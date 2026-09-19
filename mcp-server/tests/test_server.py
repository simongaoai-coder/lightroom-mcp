"""
Tests for server.py using mock_lr.py as the Lightroom backend.
Run with: pytest tests/ -v   (from mcp-server/ with venv active)
"""
import asyncio
import base64


# ── Protocol / existing commands ────────────────────────────────────────────

def test_ping(mock_lr):
    import server
    result = server.send_to_lightroom({"command": "ping"})
    assert result["success"] is True


def test_get_settings_defaults(mock_lr):
    import server
    result = server.send_to_lightroom({"command": "get_settings"})
    assert result["success"] is True
    s = result["data"]["settings"]
    assert s["Exposure"] == 0
    assert s["Temperature"] == 6500


def test_apply_settings_persists(mock_lr):
    import server
    server.send_to_lightroom({"command": "apply_settings", "settings": {"Exposure": 1.5}})
    result = server.send_to_lightroom({"command": "get_settings"})
    assert result["data"]["settings"]["Exposure"] == 1.5


def test_auto_tone(mock_lr):
    import server
    result = server.send_to_lightroom({"command": "auto_tone"})
    assert result["success"] is True
    settings = server.send_to_lightroom({"command": "get_settings"})["data"]["settings"]
    assert settings["Highlights"] == -30


def test_reset_clears_settings(mock_lr):
    import server
    server.send_to_lightroom({"command": "apply_settings", "settings": {"Exposure": 2.0}})
    server.send_to_lightroom({"command": "reset"})
    result = server.send_to_lightroom({"command": "get_settings"})
    assert result["data"]["settings"]["Exposure"] == 0


# ── export_preview ───────────────────────────────────────────────────────────

def test_export_preview_returns_jpeg(mock_lr):
    import server
    result = server.send_to_lightroom({"command": "export_preview", "size": 200})
    assert result["success"] is True
    raw = base64.b64decode(result["data"])
    assert raw[:2] == b"\xff\xd8", "Response is not a JPEG"


def test_export_preview_mcp_tool_returns_image_content(mock_lr):
    import server
    from mcp import types
    contents = asyncio.run(server.call_tool("lr_export_preview", {}))
    assert len(contents) == 1
    img = contents[0]
    assert isinstance(img, types.ImageContent)
    assert img.mimeType == "image/jpeg"
    raw = base64.b64decode(img.data)
    assert raw[:2] == b"\xff\xd8"


# ── batch_apply_settings ────────────────────────────────────────────────────

# ── lr_add_mask ──────────────────────────────────────────────────────────────

def test_add_mask_no_adjustments(mock_lr):
    import server
    result = server.send_to_lightroom({"command": "add_mask", "maskType": "subject"})
    assert result["success"] is True
    assert result["data"]["maskType"] == "subject"


def test_add_mask_with_adjustments(mock_lr):
    import server
    result = server.send_to_lightroom({
        "command": "add_mask",
        "maskType": "sky",
        "adjustments": {"Exposure": -0.5, "Highlights": -40},
    })
    assert result["success"] is True
    assert result["data"]["maskType"] == "sky"
    assert result["data"]["adjustments"]["Exposure"] == -0.5


def test_add_mask_mcp_tool(mock_lr):
    import json
    import server
    from mcp import types
    contents = asyncio.run(server.call_tool(
        "lr_add_mask",
        {"maskType": "subject", "adjustments": {"Clarity": 30, "Dehaze": 20}},
    ))
    assert len(contents) == 1
    assert isinstance(contents[0], types.TextContent)
    data = json.loads(contents[0].text)
    assert data["success"] is True


# ── lr_update_mask ────────────────────────────────────────────────────────────

def test_update_mask_protocol(mock_lr):
    import server
    result = server.send_to_lightroom({
        "command": "update_mask",
        "adjustments": {"Exposure": 1.0, "Saturation": -20},
    })
    assert result["success"] is True
    assert result["data"]["adjustments"]["Exposure"] == 1.0


def test_update_mask_no_adjustments(mock_lr):
    import server
    result = server.send_to_lightroom({
        "command": "update_mask",
        "adjustments": {},
    })
    assert result["success"] is False
    assert "adjustments" in result["error"].lower()


def test_update_mask_mcp_tool(mock_lr):
    import json
    import server
    from mcp import types
    contents = asyncio.run(server.call_tool(
        "lr_update_mask",
        {"adjustments": {"Highlights": -50, "Clarity": 20}},
    ))
    assert len(contents) == 1
    assert isinstance(contents[0], types.TextContent)
    data = json.loads(contents[0].text)
    assert data["success"] is True


# ── batch_apply_settings ────────────────────────────────────────────────────

def test_batch_apply_settings_protocol(mock_lr):
    import server
    result = server.send_to_lightroom({
        "command": "batch_apply_settings",
        "settings": {"LuminanceSmoothing": 50},
    })
    assert result["success"] is True
    assert result["applied"] == 3   # mock has 3 default photos
    assert result["skipped"] == 0


def test_batch_apply_settings_mcp_tool(mock_lr):
    import json
    import server
    from mcp import types
    contents = asyncio.run(server.call_tool(
        "lr_batch_apply_settings",
        {"settings": {"ColorNoiseReduction": 40}},
    ))
    assert len(contents) == 1
    assert isinstance(contents[0], types.TextContent)
    data = json.loads(contents[0].text)
    assert data["applied"] == 3
    assert data["skipped"] == 0
