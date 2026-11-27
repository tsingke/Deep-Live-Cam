"""Server API smoke test in an isolated, empty-photo project.

It starts the real aiohttp service (with CoreML models loaded) on a free port,
then checks state/config clamping/upload rejection/frame protocol. It never
touches the app's photos, recordings or user media.
"""
from __future__ import annotations

import json
import os
import socket
import struct
import subprocess
import sys
import tempfile
import time
import unittest
import urllib.request
from pathlib import Path

import cv2
import numpy as np

ROOT = Path(__file__).resolve().parents[1]


def _free_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.bind(("127.0.0.1", 0))
        return int(sock.getsockname()[1])


class ServerApiSmoke(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.tmp = Path(tempfile.mkdtemp(prefix="LiveFaceApiSmoke-"))
        (cls.tmp / "web").mkdir()
        (cls.tmp / "photos").mkdir()
        (cls.tmp / "logs").mkdir()

        dlc = ROOT / "Deep-Live-Cam"
        if not (dlc / "modules").is_dir():
            dlc = ROOT
        os.symlink(dlc, cls.tmp / "Deep-Live-Cam")
        os.symlink(ROOT / ".venv", cls.tmp / ".venv")
        for name in ("web_server.py", "head_swap.py"):
            (cls.tmp / name).write_bytes((ROOT / name).read_bytes())

        cls.port = _free_port()
        cls.base = f"http://127.0.0.1:{cls.port}"
        cls.log = (cls.tmp / "server.log").open("w")
        cls.proc = subprocess.Popen(
            [str(cls.tmp / ".venv/bin/python"), "web_server.py", "--port", str(cls.port)],
            cwd=str(cls.tmp),
            stdout=cls.log,
            stderr=subprocess.STDOUT,
        )
        deadline = time.time() + 120
        while time.time() < deadline:
            if cls.proc.poll() is not None:
                break
            try:
                state = cls._get("/api/state", timeout=2)
                if state.get("ready"):
                    return
            except Exception:
                pass
            time.sleep(1)
        cls.log.flush()
        tail = (cls.tmp / "server.log").read_text(errors="replace")[-4000:]
        raise RuntimeError(f"server did not become ready\n{tail}")

    @classmethod
    def tearDownClass(cls) -> None:
        try:
            cls._post("/api/shutdown", {}, timeout=3)
        except Exception:
            pass
        try:
            cls.proc.wait(timeout=10)
        except Exception:
            cls.proc.terminate()
        try:
            cls.log.close()
        except Exception:
            pass
        import shutil
        shutil.rmtree(cls.tmp, ignore_errors=True)

    @classmethod
    def _get(cls, path: str, timeout: float = 10) -> dict:
        with urllib.request.urlopen(cls.base + path, timeout=timeout) as response:
            return json.loads(response.read().decode())

    @classmethod
    def _post(cls, path: str, body: dict, timeout: float = 10) -> dict:
        request = urllib.request.Request(
            cls.base + path,
            data=json.dumps(body).encode(),
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return json.loads(response.read().decode())

    def test_01_state_ready_and_empty(self) -> None:
        state = self._get("/api/state")
        self.assertTrue(state["ready"])
        self.assertEqual(state["photos"], [])
        self.assertIn("CoreMLExecutionProvider", state.get("providers", []))
        self.assertEqual(state["settings"]["detect_interval"], 3)
        self.assertEqual(state["settings"]["head_swap"], False)

    def test_02_config_is_clamped_and_persisted(self) -> None:
        response = self._post("/api/config", {
            "detect_interval": 99,
            "jpeg_quality": 1,
            "sharpen": 999,
            "swap_count": 99,
            "head_swap": True,
            "head_strength": 999,
            "head_scale": 1,
            "head_offset_y": 999,
            "head_offset_x": -999,
        })
        self.assertTrue(response["ok"])
        self.assertEqual(response["detect_interval"], 12)
        self.assertEqual(response["jpeg_quality"], 50)
        self.assertEqual(response["sharpen"], 100)
        self.assertEqual(response["swap_count"], 6)
        self.assertEqual(response["head_strength"], 100)
        self.assertEqual(response["head_scale"], 85)
        self.assertEqual(response["head_offset_y"], 20)
        self.assertEqual(response["head_offset_x"], -20)
        saved = json.loads((self.tmp / "config.json").read_text())
        self.assertTrue(saved["head_swap"])

    def test_03_upload_without_face_is_rejected(self) -> None:
        image = np.zeros((320, 320, 3), np.uint8)
        cv2.rectangle(image, (40, 40), (280, 280), (180, 180, 180), -1)
        ok, encoded = cv2.imencode(".png", image)
        self.assertTrue(ok)
        boundary = "LiveFaceSmokeBoundary"
        body = (
            f"--{boundary}\r\n"
            'Content-Disposition: form-data; name="photos"; filename="synthetic.png"\r\n'
            "Content-Type: image/png\r\n\r\n"
        ).encode() + encoded.tobytes() + f"\r\n--{boundary}--\r\n".encode()
        request = urllib.request.Request(
            self.base + "/api/upload", data=body,
            headers={"Content-Type": f"multipart/form-data; boundary={boundary}"},
            method="POST",
        )
        with urllib.request.urlopen(request, timeout=20) as response:
            result = json.loads(response.read().decode())
        self.assertTrue(result["ok"])
        self.assertEqual(result["added"], [])
        self.assertTrue(result["errors"])
        self.assertEqual(self._get("/api/state")["photos"], [])

    def test_04_frame_protocol_without_face(self) -> None:
        image = np.zeros((360, 640, 3), np.uint8)
        image[:] = (30, 60, 90)
        ok, encoded = cv2.imencode(".jpg", image, [cv2.IMWRITE_JPEG_QUALITY, 80])
        self.assertTrue(ok)
        packet = struct.pack("<d", time.time()) + encoded.tobytes()
        request = urllib.request.Request(
            self.base + "/api/frame?s=smoke",
            data=packet,
            headers={"Content-Type": "application/octet-stream"},
            method="POST",
        )
        with urllib.request.urlopen(request, timeout=30) as response:
            data = response.read()
            self.assertEqual(response.status, 200)
            self.assertEqual(data[:2], b"\xff\xd8")
            self.assertEqual(response.headers.get("X-Detected"), "0")
            self.assertEqual(response.headers.get("X-Swapped"), "0")


if __name__ == "__main__":
    unittest.main()
