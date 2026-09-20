#!/usr/bin/env python3
"""
Claude Lightroom MCP Server
Exposes Lightroom develop controls as MCP tools for Claude Desktop.
Communicates with the Lua plugin running inside Lightroom via file-based IPC.
"""

import base64
import io
import json
import os
import time
import math
import uuid
import threading
if os.name == "nt":
    import msvcrt
else:
    import fcntl
from jsonschema import Draft7Validator
from pathlib import Path

from mcp import types
from mcp.server import Server
from mcp.server.stdio import stdio_server

from mask_tools import management_tools, validate_mask_call, MASK_COMMANDS
from version_tools import version_tools, VERSION_COMMANDS
from fine_tools import fine_tools, FINE_COMMANDS, MASK_FINE_COMMANDS
from history_tools import history_tools, HISTORY_COMMANDS
from navigation_tools import navigation_tools, GEOMETRY_COMMANDS, NAVIGATION_COMMANDS
from appearance_tools import appearance_tools, APPEARANCE_COMMANDS
from healing_tools import healing_tools, HEALING_COMMANDS
from library_tools import library_tools, LIBRARY_COMMANDS, DELIVERY_COMMANDS

REQ_FILE = os.environ.get("LR_MCP_REQ", "/tmp/lr_mcp_req.json")
RES_FILE = os.environ.get("LR_MCP_RES", "/tmp/lr_mcp_res.json")
SERVER_VERSION = "2.7.0"
PROTOCOL_VERSION = 2
_IPC_LOCK = threading.Lock()
TIMEOUT = 10.0   # seconds to wait for Lua to respond
POLL = 0.05   # seconds between polls
TARGET_IMAGE_BYTES = 1 * 1024 * 1024  # 1 MB target for preview images


def _compress_preview(b64_data: str, max_long_edge: int = 1500, orientation=1) -> str:
    """Resize, correct orientation, and compress preview to stay under TARGET_IMAGE_BYTES."""
    from PIL import Image

    raw = base64.b64decode(b64_data)
    img = Image.open(io.BytesIO(raw))

    # LR getRawMetadata("orientation") two-letter codes indicate where the stored top/right edges are:
    # "AB"=normal, "BC"=stored 90°CCW (top→right), "CD"=stored 180°, "DA"=stored 90°CW (top→left)
    _LR_ORIENT_ROTATE = {
        "BC": Image.Transpose.ROTATE_270,  # stored 90°CCW → rotate 90°CW to correct
        "CD": Image.Transpose.ROTATE_180,
        "DA": Image.Transpose.ROTATE_90,   # stored 90°CW → rotate 90°CCW to correct
    }
    transpose_op = _LR_ORIENT_ROTATE.get(str(orientation) if orientation else "AB")
    if transpose_op is not None:
        img = img.transpose(transpose_op)

    img.thumbnail((max_long_edge, max_long_edge), Image.LANCZOS)

    for quality in (85, 75, 60, 45):
        buf = io.BytesIO()
        img.save(buf, format="JPEG", quality=quality)
        if buf.tell() <= TARGET_IMAGE_BYTES:
            return base64.b64encode(buf.getvalue()).decode("ascii")

    return base64.b64encode(buf.getvalue()).decode("ascii")


app = Server("lightroom-bridge")


