# LiveFace 开发与交接

> 最后更新：2026-11-27
>
> 这份文档面向**新开的 Claude Code 会话**。先完整读一遍，再动代码。
> 目标是让下一位接手者在不了解本会话历史的情况下，能安全地继续开发和交付。

---

## 0. 先读这一段

- 项目是 macOS 原生 App + 本地 Python 换脸服务，**不上传画面/照片到云端**。
- 当前工作副本里可能包含**用户本人的人像照片**（`photos/` 与 `~/Movies/LiveFace` 里的录制）。
  **不要打开、截图、复制或提交这些用户数据。**
- 公开 fork 的**历史提交**里仍可能有上游演示媒体；当前分支树已经清理。
- 所有 README 截图都来自一个**临时空照片库项目**，不含人物。
- 发布/提交前先检查：
  `git status`、`git diff --stat`、`git ls-files`，确认没有 `photos/`、`logs/`、`config.json`、`*.onnx`、用户截图/视频。

### 0.1 用户偏好与红线

- 中文界面，Apple/macOS 设计语言；功能可以强，但主界面要简洁。
- 所有处理本地完成，不上传云端。
- 不引入第三方人物素材；README 截图只用空照片库。
- **不打开、不移动、不删除、不提交用户的 `photos/`、录音、录制视频。**
- 每次功能完成：构建 → 同步两个仓库 → 更新 README/截图 → commit/push。
- 给用户的说明用中文，并写清操作步骤、限制和回退方式。

---

## 1. 项目定位

**LiveFace** 是 Apple Silicon Mac 上的实时换脸/换头直播工具：

- 原生 SwiftUI + AppKit 窗口，AVFoundation 摄像头
- 本地 aiohttp 服务（`127.0.0.1:8787`）
- Deep-Live-Cam 的 buffalo_l 人脸检测 + inswapper_128 换脸（CoreML/ANE）
- 可弹出无控件输出窗口给 OBS 窗口采集
- 本地截图（PNG）与 H.264 + AAC 录制
- **换脸（仅面部）** 与 **换头（实验：头型/发型融合）** 可选
- 全部处理在本机完成

App 的 Bundle ID：`local.liveface.studio`  
安装位置（当前机器）：`~/Applications/LiveFace.app`  
后台端口：`8787`

---

## 2. 仓库、关系与当前快照

| 位置 | 说明 |
|---|---|
| `<checkout>` | 本地工作副本，非 git 仓库；构建和调试在这里做 |
| `tsingke/LiveFace`（私有） | **独立 App 仓库**；必要的 Deep-Live-Cam `modules/` 已 vendored，无 submodule；`./install.sh` 一键安装 |
| `tsingke/Deep-Live-Cam`（公开） | 增强 fork；根目录同时包含 App 代码与上游 `modules/`；与 App 仓库的 App 文件保持同步 |

**快照（本交接文档写入前的最新功能提交）**

- App：`e3828c9` — `feat: make LiveFace a standalone source repository`
- Fork：`8705320` — 最近的合并 App 代码快照（公开 fork 未重复 vendoring 提交）
- 交接文档本身会有一次后续 commit；以 `git log -1` 为准。

**重要维护约定**

- `LiveFace` 与公开 fork 的**App 相关文件必须保持一致**：
  `native/`、`web_server.py`、`head_swap.py`、`requirements-web.txt`、
  `make_native_app.sh`、`README.md`、`docs/`。
- App 仓库把必需的 `Deep-Live-Cam/modules/` 与 `requirements.txt` **vendored** 在仓库内，
  **没有 git submodule**；公开 fork 根目录仍保留完整 `modules/`。
- 如果未来升级上游 `modules/`，需要手动重新 vendor 到 App 仓库，并同步公开 fork。

**历史清理提醒**

- 公开 fork 的旧历史仍可能包含上游演示媒体。
- 当前树/README 已无人物素材。
- 若需要彻底清除历史，使用 `git filter-repo` 重写并强推；这会改写所有 commit。
  **先征求用户确认。**

---

## 3. 架构与数据流

