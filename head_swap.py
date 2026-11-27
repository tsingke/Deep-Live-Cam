"""Experimental 2D head transfer.

The face swapper only replaces the face region.  This module adds the source
person's head silhouette / hair / ears around the face:

1. Build a soft head mask from the source photo once (GrabCut + an
   ellipse around the face), so the source background is removed.
2. Warp that head image and mask onto the target using the five face
   landmarks (eyes, nose, mouth corners).
3. Keep the target's swapped face visible by cutting a feathered face
   oval out of the transferred head, and limit the transfer to the
   target head ellipse.

It is deliberately conservative and marked experimental in the UI: a
single frontal source photo and a frontal/near-frontal target work best.
No extra models are downloaded.
"""
from __future__ import annotations

from typing import Any, Optional, Tuple

import cv2
import numpy as np

MAX_SIDE = 1280
_GRABCUT_ITERS = 4


def _face_kps(face: Any) -> Optional[np.ndarray]:
    kps = getattr(face, "kps", None)
    if kps is None:
        return None
    try:
        arr = np.asarray(kps, dtype=np.float32)
    except Exception:
        return None
    if arr.shape != (5, 2) or not np.isfinite(arr).all():
        return None
    return arr


def _bbox(face: Any) -> Optional[np.ndarray]:
    b = getattr(face, "bbox", None)
    if b is None:
        return None
    try:
        arr = np.asarray(b, dtype=np.float32).reshape(-1)
    except Exception:
        return None
    if arr.size < 4 or not np.isfinite(arr[:4]).all():
        return None
    return arr[:4]


def _ellipse_mask(
    shape: Tuple[int, int],
    center: Tuple[float, float],
    axes: Tuple[float, float],
    blur: float = 0.0,
) -> np.ndarray:
    h, w = shape
    mask = np.zeros((h, w), dtype=np.float32)
    cv2.ellipse(
        mask,
        (int(round(center[0])), int(round(center[1]))),
        (max(3, int(round(axes[0]))), max(3, int(round(axes[1])))),
        0, 0, 360, 1.0, -1,
    )
    if blur > 0:
        k = max(3, int(round(blur * min(h, w))) | 1)
        mask = cv2.GaussianBlur(mask, (k, k), 0)
    return mask


def _vision_person_mask(img: np.ndarray) -> Optional[np.ndarray]:
    """Apple Vision person segmentation (foreground 0..1) if available.

    This is what lets hair survive on dark backgrounds where GrabCut tends
    to swallow it.  Runs once per source photo; the app is macOS-only.
    """
    try:
        import Vision
        import Quartz
        from Foundation import NSData, NSDictionary
        from Quartz import CIImage
    except Exception:
        return None
    try:
        h, w = img.shape[:2]
        ok, buf = cv2.imencode(".jpg", img, [cv2.IMWRITE_JPEG_QUALITY, 92])
        if not ok:
            return None
        data = buf.tobytes()
        ci = CIImage.imageWithData_(NSData.dataWithBytes_length_(data, len(data)))
        if ci is None:
            return None
        req = Vision.VNGeneratePersonSegmentationRequest.alloc() \
            .initWithCompletionHandler_(None)
        req.setQualityLevel_(
            Vision.VNGeneratePersonSegmentationRequestQualityLevelAccurate
        )
        req.setOutputPixelFormat_(Quartz.kCVPixelFormatType_OneComponent8)
        handler = Vision.VNImageRequestHandler.alloc() \
            .initWithCIImage_options_(ci, NSDictionary.dictionary())
        ok, err = handler.performRequests_error_([req], None)
        if not ok or err is not None or not req.results():
            return None
        pb = req.results()[0].pixelBuffer()
        if pb is None:
            return None
        Quartz.CVPixelBufferLockBaseAddress(pb, 0)
        try:
            mw = Quartz.CVPixelBufferGetWidth(pb)
            mh = Quartz.CVPixelBufferGetHeight(pb)
            stride = Quartz.CVPixelBufferGetBytesPerRow(pb)
            base = Quartz.CVPixelBufferGetBaseAddress(pb)
            view = base.as_buffer(mh * stride)
            mask = np.frombuffer(view, dtype=np.uint8).reshape(mh, stride)[:, :mw]
            mask = np.ascontiguousarray(mask)
        finally:
            Quartz.CVPixelBufferUnlockBaseAddress(pb, 0)
        mask = cv2.resize(mask, (w, h), interpolation=cv2.INTER_LINEAR)
        return mask.astype(np.float32) / 255.0
    except Exception:
        return None