def _exchange(command: dict, timeout: float) -> dict:
    request_id = uuid.uuid4().hex
    payload = {**command, "requestId": request_id, "expectedPluginVersion": SERVER_VERSION}
    if os.path.exists(RES_FILE):
        os.remove(RES_FILE)
    tmp = REQ_FILE + ".tmp"
    with open(tmp, "w") as f:
        json.dump(payload, f, allow_nan=False, ensure_ascii=False)
    os.replace(tmp, REQ_FILE)
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if os.path.exists(RES_FILE):
            try:
                with open(RES_FILE) as f:
                    result = json.load(f)
            except (json.JSONDecodeError, FileNotFoundError):
                time.sleep(POLL)
                continue
            os.remove(RES_FILE)
            if not isinstance(result, dict):
                return {"success": False, "code": "invalid_response", "error": "Expected an object response"}
            # Older plugins do not echo IDs. Only allow their read-only ping so
            # version diagnostics can explain the required deployment update.
            if result.get("requestId") == request_id or (
                command.get("command") == "ping" and "requestId" not in result
            ):
                return result
        time.sleep(POLL)
    # Remove only our own unclaimed request; a claimed operation can still finish.
    try:
        with open(REQ_FILE) as f:
            pending = json.load(f)
        if pending.get("requestId") == request_id:
            os.remove(REQ_FILE)
    except (FileNotFoundError, ValueError):
        pass
    return {"success": False, "code": "timeout", "requestId": request_id,
            "outcomeUnknown": command.get("command") not in {"ping", "get_settings", "list_presets", "list_snapshots", "list_virtual_copies", "get_curve", "list_point_colors", "get_selection", "search_photos", "get_metadata", "list_keywords", "list_collections", "get_export_status", "list_spots", "get_selected_spot", "get_remove_preferences", "get_ai_update_status", "get_appearance", "list_profiles", "get_geometry", "get_navigation", "list_folders", "list_folder_photos", "get_history_state"},
            "error": "Lightroom did not respond in time. An accepted operation may still finish; read back state before retrying."}


def send_to_lightroom(command: dict, timeout: float = TIMEOUT) -> dict:
    """Serialize clients and correlate responses; never mutate an older plugin."""
    try:
        with _IPC_LOCK, open(REQ_FILE + ".lock", "a+") as lock:
            deadline = time.monotonic() + timeout
            while True:
                try:
                    if os.name == "nt":
                        lock.seek(0)
                        if not lock.read(1):
                            lock.write("0")
                            lock.flush()
                        lock.seek(0)
                        msvcrt.locking(lock.fileno(), msvcrt.LK_NBLCK, 1)
                    else:
                        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    break
                except OSError as exc:
                    if exc.errno not in {11, 13, 35}:
                        raise
                    if time.monotonic() >= deadline:
                        return {"success": False, "code": "bridge_busy", "error": "Another MCP client is using Lightroom"}
                    time.sleep(POLL)
            if command.get("command") != "ping":
                health = _exchange({"command": "ping"}, min(timeout, 5))
                if not health.get("success"):
                    return health
                if health.get("version") != SERVER_VERSION or health.get("protocolVersion") != PROTOCOL_VERSION:
                    return {"success": False, "code": "version_mismatch",
                            "error": "Update/reload the Lightroom plugin and restart the MCP client",
                            "serverVersion": SERVER_VERSION, "pluginVersion": health.get("version")}
            return _exchange(command, timeout)
    except Exception as exc:
        return {"success": False, "code": "transport_error", "error": str(exc)}


def validate_settings(arguments):
    if not isinstance(arguments, dict) or set(arguments) - {"settings", "expectedPhotoId"}:
        return "Expected settings and optional expectedPhotoId"
    settings = arguments.get("settings")
    if not isinstance(settings, dict) or not settings:
        return "No settings provided"
    seen = set()
    for key, value in settings.items():
        if not isinstance(key, str) or not key.strip():
            return "Parameter names must be non-empty strings"
        if key.lower() in seen:
            return "Duplicate parameter: " + key
        seen.add(key.lower())
        if isinstance(value, bool) or not isinstance(value, (float, int)) or not math.isfinite(value):
            return key + " must be a finite number"
    expected = arguments.get("expectedPhotoId")
    if expected is not None and (not isinstance(expected, str) or not expected.strip()):
        return "expectedPhotoId must be a non-empty string"
    return None