```text
AVFoundation 摄像头
        │  1280×720 BGRA
        ▼
SwiftUI App（CameraController）
        │  JPEG + 8 字节小端时间戳
        ▼
本地 aiohttp 服务 :8787（2 worker、1 个 pending 帧、旧帧 204）
        │
        ├─ buffalo_l 检测（每 N 帧；中间帧复用）
        ├─ 目标选择（1/2/3/全部、身份锁定、点击锁定）
        ├─ inswapper_128 CoreML 换脸
        └─ 可选：头型/发型融合（Vision 人像分割 + 五点对齐）
        │  换脸后 JPEG
        ▼
App 预览（固定延迟上屏）
        ├─ 输出窗口（OBS 窗口采集，可置顶）
        └─ MediaCapture：截图 PNG / MP4（H.264 + AAC）
```

- 服务端最多 2 帧并发；等待队列 1 格，新帧到来时丢弃排队旧帧。
- App 端最多 2 个请求在途，忙则跳过这一拍。
- 固定延迟（0–1000ms）只影响**预览/输出**；本地录制用**采集时间戳**对齐音视频，
  不受预览延迟影响。
- 麦克风只在录制期间启用；不录制时完全停止。

---

## 4. 源码地图

### 4.1 原生 App（`native/`）

| 文件 | 职责 |
|---|---|
| `main.swift` | AppKit 入口 |
| `LiveFaceApp.swift` | AppDelegate、主窗口、菜单、崩溃日志、`--snapshot`/`--settings` 调试入口 |
| `ContentView.swift` | 主界面：照片库、同步/画质、人数、模式、点击锁定、顶部快捷按钮 |
| `SettingsView.swift` | 设置 sheet：设备 / 画面画质 / 录制 / 换头 / 状态与 OBS / 快捷键 / 维护 |
| `AppModel.swift` | 全局状态、快捷键、录制/截图、倒计时、最近文件、设备、窗口记忆、换头参数 |
| `BackendClient.swift` | 启动/复用 Python 服务、HTTP API、轮询状态 |
| `CameraController.swift` | AVFoundation 摄像头、设备/分辨率选择、JPEG 编解码、延迟上屏 |
| `AudioCapture.swift` | 录制期间麦克风采集、AAC 源数据、RMS 电平 |
| `MediaCapture.swift` | PNG 截图、H.264 + AAC MP4、像素缓冲、PTS、暂停/继续重排 |
| `OutputWindow.swift` | OBS 纯净输出窗口、黑底、FPS/光标、窗口 frame 记忆、置顶 |
| `Models.swift` | `PhotoInfo`、`ServerSettings`、`ServerState`、`CaptureDevice` 等 |

### 4.2 Python 服务

| 文件 | 职责 |
|---|---|
| `web_server.py` | aiohttp、Engine、帧队列、照片库、目标选择、配置、API |
| `head_swap.py` | Vision 人像分割源头部遮罩、GrabCut 回退、五点相似变换、软 alpha 融合 |
| `Deep-Live-Cam/modules/`（App vendored）或 `modules/`（fork） | 上游检测/换脸源码 |
| `Deep-Live-Cam/models/` 或 `models/` | 模型缓存（运行期生成，不入库） |
| `web/` | 浏览器调试控制台（App 不依赖） |
| `start.command` | 浏览器调试启动脚本 |
| `requirements-web.txt` | aiohttp + `pyobjc-framework-Vision` |

### 4.3 构建与文档

| 文件 | 职责 |
|---|---|
| `make_native_app.sh` | swiftc 构建 `LiveFace.app`，`--install` 安装到 `~/Applications` |
| `make_app.sh` | `make_native_app.sh` 包装 |
| `assets/` | AppIcon、icns、图标生成脚本 |
| `docs/ui-main.png` | 空照片库主界面截图 |
| `docs/ui-settings.png` | 设置窗口截图（换头 tab） |
| `docs/pipeline.png` | 端到端链路图 |
| `docs/HANDOFF.md` | 本文件 |
| `tests/test_head_swap.py` | 换头纯逻辑单元测试（无模型/无人物） |
| `tests/test_server_api.py` | 隔离空照片库的真实服务 API smoke（CoreML 就绪、配置钳制、上传拒绝、帧协议） |
| `tests/recording_smoke/main.swift` | 合成视频/音频 + 暂停的录制 smoke |
| `tests/run_recording_smoke.sh` | 编译并运行录制 smoke |

---

## 5. 功能状态

