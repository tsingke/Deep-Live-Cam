#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""实时换脸直播服务 —— 基于 Deep-Live-Cam 的网页版。

浏览器用 getUserMedia 采集摄像头，每帧压成 JPEG 并在前面加 8 字节
小端 float64 拍摄时间戳，POST /api/frame 到本服务。服务端复用
Deep-Live-Cam 的 buffalo_l 人脸检测与 inswapper_128_fp16 换脸模型
（Apple Silicon 走 CoreML/ANE），返回换脸后的 JPEG。

设计要点
--------
* 最多 2 帧同时处理（线程池 2 worker）；等待队列长度 1，新帧到来自动
  丢弃更旧的排队帧（HTTP 204），保证画面不越拖越晚。
* 人脸检测默认每 3 帧做一次，中间帧复用上一次的 bbox/kps。
* 启动时预热检测模型；第一次有照片后预热换脸模型（CoreML 首次编译
  需要 1–3 分钟，之后走系统缓存）。
* 闲置 2 小时（没有帧/上传/选择操作）自动退出。

只监听 127.0.0.1，不对外网开放。
"""
from __future__ import annotations

import argparse
import asyncio
import json
import logging
import math
import os
import struct
import sys
import threading
import time
import uuid
from collections import deque
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Deque, Dict, List, Optional, Tuple

import cv2
import numpy as np

# ---------------------------------------------------------------------------
# 路径 & Deep-Live-Cam 初始化
# ---------------------------------------------------------------------------
ROOT = Path(__file__).resolve().parent
# 兼容两种仓库布局：
#   独立项目：<root>/Deep-Live-Cam/modules
#   fork 整合：<root>/modules（上游源码在根目录）
DLC_DIR = ROOT / "Deep-Live-Cam"
if not (DLC_DIR / "modules").is_dir() and (ROOT / "modules").is_dir():
    DLC_DIR = ROOT
WEB_DIR = ROOT / "web"
PHOTOS_DIR = ROOT / "photos"
LIBRARY_FILE = PHOTOS_DIR / "library.json"
CONFIG_FILE = ROOT / "config.json"
LOG_DIR = ROOT / "logs"

for d in (PHOTOS_DIR, LOG_DIR):
    d.mkdir(parents=True, exist_ok=True)

if not (DLC_DIR / "modules").is_dir():
    sys.stderr.write(f"[fatal] 找不到 Deep-Live-Cam 模块目录: {DLC_DIR}\n")
    raise SystemExit(1)

sys.path.insert(0, str(DLC_DIR))

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%H:%M:%S",
    handlers=[
        logging.StreamHandler(sys.stdout),
        logging.FileHandler(LOG_DIR / "server.log", encoding="utf-8"),
    ],
)
log = logging.getLogger("faceswap")

cv2.setNumThreads(2)

import modules.globals as g  # noqa: E402  (必须在 set 之后导入)

# 这些全局开关在 import face_swapper 之前设置好。
g.headless = True
g.frame_processors = ["face_swapper"]
g.many_faces = False          # 只换最左边的一张脸（与 get_one_face 一致）
g.map_faces = False
g.opacity = 1.0
g.mouth_mask = False
g.poisson_blend = False
g.sharpness = 0.0
g.enable_interpolation = False  # 实时链路自己做丢帧，不做时间混合（会拖影）
g.nsfw_filter = False
g.det_size = 640

DEFAULT_DETECT_INTERVAL = 3
DEFAULT_JPEG_QUALITY = 85
DEFAULT_HEAD_SWAP = False
DEFAULT_HEAD_STRENGTH = 90   # 0..100
DEFAULT_HEAD_SCALE = 100     # 85..115
DEFAULT_HEAD_OFFSET_Y = 0    # -20..20 (% of target face height)
MAX_FRAME_BYTES = 8 * 1024 * 1024
MAX_UPLOAD_BYTES = 20 * 1024 * 1024
MAX_WORKERS = 2               # 同时处理的最大帧数
# 处理槽之外只保留 1 个待处理帧；新帧到来时替换它（旧请求返回 204）。


# ---------------------------------------------------------------------------
# 数据结构
# ---------------------------------------------------------------------------
@dataclass
class FrameResult:
    jpeg: bytes
    total_ms: float
    decode_ms: float
    detect_ms: float
    swap_ms: float
    encode_ms: float
    detected: bool
    swapped: bool
    detect_reused: bool
    face_area: float = 0.0


@dataclass
class FrameState:
    """每个客户端会话的检测缓存与主角锁定状态。"""
    n: int = 0
    faces: List[Any] = field(default_factory=list)          # 当前要换的目标脸
    last_faces: List[Dict[str, Any]] = field(default_factory=list)  # 最近检测到的所有候选
    last_size: Tuple[int, int] = (0, 0)
    track_embedding: Optional[np.ndarray] = None           # 锁定的主角身份
    track_bbox: Optional[np.ndarray] = None
    manual_lock: bool = False                              # 是否由点击指定
    last_frame_ts: float = 0.0
    track_lock: threading.Lock = field(default_factory=threading.Lock)
    last_seen: float = field(default_factory=time.time)


@dataclass
class FrameJob:
    jpeg: bytes
    state: FrameState
    future: asyncio.Future


def _read_image(path: Path) -> Optional[np.ndarray]:
    try:
        data = np.fromfile(str(path), dtype=np.uint8)
        return cv2.imdecode(data, cv2.IMREAD_COLOR)
    except Exception:
        return None


def _write_image(path: Path, img: np.ndarray, quality: int = 92) -> bool:
    ok, buf = cv2.imencode(".jpg", img, [cv2.IMWRITE_JPEG_QUALITY, quality])
    if not ok:
        return False
    buf.tofile(str(path))
    return True


def _load_json(path: Path, default: Any) -> Any:
    try:
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return default


def _save_json(path: Path, data: Any) -> None:
    tmp = path.with_suffix(path.suffix + ".tmp")
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
    os.replace(tmp, path)


def _pct(values: List[float], p: float) -> float:
    if not values:
        return 0.0
    s = sorted(values)
    k = min(len(s) - 1, max(0, int(round((len(s) - 1) * p))))
    return float(s[k])


# ---------------------------------------------------------------------------
# 换脸引擎
# ---------------------------------------------------------------------------
class Engine:
    def __init__(self) -> None:
        self.status = "starting"
        self.message = "准备中…"
        self.error: Optional[str] = None
        self.ready = threading.Event()

        self.providers: List[str] = []
        self.coreml = False

        self.sources: Dict[str, Dict[str, Any]] = {}   # id -> {name, file, thumb, face, path}
        self.active_id: Optional[str] = None
        self._src_lock = threading.RLock()

        self._detect_lock = threading.Lock()   # 串行化 insightface 调用
        self._head_lock = threading.Lock()     # 懒构建源照片头部遮罩
        self._state_lock = threading.Lock()
        self._stats_lock = threading.Lock()
        self.recent: Deque[Dict[str, float]] = deque(maxlen=300)
        self.frame_count = 0
        self.drop_count = 0
        self.busy = 0

        self.detect_interval = DEFAULT_DETECT_INTERVAL
        self.jpeg_quality = DEFAULT_JPEG_QUALITY
        self.swap_count = 1  # 1/2/3 = 人数，0 = 全部
        self.head_swap = DEFAULT_HEAD_SWAP  # 实验性：换脸后叠加源头部/发型
        self.head_strength = DEFAULT_HEAD_STRENGTH
        self.head_scale = DEFAULT_HEAD_SCALE
        self.head_offset_y = DEFAULT_HEAD_OFFSET_Y
        self.detect_warm_ms: Optional[float] = None
        self.swap_warm_ms: Optional[float] = None
        self._swap_warming = threading.Event()
        self._swap_warmed = False
        self._warm_started = False
        self._thread: Optional[threading.Thread] = None
        self.started_at = time.time()

    # ---- status -----------------------------------------------------------
    def set_status(self, status: str, message: str) -> None:
        self.status = status
        self.message = message
        log.info("[%s] %s", status, message)

    def start(self) -> None:
        self._thread = threading.Thread(target=self._initialize, name="engine-init", daemon=True)
        self._thread.start()

    # ---- init -------------------------------------------------------------
    def _initialize(self) -> None:
        try:
            import onnxruntime

            self.providers = list(onnxruntime.get_available_providers())
            self.coreml = "CoreMLExecutionProvider" in self.providers
            log.info("onnxruntime %s providers=%s", onnxruntime.__version__, self.providers)

            if self.coreml:
                g.execution_providers = [
                    "CoreMLExecutionProvider",
                    "CPUExecutionProvider",
                ]
            else:
                g.execution_providers = ["CPUExecutionProvider"]
                log.warning(
                    "onnxruntime 没有 CoreMLExecutionProvider，将退回 CPU（会明显变慢）。"
                )

            # 1. 人脸分析器（buffalo_l：det_10g + w600k_r50 + 2d106det）
            self.set_status("loading-analyser", "加载人脸检测模型…")
            from modules.face_analyser import get_face_analyser

            fa = get_face_analyser()

            self.set_status("warming-detector", "预热人脸检测模型（CoreML 首次编译）…")
            blank = np.zeros((480, 640, 3), dtype=np.uint8)
            with self._detect_lock:
                t0 = time.perf_counter()
                fa.det_model.detect(blank, max_num=0, metric="default")
                self.detect_warm_ms = (time.perf_counter() - t0) * 1000
            log.info("检测模型预热完成：%.1f ms", self.detect_warm_ms)

            # 2. 换脸模型
            self.set_status("loading-swapper", "加载换脸模型（首次会优化/编译，约 1–3 分钟）…")
            from modules.processors.frame.face_swapper import get_face_swapper

            sw = get_face_swapper()
            if sw is None:
                raise RuntimeError("inswapper 模型加载失败，见上方 DLC 日志")

            # 3. 照片库
            self.set_status("loading-photos", "载入照片库…")
            self._load_library()

            self.set_status("ready", "就绪")
            self.ready.set()

            # 提前加载 Vision 人像分割（换头用），避免用户第一次切到
            # 「换头」时卡在模型初始化上；失败则静默回退到 GrabCut。
            threading.Thread(target=self._warm_vision, daemon=True).start()

            if self.sources:
                self.start_swap_warmup()
        except Exception as exc:  # noqa: BLE001
            log.exception("初始化失败")
            self.error = str(exc)
            self.set_status("error", f"初始化失败：{exc}")

    # ---- source photos ----------------------------------------------------
    def _analyse_source_face(self, img: np.ndarray):
        """返回图片里面积最大的人脸（带 normed_embedding），没有则 None。"""
        from modules.face_analyser import get_many_faces

        with self._detect_lock:
            faces = get_many_faces(img)
        faces = [
            f for f in (faces or [])
            if f is not None and getattr(f, "normed_embedding", None) is not None
        ]
        if not faces:
            return None
        return max(
            faces,
            key=lambda f: float(
                (f.bbox[2] - f.bbox[0]) * (f.bbox[3] - f.bbox[1])
            ),
        )

    def _load_library(self) -> None:
        lib = _load_json(LIBRARY_FILE, {"photos": [], "active": None})
        loaded: Dict[str, Dict[str, Any]] = {}
        for item in lib.get("photos", []):
            pid = str(item.get("id") or "")
            fname = str(item.get("file") or "")
            if not pid or not fname:
                continue
            path = PHOTOS_DIR / fname
            if not path.is_file():
                continue
            img = _read_image(path)
            if img is None:
                continue
            face = self._analyse_source_face(img)
            if face is None:
                log.warning("照片 %s 未检测到人脸，已跳过", fname)
                continue
            loaded[pid] = {
                "id": pid,
                "name": item.get("name") or fname,
                "file": fname,
                "thumb": item.get("thumb") or fname,
                "path": path,
                "face": face,
            }

        with self._src_lock:
            self.sources = loaded
            active = lib.get("active")
            if active in loaded:
                self.active_id = active
            elif loaded:
                self.active_id = next(iter(loaded))
            log.info("照片库载入 %d 张，当前使用 %s", len(loaded), self.active_id)

        self._save_library()

    def _save_library(self) -> None:
        with self._src_lock:
            lib = {
                "active": self.active_id,
                "photos": [
                    {"id": p["id"], "name": p["name"], "file": p["file"], "thumb": p["thumb"]}
                    for p in self.sources.values()
                ],
            }
        try:
            _save_json(LIBRARY_FILE, lib)
        except Exception:
            log.exception("保存照片库失败")

    def add_photo(self, data: bytes, original_name: str) -> Tuple[Optional[Dict[str, Any]], Optional[str]]:
        img = cv2.imdecode(np.frombuffer(data, dtype=np.uint8), cv2.IMREAD_COLOR)
        if img is None:
            return None, "无法解码图片"
        if min(img.shape[:2]) < 64:
            return None, "图片太小"

        face = self._analyse_source_face(img)
        if face is None:
            return None, "未检测到清晰人脸"

        pid = "p_" + uuid.uuid4().hex[:10]
        fname = f"{pid}.jpg"
        thumb = f"{pid}_thumb.jpg"
        path = PHOTOS_DIR / fname

        if not _write_image(path, img, 92):
            return None, "保存图片失败"

        # 缩略图：最长边 260px
        h, w = img.shape[:2]
        scale = 260.0 / max(h, w)
        if scale < 1.0:
            thumb_img = cv2.resize(
                img, (max(1, int(w * scale)), max(1, int(h * scale))),
                interpolation=cv2.INTER_AREA,
            )
        else:
            thumb_img = img
        _write_image(PHOTOS_DIR / thumb, thumb_img, 82)

        name = (original_name or fname).rsplit("/", 1)[-1][:80]
        item = {
            "id": pid,
            "name": name,
            "file": fname,
            "thumb": thumb,
            "path": path,
            "face": face,
        }
        with self._src_lock:
            self.sources[pid] = item
            if self.active_id is None:
                self.active_id = pid
        self._save_library()

        log.info("新增照片 %s (%s)", name, pid)
        if self.head_swap:
            threading.Thread(target=self._head_assets, args=(item,), daemon=True).start()
        if not self._swap_warmed and not self._warm_started:
            self.start_swap_warmup()
        return self.public_photo(item), None

    def public_photo(self, item: Dict[str, Any]) -> Dict[str, Any]:
        return {
            "id": item["id"],
            "name": item["name"],
            "url": f"/photos/{item['file']}",
            "thumb": f"/photos/{item['thumb']}",
        }

    def photos(self) -> List[Dict[str, Any]]:
        with self._src_lock:
            return [self.public_photo(p) for p in self.sources.values()]

    def select(self, pid: str) -> bool:
        with self._src_lock:
            if pid not in self.sources:
                return False
            self.active_id = pid
            item = self.sources[pid]
        self._save_library()
        if self.head_swap:
            threading.Thread(target=self._head_assets, args=(item,), daemon=True).start()
        return True

    def delete(self, pid: str) -> bool:
        with self._src_lock:
            item = self.sources.pop(pid, None)
            if item is None:
                return False
            if self.active_id == pid:
                self.active_id = next(iter(self.sources), None)
        for key in ("file", "thumb"):
            try:
                (PHOTOS_DIR / item[key]).unlink(missing_ok=True)
            except Exception:
                pass
        self._save_library()
        return True

    def active_source_item(self) -> Optional[Dict[str, Any]]:
        with self._src_lock:
            return self.sources.get(self.active_id) if self.active_id else None

    def active_face(self):
        item = self.active_source_item()
        return item["face"] if item else None

    def _head_assets(self, item: Optional[Dict[str, Any]]):
        """懒构建并缓存当前源照片的头部图/软遮罩/五点关键点。"""
        if item is None:
            return None
        cached = item.get("head_assets")
        if cached is not None:
            return cached
        with self._head_lock:
            cached = item.get("head_assets")
            if cached is not None:
                return cached
            from head_swap import build_source_head_assets

            img = _read_image(item["path"])
            if img is None:
                return None
            assets = build_source_head_assets(img, item["face"])
            if assets is None:
                log.warning("换头：无法从 %s 提取头部遮罩", item.get("name"))
                return None
            item["head_assets"] = assets
            log.info("换头：已为 %s 构建头部遮罩", item.get("name"))
            return assets

    # ---- warm-up ----------------------------------------------------------
    def _warm_vision(self) -> None:
        try:
            from head_swap import _vision_person_mask

            with self._head_lock:
                _vision_person_mask(np.zeros((64, 64, 3), dtype=np.uint8))
            log.info("Vision 人像分割已预热")
        except Exception:
            pass

    def start_swap_warmup(self) -> None:
        if self._warm_started or self._swap_warmed:
            return
        self._warm_started = True
        threading.Thread(target=self._warm_swap, name="swap-warmup", daemon=True).start()

    def _warm_swap(self) -> None:
        from modules.processors.frame.face_swapper import swap_face

        try:
            with self._src_lock:
                item = self.sources.get(self.active_id) if self.active_id else None
                item = item or next(iter(self.sources.values()), None)
                if item is None:
                    return
                src_face = item["face"]
                path = item["path"]

            self._swap_warming.set()
            self.set_status("warming-swapper", "首次预热换脸模型（CoreML 编译，约 1–3 分钟）…")

            img = _read_image(path)
            if img is None:
                raise RuntimeError("预热图片读取失败")
            # 目标脸就用照片里的同一张脸；只为了触发一次完整推理。
            tgt = self._analyse_source_face(img)
            if tgt is None:
                raise RuntimeError("预热时未检测到人脸")

            t0 = time.perf_counter()
            swap_face(src_face, tgt, img)
            self.swap_warm_ms = (time.perf_counter() - t0) * 1000
            self._swap_warmed = True
            log.info("换脸模型预热完成：%.1f ms", self.swap_warm_ms)
            if self.status == "warming-swapper":
                self.set_status("ready", "就绪")
        except Exception:  # noqa: BLE001
            log.exception("换脸模型预热失败")
            if self.status == "warming-swapper":
                self.set_status("ready", "就绪（预热失败，首帧会较慢）")
        finally:
            self._swap_warming.clear()

    # ---- target selection -------------------------------------------------
    def _detect_candidates(self, img: np.ndarray, state: FrameState) -> List[Dict[str, Any]]:
        """检测所有人脸，过滤小脸，并计算特征用于锁定/点击选择。"""
        from modules.face_analyser import detect_many_faces_fast, get_face_analyser

        h, w = img.shape[:2]
        frame_area = float(max(1, w * h))
        raw = detect_many_faces_fast(img) or []
        cands: List[Dict[str, Any]] = []
        for face in raw:
            bbox = getattr(face, "bbox", None)
            if bbox is None:
                continue
            try:
                x1, y1, x2, y2 = (float(v) for v in bbox[:4])
            except Exception:
                continue
            area = max(0.0, (x2 - x1) * (y2 - y1))
            if area < frame_area * 0.005:  # 忽略过小的背景脸
                continue
            det = float(getattr(face, "det_score", 1.0) or 0.0)
            if det < 0.42:
                continue
            cx, cy = (x1 + x2) / 2, (y1 + y2) / 2
            norm = math.hypot(
                (cx - w / 2) / (w / 2 + 1e-6),
                (cy - h / 2) / (h / 2 + 1e-6),
            )
            central = max(0.35, 1.0 - 0.45 * min(norm, 1.2))
            cands.append({
                "face": face,
                "bbox": np.array([x1, y1, x2, y2], dtype=np.float32),
                "area": area,
                "center": (cx, cy),
                "score": area * central,
                "emb": None,
            })

        cands.sort(key=lambda c: c["score"], reverse=True)
        cands = cands[:10]

        try:
            fa = get_face_analyser()
            rec = fa.models.get("recognition") if fa is not None else None
        except Exception:
            rec = None
        if rec is not None:
            for c in cands:
                try:
                    rec.get(img, c["face"])
                    emb = getattr(c["face"], "normed_embedding", None)
                    if emb is not None:
                        c["emb"] = np.asarray(emb, dtype=np.float32).copy()
                except Exception:
                    pass

        with state.track_lock:
            state.last_faces = [dict(c) for c in cands]
            state.last_size = (w, h)
        return cands

    def _select_targets(self, cands: List[Dict[str, Any]], state: FrameState) -> List[Any]:
        count = int(self.swap_count)
        with state.track_lock:
            if not cands:
                state.faces = []
                return []

            locked = state.track_embedding
            if locked is not None:
                matches = []
                for c in cands:
                    emb = c.get("emb")
                    if emb is None:
                        continue
                    sim = float(np.dot(emb, locked))
                    if sim >= 0.45:
                        matches.append((sim, c))
                if not matches:
                    # 主角不在画面里：宁可不换，也不换到别人
                    state.faces = []
                    return []

                prev = state.track_bbox

                def rank(pair):
                    sim, c = pair
                    if prev is None:
                        dist = 0.0
                    else:
                        px = (prev[0] + prev[2]) / 2
                        py = (prev[1] + prev[3]) / 2
                        dist = math.hypot(c["center"][0] - px, c["center"][1] - py)
                    return (dist, -sim)

                _, primary = min(matches, key=rank)
                state.track_bbox = primary["bbox"].copy()

                if count == 1:
                    state.faces = [primary["face"]]
                    return state.faces

                others = [c for c in cands if c is not primary]
                if count > 1:
                    others = others[: max(0, count - 1)]
                state.faces = [primary["face"]] + [c["face"] for c in others]
                return state.faces

            # 尚未锁定
            if count == 1:
                best = next((c for c in cands if c.get("emb") is not None), cands[0])
                if best.get("emb") is not None:
                    state.track_embedding = best["emb"].copy()
                state.track_bbox = best["bbox"].copy()
                state.manual_lock = False
                state.faces = [best["face"]]
                return state.faces

            picked = cands if count <= 0 else cands[:count]
            state.track_embedding = None
            state.track_bbox = None
            state.manual_lock = False
            state.faces = [c["face"] for c in picked]
            return state.faces

    def select_face_at(self, state: FrameState, x: float, y: float) -> Optional[Dict[str, Any]]:
        """按归一化点击坐标锁定一张脸（用于人数较多时手动指定主角）。"""
        with state.track_lock:
            if not state.last_faces or state.last_size[0] <= 0:
                return None
            w, h = state.last_size
            px, py = x * w, y * h
            diag = math.hypot(w, h)

            best = None
            best_dist = 1e9
            for c in state.last_faces:
                x1, y1, x2, y2 = (float(v) for v in c["bbox"])
                bw, bh = max(1.0, x2 - x1), max(1.0, y2 - y1)
                if (x1 - 0.12 * bw <= px <= x2 + 0.12 * bw
                        and y1 - 0.12 * bh <= py <= y2 + 0.12 * bh):
                    d = math.hypot(px - c["center"][0], py - c["center"][1])
                    if d < best_dist:
                        best_dist, best = d, c
            if best is None:
                for c in state.last_faces:
                    d = math.hypot(px - c["center"][0], py - c["center"][1])
                    if d < 0.18 * diag and d < best_dist:
                        best_dist, best = d, c
            if best is None or best.get("emb") is None:
                return None

            state.track_embedding = np.asarray(best["emb"], dtype=np.float32).copy()
            state.track_bbox = best["bbox"].copy()
            state.manual_lock = True

            count = int(self.swap_count)
            if count == 1:
                state.faces = [best["face"]]
            else:
                others = [c for c in state.last_faces if c is not best]
                if count > 1:
                    others = others[: max(0, count - 1)]
                state.faces = [best["face"]] + [c["face"] for c in others]
            return best

    def reset_target(self, state: FrameState) -> None:
        with state.track_lock:
            state.track_embedding = None
            state.track_bbox = None
            state.manual_lock = False
            state.faces = []

    # ---- frame processing -------------------------------------------------
    def process(self, jpeg: bytes, state: FrameState) -> FrameResult:
        t_frame = time.perf_counter()

        arr = np.frombuffer(jpeg, dtype=np.uint8)
        img = cv2.imdecode(arr, cv2.IMREAD_COLOR)
        t_dec = time.perf_counter()
        if img is None:
            raise ValueError("JPEG 解码失败")
        decode_ms = (t_dec - t_frame) * 1000

        detect_ms = 0.0
        reused = False
        targets: List[Any] = []

        now = time.time()
        with state.track_lock:
            # 停止超过 5 秒后重新开始：清除旧锁定，允许重新自动选主角
            if state.last_frame_ts and now - state.last_frame_ts > 5.0:
                state.track_embedding = None
                state.track_bbox = None
                state.manual_lock = False
                state.faces = []
            state.last_frame_ts = now
            cached = list(state.faces)

        with self._state_lock:
            n = state.n

        need_detect = (not cached) or (n % max(1, self.detect_interval) == 0)
        if need_detect:
            with self._detect_lock:
                t = time.perf_counter()
                candidates = self._detect_candidates(img, state)
                targets = self._select_targets(candidates, state)
                detect_ms = (time.perf_counter() - t) * 1000
        else:
            targets = cached
            reused = True

        t_swap0 = time.perf_counter()
        swapped = False
        out = img
        src_item = self.active_source_item()
        src = src_item["face"] if src_item else None
        if src is not None and targets:
            from modules.processors.frame.face_swapper import swap_face

            for target_face in targets:
                out = swap_face(src, target_face, out)
            swapped = True
            if self.head_swap:
                try:
                    from head_swap import apply_head_transfer

                    assets = self._head_assets(src_item)
                    if assets is not None:
                        for target_face in targets:
                            out = apply_head_transfer(
                                out, assets[0], assets[1], assets[2], target_face,
                                strength=self.head_strength / 100.0,
                                scale=self.head_scale / 100.0,
                                offset_y_ratio=self.head_offset_y / 100.0,
                            )
                except Exception:
                    log.exception("换头融合失败（本帧保留换脸结果）")
        swap_ms = (time.perf_counter() - t_swap0) * 1000

        t_enc = time.perf_counter()
        ok, buf = cv2.imencode(
            ".jpg", out, [cv2.IMWRITE_JPEG_QUALITY, int(self.jpeg_quality)]
        )
        encode_ms = (time.perf_counter() - t_enc) * 1000
        if not ok:
            raise ValueError("JPEG 编码失败")

        total_ms = (time.perf_counter() - t_frame) * 1000
        area = 0.0
        if targets:
            b = getattr(targets[0], "bbox", None)
            if b is not None:
                area = float(max(0.0, b[2] - b[0]) * max(0.0, b[3] - b[1]))

        result = FrameResult(
            jpeg=buf.tobytes(),
            total_ms=total_ms,
            decode_ms=decode_ms,
            detect_ms=detect_ms,
            swap_ms=swap_ms,
            encode_ms=encode_ms,
            detected=bool(targets),
            swapped=swapped,
            detect_reused=reused,
            face_area=area,
        )

        with self._stats_lock:
            self.frame_count += 1
            self.recent.append(
                {
                    "t": time.time(),
                    "total": total_ms,
                    "decode": decode_ms,
                    "detect": detect_ms,
                    "swap": swap_ms,
                    "encode": encode_ms,
                }
            )
        return result

    def note_drop(self) -> None:
        with self._stats_lock:
            self.drop_count += 1

    def snapshot(self) -> Dict[str, Any]:
        with self._stats_lock:
            rows = list(self.recent)
            dropped = self.drop_count
            frames = self.frame_count
        totals = [r["total"] for r in rows]
        now = time.time()
        last30 = [r for r in rows if now - r["t"] <= 30.0]
        out = {
            "frames": frames,
            "dropped": dropped,
            "server_p50_ms": round(_pct(totals, 0.5), 1),
            "server_p95_ms": round(_pct(totals, 0.95), 1),
            "avg_decode_ms": round(sum(r["decode"] for r in last30) / len(last30), 1) if last30 else None,
            "avg_detect_ms": round(sum(r["detect"] for r in last30 if r["detect"] > 0) /
                                   max(1, sum(1 for r in last30 if r["detect"] > 0)), 1) if last30 else None,
            "avg_swap_ms": round(sum(r["swap"] for r in last30) / len(last30), 1) if last30 else None,
            "avg_encode_ms": round(sum(r["encode"] for r in last30) / len(last30), 1) if last30 else None,
            "last_total_ms": round(rows[-1]["total"], 1) if rows else None,
            "avg_fps_30s": round(len(last30) / 30.0, 1),
        }
        return out


# ---------------------------------------------------------------------------
# 帧队列：2 个 worker + 1 个等待位（新帧挤掉旧帧）
# ---------------------------------------------------------------------------
class FrameQueue:
    """2 个处理槽 + 1 个待处理槽。

    空闲槽立刻开工，所以突发请求不会让芯片空等；两个槽都满时，新帧
    替换掉待处理槽里的旧帧（旧请求立刻收到 204），最多保留 2+1 帧。
    """

    def __init__(self, engine: Engine, loop: asyncio.AbstractEventLoop) -> None:
        self.engine = engine
        self.loop = loop
        self.pool = ThreadPoolExecutor(max_workers=MAX_WORKERS, thread_name_prefix="swap")
        self.pending: Optional[FrameJob] = None
        self.inflight = 0
        self.tasks: set[asyncio.Task] = set()
        self.stopping = False

    def start(self) -> None:
        pass  # 无需常驻 worker，任务按需启动

    def qsize(self) -> int:
        return 1 if self.pending is not None else 0

    def _start(self, job: FrameJob) -> None:
        if job.future.done() or job.future.cancelled():
            return
        self.inflight += 1
        task = self.loop.create_task(self._run(job))
        self.tasks.add(task)
        task.add_done_callback(self.tasks.discard)

    def _start_pending(self) -> None:
        while not self.stopping and self.inflight < MAX_WORKERS and self.pending is not None:
            job = self.pending
            self.pending = None
            self._start(job)

    async def _run(self, job: FrameJob) -> None:
        self.engine.busy += 1
        try:
            res = await self.loop.run_in_executor(
                self.pool, self.engine.process, job.jpeg, job.state
            )
            if not job.future.done():
                job.future.set_result(res)
        except Exception as exc:  # noqa: BLE001
            log.exception("帧处理异常")
            if not job.future.done():
                job.future.set_exception(exc)
        finally:
            self.engine.busy -= 1
            self.inflight -= 1
            self._start_pending()

    async def submit(self, job: FrameJob) -> Optional[FrameResult]:
        if self.inflight < MAX_WORKERS and self.pending is None:
            self._start(job)
        else:
            # 两个槽都忙：用新帧替换待处理槽里的旧帧
            old = self.pending
            self.pending = job
            if old is not None and not old.future.done():
                old.future.set_result(None)  # 204
                self.engine.note_drop()
            # 若刚有槽空出来，立刻补上
            self._start_pending()
        try:
            return await asyncio.wait_for(job.future, timeout=20.0)
        except asyncio.TimeoutError:
            return None

    async def stop(self) -> None:
        self.stopping = True
        if self.pending is not None and not self.pending.future.done():
            self.pending.future.set_result(None)
        self.pending = None
        for t in list(self.tasks):
            t.cancel()
        for t in list(self.tasks):
            try:
                await t
            except (asyncio.CancelledError, Exception):
                pass
        self.pool.shutdown(wait=False, cancel_futures=True)


# ---------------------------------------------------------------------------
# HTTP handlers
# ---------------------------------------------------------------------------
def _engine(request) -> Engine:
    return request.app["engine"]


async def index(request) -> Any:
    request.app["last_activity"] = time.time()
    return _file(WEB_DIR / "index.html")


async def output_page(request) -> Any:
    return _file(WEB_DIR / "output.html")


def _file(path: Path) -> Any:
    from aiohttp import web

    if not path.is_file():
        return web.Response(status=404, text="not found")
    return web.FileResponse(path, headers={"Cache-Control": "no-cache"})


async def api_state(request) -> Any:
    from aiohttp import web

    app = request.app
    eng: Engine = app["engine"]
    now = time.time()
    idle = now - app["last_activity"]

    with eng._src_lock:
        active = eng.active_id
    state = {
        "status": eng.status,
        "message": eng.message,
        "ready": eng.ready.is_set(),
        "error": eng.error,
        "coreml": eng.coreml,
        "providers": eng.providers,
        "photos": eng.photos(),
        "active": active,
        "settings": {
            "detect_interval": eng.detect_interval,
            "jpeg_quality": eng.jpeg_quality,
            "swap_count": eng.swap_count,
            "head_swap": bool(eng.head_swap),
            "head_strength": eng.head_strength,
            "head_scale": eng.head_scale,
            "head_offset_y": eng.head_offset_y,
        },
        "warmup": {
            "detect_ms": round(eng.detect_warm_ms, 1) if eng.detect_warm_ms else None,
            "swap_ms": round(eng.swap_warm_ms, 1) if eng.swap_warm_ms else None,
            "swap_warming": bool(eng._swap_warming.is_set()),
        },
        "stats": eng.snapshot(),
        "busy": eng.busy,
        "queue": app["fq"].qsize(),
        "uptime_s": round(now - eng.started_at),
        "idle_timeout_s": app["idle_timeout"],
        "idle_remaining_s": max(0, int(app["idle_timeout"] - idle)),
        "version": "1.0",
    }
    return web.json_response(state)


async def api_upload(request) -> Any:
    from aiohttp import web

    app = request.app
    eng: Engine = app["engine"]
    if not eng.ready.is_set():
        return web.json_response({"ok": False, "error": "服务尚未就绪"}, status=503)
    if eng.status == "warming-swapper":
        return web.json_response(
            {"ok": False, "error": "换脸模型正在首次预热，请稍候再上传"}, status=503
        )

    added: List[Dict[str, Any]] = []
    errors: List[Dict[str, str]] = []
    try:
        reader = await request.multipart()
        async for part in reader:
            if part.name != "photos" or not getattr(part, "filename", None):
                continue
            data = await part.read()
            if not data:
                continue
            if len(data) > MAX_UPLOAD_BYTES:
                errors.append({"name": part.filename, "error": "文件超过 20MB"})
                continue
            item, err = await asyncio.get_running_loop().run_in_executor(
                None, eng.add_photo, data, part.filename
            )
            if item:
                added.append(item)
            else:
                errors.append({"name": part.filename, "error": err or "处理失败"})
    except Exception as exc:  # noqa: BLE001
        log.exception("上传失败")
        return web.json_response({"ok": False, "error": str(exc)}, status=400)

    if added:
        app["last_activity"] = time.time()
    return web.json_response({"ok": True, "added": added, "errors": errors})


async def api_select(request) -> Any:
    from aiohttp import web

    try:
        body = await request.json()
    except Exception:
        return web.json_response({"ok": False, "error": "bad json"}, status=400)
    pid = str(body.get("id") or "")
    ok = _engine(request).select(pid)
    if ok:
        request.app["last_activity"] = time.time()
    return web.json_response(
        {"ok": ok, "active": _engine(request).active_id}, status=200 if ok else 404
    )


async def api_delete(request) -> Any:
    from aiohttp import web

    try:
        body = await request.json()
    except Exception:
        return web.json_response({"ok": False, "error": "bad json"}, status=400)
    ok = _engine(request).delete(str(body.get("id") or ""))
    return web.json_response({"ok": ok, "active": _engine(request).active_id})


async def api_config(request) -> Any:
    from aiohttp import web

    eng = _engine(request)
    try:
        body = await request.json()
    except Exception:
        return web.json_response({"ok": False, "error": "bad json"}, status=400)

    if "detect_interval" in body:
        try:
            eng.detect_interval = max(1, min(12, int(body["detect_interval"])))
        except Exception:
            pass
    if "jpeg_quality" in body:
        try:
            eng.jpeg_quality = max(50, min(95, int(body["jpeg_quality"])))
        except Exception:
            pass
    if "swap_count" in body:
        try:
            value = int(body["swap_count"])
            new_value = 0 if value <= 0 else max(1, min(6, value))
            if new_value != eng.swap_count:
                eng.swap_count = new_value
                # 立即让下一帧按新人数重新选目标
                for session_state in request.app["states"].values():
                    with session_state.track_lock:
                        session_state.faces = []
        except Exception:
            pass
    if "head_swap" in body:
        try:
            eng.head_swap = bool(body["head_swap"])
            if eng.head_swap:
                item = eng.active_source_item()
                if item is not None:
                    threading.Thread(
                        target=eng._head_assets, args=(item,), daemon=True
                    ).start()
        except Exception:
            pass
    if "head_strength" in body:
        try:
            eng.head_strength = max(0, min(100, int(body["head_strength"])))
        except Exception:
            pass
    if "head_scale" in body:
        try:
            eng.head_scale = max(85, min(115, int(body["head_scale"])))
        except Exception:
            pass
    if "head_offset_y" in body:
        try:
            eng.head_offset_y = max(-20, min(20, int(body["head_offset_y"])))
        except Exception:
            pass
    _save_json(
        CONFIG_FILE,
        {
            "detect_interval": eng.detect_interval,
            "jpeg_quality": eng.jpeg_quality,
            "swap_count": eng.swap_count,
            "head_swap": bool(eng.head_swap),
            "head_strength": eng.head_strength,
            "head_scale": eng.head_scale,
            "head_offset_y": eng.head_offset_y,
        },
    )
    request.app["last_activity"] = time.time()
    return web.json_response(
        {
            "ok": True,
            "detect_interval": eng.detect_interval,
            "jpeg_quality": eng.jpeg_quality,
            "swap_count": eng.swap_count,
            "head_swap": bool(eng.head_swap),
            "head_strength": eng.head_strength,
            "head_scale": eng.head_scale,
            "head_offset_y": eng.head_offset_y,
        }
    )


def _session_state(request) -> Optional[FrameState]:
    sid = request.query.get("s") or request.headers.get("X-Session") or "default"
    return request.app["states"].get(sid)


async def api_target(request) -> Any:
    """点击画面锁定目标：x/y 为相对画面的归一化坐标。"""
    from aiohttp import web

    try:
        body = await request.json()
        x = float(body["x"])
        y = float(body["y"])
    except Exception:
        return web.json_response({"ok": False, "error": "bad request"}, status=400)
    if not (0.0 <= x <= 1.0 and 0.0 <= y <= 1.0):
        return web.json_response({"ok": False, "error": "坐标超出画面"}, status=400)

    state = _session_state(request)
    if state is None or state.last_size[0] <= 0:
        return web.json_response({"ok": False, "error": "画面尚未就绪"}, status=200)
    if time.time() - state.last_frame_ts > 3.0:
        return web.json_response({"ok": False, "error": "画面已暂停"}, status=200)

    face = _engine(request).select_face_at(state, x, y)
    if face is None:
        return web.json_response(
            {"ok": False, "error": "这个位置没有可锁定的人脸"}, status=200
        )
    w, h = state.last_size
    b = [float(v) for v in face["bbox"]]
    request.app["last_activity"] = time.time()
    return web.json_response({
        "ok": True,
        "bbox": [b[0] / w, b[1] / h, b[2] / w, b[3] / h],
        "count": len(state.faces),
    })


async def api_target_reset(request) -> Any:
    from aiohttp import web

    state = _session_state(request)
    if state is not None:
        _engine(request).reset_target(state)
    request.app["last_activity"] = time.time()
    return web.json_response({"ok": True})


async def api_frame(request) -> Any:
    from aiohttp import web

    app = request.app
    eng: Engine = app["engine"]
    if not eng.ready.is_set() or eng.status == "warming-swapper":
        return web.Response(status=503, headers={"X-Status": eng.status})

    body = await request.read()
    if len(body) < 9:
        return web.Response(status=400, text="frame too short")
    if len(body) > MAX_FRAME_BYTES:
        return web.Response(status=413, text="frame too large")

    capture_ts = struct.unpack_from("<d", body, 0)[0]
    jpeg = body[8:]
    if not (jpeg[:2] == b"\xff\xd8"):
        return web.Response(status=400, text="not jpeg")

    app["last_activity"] = time.time()

    sid = request.query.get("s") or request.headers.get("X-Session") or "default"
    states = app["states"]
    st = states.get(sid)
    if st is None:
        if len(states) > 16:
            # 清理最久未用的会话
            oldest = min(states.items(), key=lambda kv: kv[1].last_seen)[0]
            states.pop(oldest, None)
        st = states[sid] = FrameState()
    st.last_seen = time.time()
    with eng._state_lock:
        st.n += 1

    loop = asyncio.get_running_loop()
    job = FrameJob(jpeg=jpeg, state=st, future=loop.create_future())
    result = await app["fq"].submit(job)

    if result is None:
        return web.Response(
            status=204,
            headers={
                "X-Capture-Ts": f"{capture_ts:.3f}",
                "X-Dropped": "1",
            },
        )

    headers = {
        "X-Capture-Ts": f"{capture_ts:.3f}",
        "X-Process-Ms": f"{result.total_ms:.1f}",
        "X-Decode-Ms": f"{result.decode_ms:.1f}",
        "X-Detect-Ms": f"{result.detect_ms:.1f}",
        "X-Swap-Ms": f"{result.swap_ms:.1f}",
        "X-Encode-Ms": f"{result.encode_ms:.1f}",
        "X-Detected": "1" if result.detected else "0",
        "X-Swapped": "1" if result.swapped else "0",
        "X-Detect-Reused": "1" if result.detect_reused else "0",
        "Cache-Control": "no-store",
    }
    return web.Response(body=result.jpeg, content_type="image/jpeg", headers=headers)


async def api_shutdown(request) -> Any:
    from aiohttp import web

    log.info("收到 /api/shutdown，正在退出")
    asyncio.get_running_loop().call_later(0.2, lambda: os._exit(0))
    return web.json_response({"ok": True})


# ---------------------------------------------------------------------------
# 后台任务
# ---------------------------------------------------------------------------
async def idle_monitor(app) -> None:
    timeout = app["idle_timeout"]
    while True:
        await asyncio.sleep(30)
        idle = time.time() - app["last_activity"]
        if idle >= timeout:
            log.info("已闲置 %.0f 秒（上限 %d 秒），自动退出", idle, timeout)
            # 给页面一个提示的机会（广播通道不需要服务端）
            os._exit(0)


async def on_startup(app) -> None:
    app["states"] = {}
    app["last_activity"] = time.time()
    eng: Engine = app["engine"]
    loop = asyncio.get_running_loop()
    app["fq"] = FrameQueue(eng, loop)
    app["fq"].start()
    app["idle_task"] = loop.create_task(idle_monitor(app))
    eng.start()


async def on_cleanup(app) -> None:
    app["idle_task"].cancel()
    await app["fq"].stop()


def load_config() -> Dict[str, Any]:
    cfg = _load_json(CONFIG_FILE, {})
    if not isinstance(cfg, dict):
        cfg = {}
    return cfg


def create_app(idle_timeout: int = 7200) -> Any:
    from aiohttp import web

    eng = Engine()
    cfg = load_config()
    eng.detect_interval = int(cfg.get("detect_interval", DEFAULT_DETECT_INTERVAL))
    eng.jpeg_quality = int(cfg.get("jpeg_quality", DEFAULT_JPEG_QUALITY))
    eng.swap_count = max(0, min(6, int(cfg.get("swap_count", 1))))
    eng.head_swap = bool(cfg.get("head_swap", DEFAULT_HEAD_SWAP))
    eng.head_strength = max(0, min(100, int(cfg.get("head_strength", DEFAULT_HEAD_STRENGTH))))
    eng.head_scale = max(85, min(115, int(cfg.get("head_scale", DEFAULT_HEAD_SCALE))))
    eng.head_offset_y = max(-20, min(20, int(cfg.get("head_offset_y", DEFAULT_HEAD_OFFSET_Y))))

    # 帧请求约 100–400KB；上传是多文件 multipart，单独限制每个文件 20MB。
    app = web.Application(client_max_size=128 * 1024 * 1024)
    app["engine"] = eng
    app["idle_timeout"] = idle_timeout

    app.router.add_get("/", index)
    app.router.add_get("/output", output_page)
    app.router.add_get("/api/state", api_state)
    app.router.add_post("/api/upload", api_upload)
    app.router.add_post("/api/select", api_select)
    app.router.add_post("/api/delete", api_delete)
    app.router.add_post("/api/config", api_config)
    app.router.add_post("/api/target", api_target)
    app.router.add_post("/api/target/reset", api_target_reset)
    app.router.add_post("/api/frame", api_frame)
    app.router.add_post("/api/shutdown", api_shutdown)

    app.router.add_static("/static/", WEB_DIR, name="static")
    app.router.add_static("/photos/", PHOTOS_DIR, name="photos")

    app.on_startup.append(on_startup)
    app.on_cleanup.append(on_cleanup)
    return app


def main() -> None:
    parser = argparse.ArgumentParser(description="Deep-Live-Cam realtime web server")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=int(os.environ.get("PORT", "8787")))
    parser.add_argument(
        "--idle-timeout",
        type=int,
        default=int(os.environ.get("IDLE_TIMEOUT", "7200")),
        help="闲置多少秒后自动退出（默认 7200 = 2 小时）",
    )
    args = parser.parse_args()

    from aiohttp import web

    app = create_app(args.idle_timeout)
    log.info("服务地址 http://%s:%d  （闲置 %d 分钟自动退出）", args.host, args.port, args.idle_timeout // 60)
    log.info("首次启动需要编译 CoreML 模型，请耐心等待状态变为“就绪”")
    web.run_app(
        app,
        host=args.host,
        port=args.port,
        print=None,
        access_log=None,
    )


if __name__ == "__main__":
    main()