@app.list_tools()
async def list_tools() -> list[types.Tool]:
    tools = management_tools() + version_tools() + fine_tools() + library_tools() + healing_tools() + appearance_tools() + navigation_tools() + history_tools() + [
        types.Tool(
            name="lr_apply_settings",
            description=(
                "Apply develop settings to the currently selected photo in Lightroom Classic. "
                "Pass a dict of parameter names and values. "
                "Tone: Exposure (-5 to 5), Contrast (-100 to 100), "
                "Highlights (-100 to 100), Shadows (-100 to 100), Whites (-100 to 100), "
                "Blacks (-100 to 100). "
                "Presence: Clarity (-100 to 100), Texture (-100 to 100), "
                "Dehaze (-100 to 100), Vibrance (-100 to 100), Saturation (-100 to 100). "
                "Color: Temperature (2000-50000 K), Tint (-150 to 150). "
                "Detail: Sharpness (0-150), LuminanceSmoothing (0-100), ColorNoiseReduction (0-100). "
                "HSL: HueAdjustmentRed/Orange/Yellow/Green/Aqua/Blue/Purple/Magenta (-100 to 100). "
                "Effects: GrainAmount (0-100), PostCropVignetteAmount (-100 to 100). "
                "Transform: PerspectiveVertical/Horizontal (-100 to 100), PerspectiveRotate (-10 to 10), "
                "PerspectiveScale (50-150), PerspectiveAspect (-100 to 100), "
                "PerspectiveX/Y (-100 to 100), PerspectiveUpright (0=off,1=auto,2=level,3=vertical,4=full). "
                "Color Grading: ColorGradeBlending (0-100), "
                "ColorGradeGlobalHue/Lum/Sat, ColorGradeMidtoneHue/Lum/Sat (Hue 0-360, Lum/Sat -100 to 100), "
                "ColorGradeHighlightLum (-100 to 100), ColorGradeShadowLum (-100 to 100). "
                "B&W Mix: GrayMixerRed/Orange/Yellow/Green/Aqua/Blue/Purple/Magenta (-100 to 100). "
                "Split Toning: SplitToningBalance (-100 to 100), SplitToningHighlightHue/Saturation, SplitToningShadowHue/Saturation. "
                "Defringe: DefringeGreenAmount/HueHi/HueLo, DefringePurpleAmount/HueHi/HueLo (0-100)."
            ),
            inputSchema={
                "type": "object",
                "properties": {
                    "settings": {
                        "type": "object",
                        "description": "Key-value pairs of Lightroom develop parameters",
                        "additionalProperties": {"type": "number"},
                    }
                },
                "required": ["settings"],
            },
        ),
        types.Tool(
            name="lr_get_settings",
            description=(
                "Get the current develop settings and metadata of the selected photo "
                "in Lightroom Classic. Returns all current slider values, filename, and rating."
            ),
            inputSchema={"type": "object", "properties": {}},
        ),
        types.Tool(
            name="lr_auto_tone",
            description=(
                "Apply Lightroom's Auto Tone to the selected photo. "
                "This is equivalent to clicking the Auto button in the Tone section."
            ),
            inputSchema={"type": "object", "properties": {}},
        ),
        types.Tool(
            name="lr_reset",
            description=(
                "Reset all develop settings on the selected photo back to defaults. "
                "Use with caution - this clears all edits."
            ),
            inputSchema={"type": "object", "properties": {}},
        ),
        types.Tool(
            name="lr_ping",
            description="Check if the Lightroom bridge is connected and running.",
            inputSchema={"type": "object", "properties": {}},
        ),
        types.Tool(
            name="lr_export_preview",
            description=(
                "Export a JPEG preview of the currently selected photo in Lightroom Classic "
                "and return it as an image. Claude can see the photo and give visual feedback "
                "on develop settings, tone, color, composition, etc. "
                "Call this before and after applying settings to compare results."
            ),
            inputSchema={
                "type": "object",
                "properties": {
                    "size": {
                        "type": "integer",
                        "description": "Long-edge pixel size of the JPEG (default 1500, max 2048)",
                    }
                },
            },
        ),
        types.Tool(
            name="lr_batch_apply_settings",
            description=(
                "Apply develop settings to ALL currently selected photos in Lightroom Classic. "
                "Useful for batch operations like denoising a series of shots, "
                "applying a consistent grade across a set, etc. "
                "Uses the same parameter names and ranges as lr_apply_settings."
            ),
            inputSchema={
                "type": "object",
                "properties": {
                    "settings": {
                        "type": "object",
                        "description": "Key-value pairs of Lightroom develop parameters to apply to all selected photos",
                        "additionalProperties": {"type": "number"},
                    }
                },
                "required": ["settings"],
            },
        ),
        types.Tool(
            name="lr_crop",
            description=(
                "Crop and/or straighten the selected photo in Lightroom Classic. "
                "Specify crop bounds as normalized coordinates (0.0–1.0) and/or a straighten angle. "
                "All parameters are optional — only provided values are changed. "
                "angle: straighten rotation in degrees (-45 to 45). "
                "CropTop/CropBottom/CropLeft/CropRight: crop boundary (0.0=edge, 1.0=opposite edge)."
            ),
            inputSchema={
                "type": "object",
                "properties": {
                    "angle": {"type": "number", "description": "Straighten angle in degrees (-45 to 45)"},
                    "CropTop":    {"type": "number", "description": "Top crop boundary (0.0–1.0)"},
                    "CropBottom": {"type": "number", "description": "Bottom crop boundary (0.0–1.0)"},
                    "CropLeft":   {"type": "number", "description": "Left crop boundary (0.0–1.0)"},
                    "CropRight":  {"type": "number", "description": "Right crop boundary (0.0–1.0)"},
                },
            },
        ),
        types.Tool(
            name="lr_lens_blur",
            description=(
                "Apply AI Lens Blur (depth-of-field effect) to the selected photo in Lightroom Classic. "
                "Uses an AI-generated depth map to blur foreground/background. "
                "Parameters: "
                "active (bool — enable/disable lens blur; omitted leaves current state), "
                "amount (0-100, blur strength), "
                "bokeh (shape of out-of-focus highlights: 'Circle', 'SoapBubble', 'Blade', 'Ring', 'Anamorphic'), "
                "catEye (0-100, cat-eye vignetting on bokeh), "
                "highlightsBoost (0-100, boost specular highlights in blur), "
                "focalRangeFromSubject (bool, auto-set focal range to focus on the main subject)."
            ),
            inputSchema={
                "type": "object",
                "properties": {
                    "active": {"type": "boolean", "description": "Enable or disable lens blur; omitted leaves current state"},
                    "amount": {"type": "number", "description": "Blur strength (0-100)"},
                    "bokeh": {
                        "type": "string",
                        "description": "Bokeh shape",
                        "enum": ["Circle", "SoapBubble", "Blade", "Ring", "Anamorphic"],
                    },
                    "catEye": {"type": "number", "description": "Cat-eye vignetting on bokeh highlights (0-100)"},
                    "highlightsBoost": {"type": "number", "description": "Boost specular highlights in blur (0-100)"},
                    "focalRangeFromSubject": {
                        "type": "boolean",
                        "description": "Auto-set focal range from the AI-detected subject",
                    },
                },
            },
        ),
        types.Tool(
            name="lr_enhance",
            description=(
                "Run Lightroom's AI Enhance on the selected photo. "
                "Supports: AI Denoise (reduces noise using machine learning), "
                "Super Resolution (upscales image to 2× using AI), "
                "Raw Details (improves demosaicing of RAW files). "
                "Requires the runtime setEnhance API; check lr_ping capabilities. Returns unsupported_api when absent. Output and processing behavior depend on Lightroom version. "
                "Parameters: denoise (bool), denoiseAmount (0-100, strength of noise reduction), "
                "superRes (bool), rawDetails (bool)."
            ),
            inputSchema={
                "type": "object",
                "properties": {
                    "denoise": {"type": "boolean", "description": "Enable AI Denoise"},
                    "denoiseAmount": {"type": "number", "description": "Denoise strength (0-100)"},
                    "superRes": {"type": "boolean", "description": "Enable Super Resolution (2× upscale)"},
                    "rawDetails": {"type": "boolean", "description": "Enable Raw Details (improved RAW demosaicing)"},
                },
            },
        ),
        types.Tool(
            name="lr_add_mask",
            description=(
                "Add a mask to the selected photo in Lightroom Classic. "
                "AI selection types: 'subject', 'sky', 'background', 'objects', 'people', 'landscape'. "
                "Range selection types: 'luminance', 'color', 'depth'. "
                "Manual types (user must draw after calling): 'gradient' (linear), 'radialGradient' (elliptical), 'brush'. "
                "Returns a new maskId when available. Interactive types return awaiting_user_input; "
                "adjustments are deferred until you draw/sample and call lr_update_mask. "
                "Only subject, sky and background are treated as automatic."
            ),
            inputSchema={
                "type": "object",
                "properties": {
                    "expectedPhotoId": {"type": "string", "minLength": 1},
                    "maskType": {
                        "type": "string",
                        "description": "Type of mask to create",
                        "enum": ["subject", "sky", "background", "objects", "people", "landscape",
                                 "luminance", "color", "depth",
                                 "gradient", "radialGradient", "brush"],
                    },
                    "params": {
                        "type": "object",
                        "description": "Reserved; must be empty. The SDK creation API does not accept geometry parameters.",
                        "additionalProperties": False,
                    },
                    "adjustments": {
                        "type": "object",
                        "description": (
                            "Optional develop sliders to apply to the new mask "
                            "(e.g. {\"Exposure\": 0.5, \"Highlights\": -30, \"Saturation\": 20}). "
                            "Keys are the same parameter names as lr_apply_settings but applied "
                            "locally to only this mask. Supported: Exposure, Contrast, Highlights, "
                            "Shadows, Whites, Blacks, Clarity, Texture, Dehaze, Vibrance, "
                            "Saturation, Temperature, Tint, Sharpness, LuminanceNoise, ColorNoise, "
                            "MoireFilter, Defringe, ToningHue, ToningSaturation."
                        ),
                        "additionalProperties": {"type": "number"},
                    },
                },
                "required": ["maskType"],
                "additionalProperties": False,
            },
        ),
        types.Tool(
            name="lr_update_mask",
            description=(
                "Update local develop sliders on maskId, or on the currently selected mask if omitted. "
                "An invalid maskId fails without editing another mask. Call "
                "this tool with the slider values to apply. Supported: Exposure, Contrast, "
                "Highlights, Shadows, Whites, Blacks, Clarity, Texture, Dehaze, Vibrance, "
                "Saturation, Temperature, Tint, Sharpness, LuminanceNoise, ColorNoise, "
                "MoireFilter, Defringe, ToningHue, ToningSaturation."
            ),
            inputSchema={
                "type": "object",
                "properties": {
                    "maskId": {"type": "string", "minLength": 1},
                    "expectedPhotoId": {"type": "string", "minLength": 1},
                    "adjustments": {
                        "type": "object",
                        "description": "Slider values to apply to the active mask (e.g. {\"Exposure\": 0.5, \"Highlights\": -30})",
                        "additionalProperties": {"type": "number"},
                    },
                },
                "required": ["adjustments"],
                "additionalProperties": False,
            },
        ),
    ]

    for tool in tools:
        if tool.name in {"lr_apply_settings", "lr_batch_apply_settings", "lr_get_settings"}:
            tool.inputSchema["properties"]["expectedPhotoId"] = {"type": "string", "minLength": 1}
            tool.inputSchema["additionalProperties"] = False
        if tool.name == "lr_get_settings":
            tool.inputSchema["properties"]["includeRaw"] = {"type": "boolean", "default": False}
            tool.description = "Read catalog numeric settings, photo ID, process version, actual parameter mappings and unavailable parameters. includeRaw also returns the full SDK settings table (read-only, potentially large)."
        if tool.name in {"lr_apply_settings", "lr_batch_apply_settings"}:
            tool.description = "Apply absolute numeric develop values using the same per-photo catalog mapping for single and batch edits. Names are case-insensitive. Use lr_get_settings to discover available parameters. Values are verified after writing; inspect per-photo results on failure. Temperature/Tint units depend on RAW versus rendered files. Only the current selection is targeted."
        if tool.name == "lr_ping":
            tool.description = "Inspect running plugin path/version, Lightroom version, SDK API availability, and this MCP process's tool names/version. Does not modify photos."
    for tool in tools:
        tool.inputSchema["additionalProperties"] = False
    for tool in tools:
        if tool.name in {"lr_add_mask", "lr_update_mask", "lr_get_selected_mask"}:
            tool.description += " Additional local numeric controls: Hue, Amount, Grain, RefineSaturation; availability/ranges depend on the current SDK/photo."
    return tools