### 照片与目标
- 多选/拖拽上传 JPG/PNG/WEBP，最多 9 张快捷键 1–9。
- 自动检测最大人脸并提取特征。
- 换脸人数：1（主角）/2/3/全部。
- 主角身份锁定；主角离开不换别人。
- 点击画面任意脸锁定；「自动选择」恢复。

### 实时与输出
- 2 帧并发、检测每 N 帧、积压丢帧。
- 固定延迟 0–1000ms，用于 OBS 音画同步。
- 输出窗口 1280×720、黑底、无控件、16:9、F 全屏、Esc 关闭、光标自动隐藏。
- 输出窗口可置顶；主窗口/输出窗口位置大小记忆。

### 画质与分辨率
- 采集：720p / 1080p / 4K（`AVCaptureSession` preset；停止直播后切换）。
- 发送 JPEG 画质 50–95（默认 85）；服务端输出 JPEG 画质 50–95（默认 90）。
- 清晰度增强 0–100（服务端 unsharp mask，整帧）。
- **GPEN-BFR-256 面部增强**（可选）：首次下载约 75MB；增强换脸后的脸；会增加延迟/发热。
- 画质预设：流畅优先（720p/75/85/0）、均衡（1080p/85/90/10）、清晰优先（1080p/92/93/25 + 面部增强）。
- 录制码率 4/8/12/16/32 Mbps。
- 实测：面部增强下 960×1137 测试图约 176–250ms/帧（约 4–6fps）；不开增强时约 50–80ms。
- **限制**：inswapper 输出固定 128×128，不开增强时面部细节仍受模型限制；4K 对集成 GPU 和散热压力大。

### 录制
- 顶部 `截图` / `⌘S`：PNG，保存当前换脸后的干净画面。
- 顶部 `录制` / `⌘R`：H.264 MP4；可选 AAC 麦克风；`⌘P` 暂停/继续。
- 4/8/12 Mbps 画质；倒计时 0/3/5 秒；最长录制 1/5/10/30 分钟。
- **暂停/继续录制**（`⌘P` 或顶部按钮）：暂停时停止视频帧和麦克风，继续后写入同一文件；
  音视频 PTS 会去掉暂停段，REC 计时/最长录制只算实际录制时间。
- 麦克风可关闭；录制期间顶部显示 RMS 电平；首次请求麦克风权限。
- 停止直播/退出 App 自动结束录制并停止麦克风。
- 默认目录 `~/Movies/LiveFace`；最近文件列出 **LiveFace_** 前缀的 5 个文件，可打开/Finder/删除。
- 音视频用 host-clock 采集时间戳对齐；本地文件不受预览固定延迟影响。

### 换头（实验）
- 侧栏「模式」：换脸（仅面部）/ 换头（实验）。
- 换头 = inswapper 换脸 + 源照片头型/发型叠加：
  - 源头部用 Vision `VNGeneratePersonSegmentationRequest` 软遮罩；不可用时 GrabCut。
  - 五点 landmarks 相似变换对齐。
  - 目标脸孔保留目标表情/口型；只传头发/耳朵/头部轮廓。
- 参数：强度 0–100（默认 90）、缩放 85–115（100）、上下/左右 -20..20（0）。
- 预设：自然 70/98/0、均衡 90/100/0、明显 100/104/0。
- 首次切换构建源头部遮罩；Vision 在服务启动后预热。
- **限制：2D 头型/发型融合，不是 3D 生成式整头替换。侧脸/光线差异大时会有接缝。**
- 每帧约 +10–20ms（Apple Silicon 参考机，960×1137 测试图，换脸 54ms → 换头 68ms）。

### 设备与设置
- 设置（齿轮 / `⌘,`）分四类：设备、录制、换头、状态与 OBS。
- 摄像头/麦克风可枚举、刷新、持久化；停止直播/录制后才能切换。
- 快捷键参考、打开日志目录、重置窗口位置。
- 主窗口和输出窗口 frame 持久化；输出窗口置顶开关。

---

## 6. 后台 API 与配置