def _build_source_alpha(img: np.ndarray, face: Any) -> Optional[np.ndarray]:
    """Soft alpha for the source head, with the photo background removed."""
    bbox = _bbox(face)
    if bbox is None:
        return None
    h, w = img.shape[:2]
    x1, y1, x2, y2 = [float(v) for v in bbox]
    x1 = max(0.0, min(w - 1.0, x1))
    x2 = max(x1 + 1.0, min(float(w - 1), x2))
    y1 = max(0.0, min(h - 1.0, y1))
    y2 = max(y1 + 1.0, min(float(h - 1), y2))
    fw, fh = x2 - x1, y2 - y1
    cx = (x1 + x2) / 2.0
    cy = y1 + 0.36 * fh
    rx = max(8.0, 1.08 * fw)
    ry = max(8.0, 1.08 * fh)

    outer = _ellipse_mask((h, w), (cx, cy), (rx, ry))
    # Definite foreground: the face core.  Probable foreground: the whole
    # head ellipse.  Everything else starts as background.
    face_core = _ellipse_mask((h, w), ((x1 + x2) / 2.0, (y1 + y2) / 2.0),
                              (0.52 * fw, 0.66 * fh))
    gc = np.full((h, w), cv2.GC_BGD, dtype=np.uint8)
    gc[outer > 0.5] = cv2.GC_PR_FGD
    gc[face_core > 0.5] = cv2.GC_FGD

    rx0 = max(0, int(cx - rx * 1.08))
    ry0 = max(0, int(cy - ry * 1.08))
    rx1 = min(w - 1, int(cx + rx * 1.08))
    ry1 = min(h - 1, int(cy + ry * 1.08))
    rect = (rx0, ry0, max(rx0 + 2, rx1 - rx0), max(ry0 + 2, ry1 - ry0))

    person = _vision_person_mask(img)
    if person is not None:
        fg = np.clip(person, 0.0, 1.0).astype(np.float32)
    else:
        fg = outer.copy()
        try:
            bgd = np.zeros((1, 65), np.float64)
            fgd = np.zeros((1, 65), np.float64)
            cv2.grabCut(img, gc, rect, bgd, fgd, _GRABCUT_ITERS, cv2.GC_INIT_WITH_MASK)
            fg = np.where((gc == cv2.GC_FGD) | (gc == cv2.GC_PR_FGD), 1.0, 0.0).astype(np.float32)
        except Exception:
            pass

    fg *= outer
    fg = cv2.morphologyEx(
        fg, cv2.MORPH_CLOSE,
        cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (7, 7)),
    )
    fg = cv2.morphologyEx(
        fg, cv2.MORPH_OPEN,
        cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (5, 5)),
    )
    # Slightly soften the outer head boundary.
    fg = cv2.GaussianBlur(fg, (0, 0), max(2.0, 0.010 * min(h, w)))
    # Always fade the ellipse edge, even if GrabCut leaked.
    edge = _ellipse_mask((h, w), (cx, cy), (rx * 1.02, ry * 1.02),
                         blur=0.018)
    # Fade out below the neck so a shoulder/garment cannot leak in.
    fade = np.ones((h, w), dtype=np.float32)
    fade_top = int(round(y2 - 0.10 * fh))
    fade_bottom = int(round(y2 + 0.18 * fh))
    if fade_bottom > fade_top:
        ramp = np.linspace(1.0, 0.0, max(2, fade_bottom - fade_top), dtype=np.float32)
        fade[fade_top:fade_bottom, :] = ramp[:, None]
        fade[fade_bottom:, :] = 0.0
    edge *= fade
    # Cut the source face out completely.  The target face is filled by the
    # face swapper, so only hair / forehand rim / ears / head outline should
    # be transferred; otherwise the source cheeks appear as a bright halo.
    face_cut = _ellipse_mask(
        (h, w), ((x1 + x2) / 2.0, y1 + 0.50 * fh),
        (0.68 * fw, 0.60 * fh), blur=0.012,
    )
    return np.clip(fg * edge * (1.0 - face_cut), 0.0, 1.0).astype(np.float32)


def build_source_head_assets(
    img: np.ndarray, face: Any, max_side: int = MAX_SIDE
) -> Optional[Tuple[np.ndarray, np.ndarray, np.ndarray]]:
    """Return (head_bgr, head_alpha, five_landmarks) in a manageable size."""
    kps = _face_kps(face)
    if kps is None:
        return None
    if img is None or img.size == 0:
        return None

    h, w = img.shape[:2]
    scale = min(1.0, float(max_side) / float(max(h, w)))
    if scale < 0.999:
        small = cv2.resize(
            img, (max(1, int(round(w * scale))), max(1, int(round(h * scale)))),
            interpolation=cv2.INTER_AREA,
        )
        kps = kps * scale
    else:
        small = img

    # A light copy of the face object with scaled coordinates keeps this
    # module independent of insightface internals.
    class _ScaledFace:
        pass

    sf = _ScaledFace()
    bbox = _bbox(face)
    if bbox is None:
        return None
    sf.bbox = bbox * scale
    sf.kps = kps

    alpha = _build_source_alpha(small, sf)
    if alpha is None or float(alpha.max()) < 0.05:
        return None
    return small, alpha, kps


