"""Head-transfer smoke tests. No models, no people, no network."""
from __future__ import annotations

import sys
import unittest
from pathlib import Path
from types import SimpleNamespace

import cv2
import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from head_swap import _ellipse_mask, apply_head_transfer  # noqa: E402


def make_head(
    w: int, h: int, cx: int, cy: int, rx: int, ry: int,
    bg: tuple[int, int, int],
) -> np.ndarray:
    img = np.full((h, w, 3), bg, np.uint8)
    cv2.ellipse(img, (cx, cy + ry + 70), (int(rx * 1.5), int(ry * 0.65)), 0, 0, 360, (60, 70, 90), -1)
    cv2.ellipse(img, (cx, cy - 10), (int(rx * 1.05), int(ry * 0.95)), 0, 0, 360, (40, 45, 60), -1)
    cv2.ellipse(img, (cx, cy + 15), (int(rx * 0.85), int(ry * 0.85)), 0, 0, 360, (150, 175, 210), -1)
    return img


class HeadTransferTests(unittest.TestCase):
    def setUp(self) -> None:
        self.source = make_head(640, 640, 320, 300, 120, 150, (25, 35, 45))
        alpha = _ellipse_mask((640, 640), (320, 300), (140, 170))
        alpha *= 1.0 - _ellipse_mask((640, 640), (320, 300), (80, 100))
        self.alpha = np.clip(alpha, 0, 1).astype(np.float32)
        self.source_kps = np.array(
            [[275, 300], [365, 300], [320, 335], [290, 365], [350, 365]],
            np.float32,
        )
        self.target = make_head(1280, 720, 800, 340, 110, 145, (20, 25, 35))
        self.target_bbox = np.array([690, 270, 910, 470], np.float32)
        self.target_kps = np.array(
            [[745, 340], [855, 340], [800, 375], [770, 405], [830, 405]],
            np.float32,
        )
        self.face = SimpleNamespace(bbox=self.target_bbox, kps=self.target_kps)

    def test_zero_strength_returns_input(self) -> None:
        out = apply_head_transfer(
            self.target, self.source, self.alpha,
            self.source_kps, self.face, strength=0.0,
        )
        np.testing.assert_array_equal(out, self.target)

    def test_transfer_changes_pixels(self) -> None:
        out = apply_head_transfer(
            self.target, self.source, self.alpha,
            self.source_kps, self.face, strength=1.0,
        )
        self.assertEqual(out.shape, self.target.shape)
        self.assertFalse(np.array_equal(out, self.target))
        self.assertLessEqual(int(out.min()), int(out.max()))

    def test_scale_and_offsets_are_finite(self) -> None:
        for scale, ox, oy in ((0.9, -0.1, 0.1), (1.1, 0.1, -0.1)):
            out = apply_head_transfer(
                self.target, self.source, self.alpha,
                self.source_kps, self.face,
                strength=0.85, scale=scale,
                offset_x_ratio=ox, offset_y_ratio=oy,
            )
            self.assertEqual(out.shape, self.target.shape)
            self.assertTrue(np.isfinite(out).all())

    def test_invalid_landmarks_returns_input(self) -> None:
        bad = np.zeros((4, 2), np.float32)
        out = apply_head_transfer(
            self.target, self.source, self.alpha, bad, self.face,
        )
        np.testing.assert_array_equal(out, self.target)


if __name__ == "__main__":
    unittest.main()