监听 `127.0.0.1:8787`。

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/api/state` | 状态、照片、设置、性能、闲置 |
| POST | `/api/upload` | multipart `photos`，多文件 |
| POST | `/api/select` | `{id}` |
| POST | `/api/delete` | `{id}` |
| POST | `/api/config` | 见下方配置键 |
| POST | `/api/target?s=...` | `{x,y}` 归一化点击坐标 |
| POST | `/api/target/reset?s=...` | 恢复自动主角 |
| POST | `/api/frame?s=...` | 8 字节 LE float64 拍摄时间戳 + JPEG |
| POST | `/api/shutdown` | 关闭服务 |

### `config.json` 键（默认值）

```json
{
  "detect_interval": 3,
  "jpeg_quality": 90,
  "sharpen": 0,
  "face_enhance": false,
  "swap_count": 1,
  "head_swap": false,
  "head_strength": 90,
  "head_scale": 100,
  "head_offset_y": 0,
  "head_offset_x": 0
}
```

范围：

- `detect_interval` 1–12
- `jpeg_quality` 50–95
- `sharpen` 0–100
- `face_enhance` bool（运行时另有 `face_enhance_ready/error`）
- `swap_count` 0（全部）..6
- `head_strength` 0–100
- `head_scale` 85–115
- `head_offset_y/x` -20..20

配置文件位置：`<project-root>/config.json`（运行期生成，不入库）。

### 帧会话

- `s` 查询参数是客户端会话 ID；每个会话有检测缓存、主角锁定、点击目标。
- 停止 5 秒后重新开始会清除旧锁定。
- 204 = 队列忙/旧帧丢弃。

### 照片库

- `<project-root>/photos/`；`library.json` 索引。
- 删除照片会删除主图和缩略图。
- **不要提交 `photos/`。**

---

## 7. 录制实现细节

- `MediaCapture.start`：视频 H.264、可选 AAC 48kHz mono 128kbps；8Mbps 默认。
- `writer.startSession(atSourceTime: hostTime)`：
  - 视频 PTS = `CACurrentMediaTime()` 拍摄时间；音频 PTS 用采集 CMSampleBuffer 原始 host clock。
  - 这样预览固定延迟不会造成本地文件音画不同步。
- 视频帧来自 `AppModel.onDisplay`（已换脸、已显示的那一帧），音频来自 `AudioCapture`。
- 暂停：`MediaCapture.pause(at:)` 停止收帧/音频，`audioCapture.stop()`；继续时
  `resume(at:)` 累加 pausedTotal，视频 PTS 平移，音频用
  `CMSampleBufferSetOutputPresentationTimeStamp` 重写输出 PTS；暂停段不进入文件。
- 停止：`audioCapture.stop()` → `mediaCapture.finish()`；退出：`finishSynchronously()`。
- 最长录制在 `tickMetrics` 检查，暂停期间不计时。
- 文件名：`LiveFace_yyyy-MM-dd_HH-mm-ss.png/.mp4`。
- 最近文件只筛 `LiveFace_` 前缀，避免列出用户目录里的其他文件。
- 删除前 NSAlert 二次确认。

**已知限制**：暂停/继续已支持（单文件）；源分辨率固定摄像头 720p；无音频时视频仍可录。

---

## 8. 构建、运行、调试

### 依赖

- Apple Silicon Mac，macOS 14+
- Python 3.12
- Xcode Command Line Tools（不需要完整 Xcode）
- `pyobjc-framework-Vision`（由 `requirements-web.txt` 安装）
- 模型自动下载到 `Deep-Live-Cam/models/` 和 `~/.insightface/models/buffalo_l/`

### 安装

**独立 App 仓库（推荐）**

```bash
git clone https://github.com/tsingke/LiveFace.git
cd LiveFace
./install.sh
```

`install.sh` 会创建 `.venv`、安装依赖并构建/安装到 `~/Applications`；也可以双击 `install.command`。
公开 fork 根目录仍可用手动方式：

```bash
python3.12 -m venv .venv
.venv/bin/pip install -r requirements.txt -r requirements-web.txt
./make_app.sh --install
```

### 运行

- 直接打开 `~/Applications/LiveFace.app`。
- 后台由 App 自动启动/复用；也可手动：
  ```bash
  .venv/bin/python web_server.py --port 8787
  ```
- 首次启动会编译 CoreML（1–3 分钟）。

### 调试参数

| 参数 | 作用 |
|---|---|
| `--snapshot <png>` | 主窗口截图后退出（5s） |
| `--settings` | 启动后打开设置 sheet |
| `--settings-head` | 设置默认进入「换头」 |
| `--settings-recording` | 设置默认进入「录制」 |
| `--snapshot-settings <png>` | 5s 时截取 attached sheet；有时需要手动结束进程 |
| `--camera` | 启动后自动开摄像头（开发者用） |
| `--demo` | 需要 `test_assets/target_face.jpg`；该素材已清理，**当前不可用** |
| `--output` | 仅 demo 模式自动打开输出窗口 |

### 自动化测试

```bash
.venv/bin/python -m unittest discover -s tests -p 'test_*.py' -v
./tests/run_recording_smoke.sh
```

- `test_head_swap`：只测合成图/假 landmarks，不加载模型、不读人物素材。
- `test_server_api`：启动真实服务（隔离空照片库、随机端口）；校验 CoreML/ready、配置范围、无脸上传拒绝、帧时间戳+JPEG 协议。约 25s。
- `recording_smoke`：合成帧 + 合成音频 + 暂停/继续；断言 1 视频轨、1 音频轨、暂停段被移除。
- 尚未覆盖：真实摄像头/麦克风、UI 截图回归。

### 隐私安全截图流程（重要）

不要直接截带用户照片的主窗口。使用**临时空照片库项目**：

```bash
CHECKOUT="<checkout>"
TMP=$(mktemp -d)
mkdir -p "$TMP/web" "$TMP/photos" "$TMP/logs"
ln -s "$CHECKOUT/Deep-Live-Cam" "$TMP/Deep-Live-Cam"
ln -s "$CHECKOUT/.venv" "$TMP/.venv"
cp "$CHECKOUT/web_server.py" "$CHECKOUT/head_swap.py" "$TMP/"