def apply_head_transfer(
    frame: np.ndarray,
    head_img: np.ndarray,
    head_alpha: np.ndarray,
    head_kps: np.ndarray,
    target_face: Any,
    strength: float = 1.0,
    scale: float = 1.0,
    offset_y_ratio: float = 0.0,
    offset_x_ratio: float = 0.0,
) -> np.ndarray:
    """Composite the source head ring onto frame, keeping the target face.

    strength  0..1  overall head-transfer opacity (0 = face-only result)
    scale     0.8..1.2  scale around the target face centre
    offset_y_ratio -0.2..0.2  vertical offset relative to target face height
    """
    if strength <= 0.0:
        return frame
    tgt_kps = _face_kps(target_face)
    bbox = _bbox(target_face)
    if tgt_kps is None or bbox is None or head_img is None or head_alpha is None:
        return frame

    # Similarity transform from source landmarks to target landmarks.
    # LMEDS is robust to small landmark errors; fall back to a plain fit.
    try:
        matrix, _ = cv2.estimateAffinePartial2D(
            head_kps, tgt_kps, method=cv2.LMEDS
        )
    except Exception:
        matrix = None
    if matrix is None:
        try:
            matrix, _ = cv2.estimateAffinePartial2D(head_kps, tgt_kps)
        except Exception:
            matrix = None
    if matrix is None or not np.isfinite(matrix).all():
        return frame

    bbox_tmp = _bbox(target_face)
    if bbox_tmp is None:
        return frame
    tx1, ty1, tx2, ty2 = [float(v) for v in bbox_tmp]
    fw_tmp = max(1.0, tx2 - tx1)
    fh_tmp = max(1.0, ty2 - ty1)
    tcx = (tx1 + tx2) / 2.0
    tcy = (ty1 + ty2) / 2.0

    if abs(scale - 1.0) > 1e-4:
        m3 = np.vstack([matrix, [0.0, 0.0, 1.0]])
        s3 = np.array(
            [[scale, 0.0, tcx * (1.0 - scale)],
             [0.0, scale, tcy * (1.0 - scale)],
             [0.0, 0.0, 1.0]],
            dtype=np.float64,
        )
        matrix = (s3 @ m3)[:2, :]
    if abs(offset_y_ratio) > 1e-4:
        matrix[1, 2] += float(offset_y_ratio) * fh_tmp
    if abs(offset_x_ratio) > 1e-4:
        matrix[0, 2] += float(offset_x_ratio) * fw_tmp

    h, w = frame.shape[:2]
    warped = cv2.warpAffine(
        head_img, matrix, (w, h),
        flags=cv2.INTER_LINEAR,
        borderMode=cv2.BORDER_REFLECT_101,
    )
    warped_alpha = cv2.warpAffine(
        head_alpha, matrix, (w, h),
        flags=cv2.INTER_LINEAR,
        borderMode=cv2.BORDER_CONSTANT,
        borderValue=0,
    )

    x1, y1, x2, y2 = [float(v) for v in bbox]
    fw = max(1.0, x2 - x1)
    fh = max(1.0, y2 - y1)
    cx = (x1 + x2) / 2.0
    cy = (y1 + y2) / 2.0

    # Only transfer within the target's head area; the target's already
    # swapped face is cut out of the transfer.
    head_region = _ellipse_mask(
        (h, w), (cx, cy - 0.03 * fh), (1.10 * fw, 1.22 * fh), blur=0.012
    )
    face_hole = _ellipse_mask(
        (h, w), (cx, cy), (0.60 * fw, 0.58 * fh), blur=0.014
    )
    alpha = np.clip(
        warped_alpha * head_region * (1.0 - face_hole) * float(strength),
        0.0, 1.0,
    )
    alpha = cv2.GaussianBlur(alpha, (0, 0), max(1.0, 0.004 * min(h, w)))
    if float(alpha.max()) < 0.02:
        return frame

    a = alpha[:, :, None]
    out = frame.astype(np.float32) * (1.0 - a) + warped.astype(np.float32) * a
    return np.clip(out, 0.0, 255.0).astype(np.uint8)
