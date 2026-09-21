#!/usr/bin/env python3
"""
Mock Lightroom file-IPC server for testing without Lightroom open.
Dev/test only — never deployed or referenced by Claude Desktop.

Polls /tmp/lr_mcp_req.json every 50ms and writes /tmp/lr_mcp_res.json.

Usage:
    python3 mock_lr.py
"""

from mock_masks import MockMasks
from mock_versions import MockVersions
from history_tools import HISTORY_COMMANDS
from mock_history import MockHistory
from mock_fine import MockFine
from appearance_tools import APPEARANCE_COMMANDS
from mock_library import MockLibrary
from navigation_tools import GEOMETRY_COMMANDS, NAVIGATION_COMMANDS
from mock_navigation import MockNavigation
from mock_healing import MockHealing
from healing_tools import HEALING_COMMANDS
from library_tools import LIBRARY_COMMANDS, DELIVERY_COMMANDS
from workflow_tools import PREVIEW_COMMANDS, RELATIVE_COMMANDS
from mock_workflows import MockWorkflows
from fine_tools import FINE_COMMANDS, MASK_FINE_COMMANDS
from version_tools import VERSION_COMMANDS
from mask_tools import MASK_COMMANDS

import base64
import io
import json
import os
import threading
import time

try:
    from PIL import Image
    HAS_PILLOW = True
except ImportError:
    HAS_PILLOW = False

REQ_FILE = os.environ.get("LR_MCP_REQ", "/tmp/lr_mcp_req.json")
RES_FILE = os.environ.get("LR_MCP_RES", "/tmp/lr_mcp_res.json")
POLL = 0.05

_DEFAULT_SETTINGS = {
    "Exposure": 0, "Contrast": 0, "Highlights": 0, "Shadows": 0,
    "Whites": 0, "Blacks": 0, "Clarity": 0, "Dehaze": 0,
    "Vibrance": 0, "Saturation": 0, "Temperature": 6500, "Tint": 0,
    "Sharpness": 25, "LuminanceSmoothing": 0, "ColorNoiseReduction": 25,
    "HueAdjustmentRed": 0, "HueAdjustmentOrange": 0, "HueAdjustmentYellow": 0,
    "HueAdjustmentGreen": 0, "HueAdjustmentAqua": 0, "HueAdjustmentBlue": 0,
    "HueAdjustmentPurple": 0, "HueAdjustmentMagenta": 0,
    "SaturationAdjustmentRed": 0, "SaturationAdjustmentOrange": 0,
    "SaturationAdjustmentYellow": 0, "SaturationAdjustmentGreen": 0,
    "SaturationAdjustmentAqua": 0, "SaturationAdjustmentBlue": 0,
    "SaturationAdjustmentPurple": 0, "SaturationAdjustmentMagenta": 0,
    "LuminanceAdjustmentRed": 0, "LuminanceAdjustmentOrange": 0,
    "LuminanceAdjustmentYellow": 0, "LuminanceAdjustmentGreen": 0,
    "LuminanceAdjustmentAqua": 0, "LuminanceAdjustmentBlue": 0,
    "LuminanceAdjustmentPurple": 0, "LuminanceAdjustmentMagenta": 0,
    "GrainAmount": 0, "PostCropVignetteAmount": 0,
    "PerspectiveVertical": 0, "PerspectiveHorizontal": 0, "PerspectiveRotate": 0,
}

_AUTO_TONE = {
    "Exposure": 0.5, "Highlights": -30, "Shadows": 20, "Whites": 10, "Blacks": -10,
}

_DEFAULT_PHOTOS = ["DSC_001.NEF", "DSC_002.NEF", "DSC_003.NEF"]