# 先退出正常 App，释放 8787
(cd "$TMP" && nohup ./.venv/bin/python web_server.py --port 8787 \
  >/tmp/lf-shot-backend.log 2>&1 &)
# 等 /api/state ready

cp -R "$HOME/Applications/LiveFace.app" "$TMP/LiveFaceShot.app"
printf '%s' "$TMP" > "$TMP/LiveFaceShot.app/Contents/Resources/ProjectPath.txt"
codesign --force --deep --sign - "$TMP/LiveFaceShot.app"

"$TMP/LiveFaceShot.app/Contents/MacOS/LiveFace" --snapshot /tmp/ui-main.png
"$TMP/LiveFaceShot.app/Contents/MacOS/LiveFace" \
  --settings --settings-head --snapshot-settings /tmp/ui-settings.png

# 如果 --snapshot-settings 进程不退出，确认 PNG 写入后 kill；再停临时 backend
# 删除 $TMP；重新打开正常 App
```

临时项目的 `photos/` 为空，不会带出用户照片。

---

## 9. 开发工作流

1. 在 `<checkout>` 修改。
2. 构建：
   ```bash
   ./make_native_app.sh --install
   ```
3. 同步到两个仓库（App 根文件保持一致）：
   ```bash
   for d in <app-repo> <fork-repo>; do
     cp web_server.py head_swap.py requirements-web.txt make_native_app.sh "$d/"
     cp native/*.swift "$d/native/"
     cp README.md docs/HANDOFF.md "$d/"
     cp docs/*.png "$d/docs/"
   done
   ```
4. 提交/推送：
   - 私有 App：`tsingke/LiveFace`
   - 公开 fork：`tsingke/Deep-Live-Cam`
   - commit 末尾使用：
     `Co-Authored-By: Claude Code <noreply@anthropic.com>`
5. **不要提交**：`photos/`、`logs/`、`config.json`、`.venv/`、`LiveFace.app`、
   `models/*.onnx`、用户截图/视频、模型缓存。

### 仓库/代码同步注意


- 公开 fork 根目录同时有 App 代码和上游 `modules/`。
- App 仓库不再有 submodule；上游 `modules/` 变更需要手动重新 vendor。

---

## 10. 当前已知限制

- 换头是**实验性 2D 头型/发型融合**，不是 3D 生成式整头替换；侧脸/光线差异大时有接缝。
- 录制暂停/继续已支持（单文件、无暂停空洞）；视频分辨率随采集选择；音频可选但无增益/降噪。
- `--demo` 依赖的测试素材已清理，当前不可用。
- 旧侧栏的 `captureSection`/`devicesSection`/`statsSection`/`obsSection` 已从 `ContentView` 清理；设置项保留在 `SettingsView`。
- App 仓库已经 source-vendored、无 submodule；但仍是“Python 环境 + 首次下载模型”的安装方式，不是完全内置 Python/模型的便携二进制。
- 公开 fork 历史仍包含上游演示媒体；当前树已清理。
- 已有 head_swap 单元测试、隔离服务 API smoke 与录制 smoke；尚无真实摄像头/麦克风/4K/UI 回归。
- 面部增强模型（GPEN-BFR-256，75MB）未入库；本机已放在 `Deep-Live-Cam/models/`。上游 Python 下载在部分网络会 SSL 失败；可手动放置模型。
- `MediaCapture` 使用 macOS 27 中已弃用的 AVAssetWriter 输入 API；目标 macOS 14，构建有弃用警告但不影响。
- 设置以 sheet 呈现，不是独立 Preferences 窗口；已支持 `⌘,`。
- 窗口位置重置在下次启动生效。

## 11. 下一步建议（按优先级）

1. **便携式 App**：内置/附带 Python 运行时与模型，拷贝即用（体积约 2–3GB）。
2. **真正整头替换模型**：接入专用 head-swap/portrait 模型；需要新的模型下载、性能评估和许可审查。
3. **真实设备/4K/UI 集成测试**：摄像头/麦克风、目标锁定、4K 帧、UI 回归（服务 API 已有 smoke）。
4. **设置搜索/收藏**：设置项增多后可加搜索。
5. **独立 Preferences 窗口**：替代 sheet；保持 `⌘,`。
6. **签名/分发**：Developer ID、notarization、便携包。
7. **历史清理**：filter-repo 清除公开 fork 的上游媒体历史（需用户确认）。

---

## 12. 排障

| 现象 | 处理 |
|---|---|
| App 显示服务启动失败 | 看 `logs/native-app.log` / `logs/server.log`；确认 `.venv`、模型、端口 |
| 摄像头没有画面 | 系统设置 → 隐私与安全性 → 摄像头 → 允许 LiveFace |
| 麦克风无输入/无声音 | 系统设置 → 隐私与安全性 → 麦克风 → 允许 LiveFace；停止后重新录制 |
| 换头无变化 | 源照片需可见头发/头部；正脸/半身照；确认模式为「换头」 |
| 换头接缝明显 | 降低强度、调缩放/上下/左右；改用接近光源/角度的源照片 |
| Vision 不可用 | `pip install pyobjc-framework-Vision`；失败会自动回退 GrabCut |
| OBS 黑屏 | 给 OBS 屏幕录制权限；输出窗口不要最小化；可开启置顶 |
| 录制没有文件 | 确认目录可写；`LiveFace_` 前缀；停止录制等收尾 |
| 端口占用 | `pkill -f 'web_server.py --port 8787'` 后重启 App |
| 设置打开崩溃 | 看 `/tmp/LiveFace-crash.log` 和 `logs/native-crash.log` |

---

## 13. 新会话交接检查清单

- [ ] 读本文件，确认最新 commit：`git log -1`（两个仓库）。
- [ ] `git status`：不要带入用户照片/日志/config/模型。
- [ ] App 仓库无 submodule；确认 `Deep-Live-Cam/modules/face_analyser.py` 存在，`./install.sh` 可执行。
- [ ] 运行 `./make_native_app.sh --install`，确认构建。
- [ ] 打开 App，确认后台 `ready`、摄像头/麦克风权限。
- [ ] 需要截图时只使用**临时空照片库**流程。
- [ ] 修改 App 根文件后同时同步 `LiveFace` 与公开 fork。
- [ ] 提交信息带 `Co-Authored-By: Claude Code <noreply@anthropic.com>`。
- [ ] 不提交任何用户数据；不把用户照片写入 README/issue/外部服务。

---

## 14. 当前运行时状态（参考）

- 正常 App 由 `~/Applications/LiveFace.app` 启动；后台由 App 管理。
- 服务状态：`GET http://127.0.0.1:8787/api/state`。
- 默认设置：检测间隔 3、发送画质 85、输出画质 90、换脸人数 1、换头关闭、强度 90、缩放 100、偏移 0/0；采集 720p；面部增强关闭。
- 用户本地的照片库/录制目录属于用户；文档与仓库不包含其内容。
- 最新功能提交见第 2 节；交接文档提交在其后。

---

**隐私底线：用户的人像照片、录音、录制文件、日志中的个人信息，永远不进入仓库、README、截图或外部服务。**