@app.call_tool()
async def call_tool(name: str, arguments: dict) -> list[types.TextContent]:
    definition = next((tool for tool in await list_tools() if tool.name == name), None)
    if definition is not None:
        errors = list(Draft7Validator(definition.inputSchema).iter_errors(arguments))
        def nonfinite(value):
            if isinstance(value, float):
                return not math.isfinite(value)
            if isinstance(value, dict):
                return any(nonfinite(v) for v in value.values())
            if isinstance(value, list):
                return any(nonfinite(v) for v in value)
            return False
        if errors or nonfinite(arguments):
            result = {"success": False, "code": "invalid_arguments",
                      "error": errors[0].message if errors else "Numbers must be finite"}
            return [types.TextContent(type="text", text=json.dumps(result))]
    if name in HISTORY_COMMANDS:
        payload = {"command": HISTORY_COMMANDS[name], **arguments}
        if name in {"lr_copy_settings", "lr_get_history_state"}:
            payload["copyId" if name == "lr_copy_settings" else "historyToken"] = uuid.uuid4().hex
        result = send_to_lightroom(payload, timeout=120.0)

    elif name in HEALING_COMMANDS:
        payload = {"command": HEALING_COMMANDS[name], **arguments}
        job_id = uuid.uuid4().hex if name == "lr_update_ai_settings" else None
        if job_id:
            payload["jobId"] = job_id
        result = send_to_lightroom(payload, timeout=120.0)
        if job_id:
            result["jobId"] = job_id

    elif name in LIBRARY_COMMANDS or name in NAVIGATION_COMMANDS:
        result = send_to_lightroom({"command": (LIBRARY_COMMANDS | NAVIGATION_COMMANDS)[name], **arguments}, timeout=120.0)

    elif name in DELIVERY_COMMANDS:
        payload = {"command": DELIVERY_COMMANDS[name], **arguments}
        job_id = None
        if name == "lr_export_photos":
            if not os.path.isabs(arguments["destination"]):
                return [types.TextContent(type="text", text=json.dumps({"success": False, "code": "invalid_arguments", "error": "destination must be absolute"}))]
            payload["destination"] = os.path.realpath(arguments["destination"])
            job_id = uuid.uuid4().hex
            payload["jobId"] = job_id
        result = send_to_lightroom(payload, timeout=30.0)
        if job_id:
            result["jobId"] = job_id  # Reconcile an uncertain start via get_export_status.

    elif name in FINE_COMMANDS or name in MASK_FINE_COMMANDS or name in APPEARANCE_COMMANDS or name in GEOMETRY_COMMANDS:
        result = send_to_lightroom({"command": (FINE_COMMANDS | MASK_FINE_COMMANDS | APPEARANCE_COMMANDS | GEOMETRY_COMMANDS)[name], **arguments}, timeout=120.0)

    elif name in VERSION_COMMANDS:
        result = send_to_lightroom({"command": VERSION_COMMANDS[name], **arguments}, timeout=120.0)

    elif name in MASK_COMMANDS:
        error = validate_mask_call(name, arguments)
        if error:
            result = {"success": False, "code": "invalid_arguments", "error": error}
        else:
            result = send_to_lightroom(
                {"command": MASK_COMMANDS[name], **arguments},
                timeout=120.0 if name == "lr_add_mask" else 30.0,
            )

    elif name == "lr_ping":
        result = send_to_lightroom({"command": "ping"})
        names = [tool.name for tool in await list_tools()]
        result["server"] = {"version": SERVER_VERSION, "path": str(Path(__file__).resolve()),
                            "toolCount": len(names), "tools": names}
        result["compatible"] = (result.get("version") == SERVER_VERSION and result.get("protocolVersion") == PROTOCOL_VERSION)
        if result.get("success") and not result["compatible"]:
            result["warning"] = "Plugin/server versions differ; writes are blocked until deployment is updated."

    elif name == "lr_get_settings":
        if (not isinstance(arguments, dict) or set(arguments) - {"includeRaw", "expectedPhotoId"}
                or ("includeRaw" in arguments and not isinstance(arguments["includeRaw"], bool))
                or ("expectedPhotoId" in arguments and (not isinstance(arguments["expectedPhotoId"], str) or not arguments["expectedPhotoId"].strip()))):
            result = {"success": False, "code": "invalid_arguments", "error": "Invalid get_settings arguments"}
        else:
            result = send_to_lightroom({"command": "get_settings", **arguments})

    elif name == "lr_auto_tone":
        result = send_to_lightroom({"command": "auto_tone"})

    elif name == "lr_reset":
        result = send_to_lightroom({"command": "reset"})

    elif name in {"lr_apply_settings", "lr_batch_apply_settings"}:
        error = validate_settings(arguments)
        if error:
            result = {"success": False, "code": "invalid_arguments", "error": error}
        else:
            result = send_to_lightroom({"command": name.removeprefix("lr_"), **arguments}, timeout=120.0)

    elif name == "lr_export_preview":
        size = min(int(arguments.get("size", 1500)), 2048)
        result = send_to_lightroom(
            {"command": "export_preview", "size": size}, timeout=30.0)
        if result.get("success") and result.get("data"):
            img_data = _compress_preview(
                result["data"],
                max_long_edge=size,
                orientation=result.get("orientation", 1),
            )
            return [
                types.ImageContent(
                    type="image",
                    mimeType="image/jpeg",
                    data=img_data,
                )
            ]
        return [types.TextContent(type="text", text=json.dumps(result, indent=2))]

    elif name == "lr_crop":
        params = {k: v for k, v in arguments.items()}
        if not params:
            result = {"success": False, "error": "No crop parameters provided"}
        else:
            result = send_to_lightroom({"command": "crop", "params": params})

    elif name == "lr_lens_blur":
        params = {k: v for k, v in arguments.items()}
        if not params:
            result = {"success": False,
                      "error": "No lens blur parameters provided"}
        else:
            result = send_to_lightroom(
                {"command": "lens_blur", "params": params})

    elif name == "lr_enhance":
        params = {k: v for k, v in arguments.items()}
        if not params:
            result = {
                "success": False, "error": "No enhance parameters provided. Use: denoise, denoiseAmount, superRes, rawDetails"}
        else:
            result = send_to_lightroom(
                {"command": "enhance", "params": params})

    else:
        result = {"success": False, "error": f"Unknown tool: {name}"}

    if result.get("success") is False and "code" not in result:
        result["code"] = "operation_failed"
    return [types.TextContent(type="text", text=json.dumps(result, indent=2))]


async def main():
    async with stdio_server() as (read_stream, write_stream):
        await app.run(read_stream, write_stream, app.create_initialization_options())


if __name__ == "__main__":
    import asyncio
    asyncio.run(main())