def _make_jpeg(settings: dict, size: int) -> str:
    """Return a base64-encoded JPEG; color shifts with Temperature."""
    temp = settings.get("Temperature", 6500)
    ratio = max(0.0, min(1.0, (temp - 2000) / 48000))
    r = int(220 * (0.5 + 0.5 * (1 - ratio)))
    g = 180
    b = int(220 * (0.3 + 0.7 * ratio))
    if HAS_PILLOW:
        img = Image.new("RGB", (size, max(1, size * 2 // 3)), color=(r, g, b))
        buf = io.BytesIO()
        img.save(buf, format="JPEG", quality=85)
        return base64.b64encode(buf.getvalue()).decode()
    # Minimal valid 1x1 white JPEG when Pillow is absent
    minimal = (
        b"\xff\xd8\xff\xe0\x00\x10JFIF\x00\x01\x01\x00\x00\x01\x00\x01\x00\x00"
        b"\xff\xdb\x00C\x00\x08\x06\x06\x07\x06\x05\x08\x07\x07\x07\t\t"
        b"\x08\n\x0c\x14\r\x0c\x0b\x0b\x0c\x19\x12\x13\x0f\x14\x1d\x1a"
        b"\x1f\x1e\x1d\x1a\x1c\x1c $.' \",#\x1c\x1c(7),01444\x1f'9=82<.342\xc7"
        b"\xff\xc0\x00\x0b\x08\x00\x01\x00\x01\x01\x01\x11\x00"
        b"\xff\xc4\x00\x1f\x00\x00\x01\x05\x01\x01\x01\x01\x01\x01\x00\x00"
        b"\x00\x00\x00\x00\x00\x00\x01\x02\x03\x04\x05\x06\x07\x08\t\n\x0b"
        b"\xff\xda\x00\x08\x01\x01\x00\x00?\x00\xf5\x00\xff\xd9"
    )
    return base64.b64encode(minimal).decode()


class _State:
    def __init__(self):
        self.settings = dict(_DEFAULT_SETTINGS)
        self.photos = list(_DEFAULT_PHOTOS)
        self.rating = 0
        self.mask_state = MockMasks()
        self.version_state = MockVersions(self)
        self.history_state = MockHistory(self)
        self.fine_state = MockFine(self)
        self.library_state = MockLibrary(self)
        self.workflow_state = MockWorkflows(self.library_state)
        self.navigation_state = MockNavigation()
        self.healing_state = MockHealing()
        self._lock = threading.Lock()

    def handle(self, req: dict) -> dict:
        cmd = req.get("command")
        with self._lock:
            if cmd in PREVIEW_COMMANDS.values() or cmd in RELATIVE_COMMANDS.values():
                return self.workflow_state.handle(req)
            if cmd in HISTORY_COMMANDS.values():
                return self.history_state.handle(req)
            if cmd in GEOMETRY_COMMANDS.values() or cmd in NAVIGATION_COMMANDS.values():
                return self.navigation_state.handle(req)
            if cmd in HEALING_COMMANDS.values():
                return self.healing_state.handle(req)
            if cmd in LIBRARY_COMMANDS.values() or cmd in DELIVERY_COMMANDS.values():
                return self.library_state.handle(req)
            if cmd in FINE_COMMANDS.values() or cmd in MASK_FINE_COMMANDS.values() or cmd in APPEARANCE_COMMANDS.values():
                return self.fine_state.handle(req)
            if cmd in VERSION_COMMANDS.values():
                return self.version_state.handle(req)
            if cmd in MASK_COMMANDS.values():
                return self.mask_state.handle({k: v for k, v in req.items() if k not in {"requestId", "expectedPluginVersion"}})
            if cmd == "ping":
                return {"success": True, "message": "Mock LR Bridge running", "version": "2.11.0", "protocolVersion": 2}

            if cmd == "get_settings":
                return {
                    "success": True,
                    "data": {
                        "filename": self.photos[0] if self.photos else "none",
                        "rating": self.rating,
                        "settings": dict(self.settings),
                    },
                }

            if cmd == "apply_settings":
                s = req.get("settings", {})
                self.settings.update(s)
                return {"success": True, "message": f"Applied: {', '.join(s)}"}

            if cmd == "batch_apply_settings":
                s = req.get("settings", {})
                self.settings.update(s)
                n = len(self.photos)
                return {"success": True, "applied": n, "skipped": 0,
                        "message": f"Applied to {n} photos, 0 skipped"}

            if cmd == "auto_tone":
                self.settings.update(_AUTO_TONE)
                return {"success": True, "message": "Auto tone applied"}

            if cmd == "reset":
                self.settings = dict(_DEFAULT_SETTINGS)
                self.mask_state.masks = []
                self.mask_state.selected = self.mask_state.tool = None
                return {"success": True, "message": "All develop settings reset"}

            if cmd == "export_preview":
                size = max(1, min(int(req.get("size", 200)), 2048))
                b64 = _make_jpeg(self.settings, size)
                return {
                    "success": True,
                    "data": b64,
                    "width": size,
                    "height": size * 2 // 3,
                }

            return {"success": False, "error": f"Unknown command: {cmd}"}


def serve() -> None:
    state = _State()
    # Clean up stale files
    for f in (REQ_FILE, RES_FILE):
        if os.path.exists(f):
            os.remove(f)
    print("Mock LR Bridge running (file IPC mode)", flush=True)
    print(f"  Watching: {REQ_FILE}", flush=True)
    print(f"  Writing:  {RES_FILE}", flush=True)
    try:
        while True:
            if os.path.exists(REQ_FILE):
                try:
                    with open(REQ_FILE, "r") as f:
                        req = json.load(f)
                    os.remove(REQ_FILE)
                    resp = state.handle(req)
                    resp["requestId"] = req.get("requestId")
                    tmp = RES_FILE + ".tmp"
                    with open(tmp, "w") as f:
                        json.dump(resp, f)
                    os.replace(tmp, RES_FILE)
                    print(
                        f"  {req.get('command')} → {resp.get('success')}", flush=True)
                except Exception as exc:
                    # Write error response so server.py doesn't time out
                    tmp = RES_FILE + ".tmp"
                    with open(tmp, "w") as f:
                        json.dump({"success": False, "error": str(exc)}, f)
                    os.replace(tmp, RES_FILE)
            time.sleep(POLL)
    except KeyboardInterrupt:
        pass
    finally:
        for f in (REQ_FILE, RES_FILE):
            if os.path.exists(f):
                os.remove(f)


if __name__ == "__main__":
    serve()
