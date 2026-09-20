"""MCP schemas and transport-side validation for mask management."""
import math

from mcp import types

MASK_COMMANDS = {f"lr_{name}": name for name in (
    "list_masks", "get_selected_mask", "select_mask", "update_mask",
    "delete_mask", "delete_mask_tool", "add_mask",
)}
MASK_TYPES = {
    "subject", "sky", "background", "objects", "people", "landscape",
    "luminance", "color", "depth", "gradient", "radialGradient", "brush",
}
AUTOMATIC_TYPES = {"subject", "sky", "background"}
LOCAL_PARAMS = (
    "Exposure Contrast Highlights Shadows Whites Blacks Clarity Texture Dehaze "
    "Vibrance Saturation Temperature Tint Sharpness LuminanceNoise ColorNoise "
    "MoireFilter Moire Defringe ToningHue ToningSaturation Hue Amount Grain RefineSaturation"
).split()
LOCAL_INDEX = {name.lower(): name for name in LOCAL_PARAMS}
LOCAL_INDEX["moirefilter"] = "Moire"


def management_tools():
    id_schema = {"type": "string", "minLength": 1}
    definitions = [
        ("list_masks", "List current photo's masks and component tools, including IDs, names, types and selected IDs.", []),
        ("get_selected_mask", "Read selected mask/tool IDs and available local slider values. No selection is a valid empty result.", []),
        ("select_mask", "Select maskId and optionally toolId belonging to that mask; verify selection before returning.", ["maskId"]),
        ("delete_mask", "Delete the explicitly identified mask and verify removal. Obtain its ID from lr_list_masks.", ["maskId"]),
        ("delete_mask_tool", "Delete toolId within maskId and verify removal. Removing the last tool may remove its parent mask.", ["maskId", "toolId"]),
    ]
    result = []
    for name, description, required in definitions:
        props = {"expectedPhotoId": {**id_schema, "description": "Optional photoId from lr_list_masks; reject if the photo changed."}}
        for key in required:
            props[key] = dict(id_schema)
        if name == "select_mask":
            props["toolId"] = dict(id_schema)
        result.append(types.Tool(name=f"lr_{name}", description=description, inputSchema={
            "type": "object", "properties": props, "required": required,
            "additionalProperties": False,
        }))
    return result


def validate_mask_call(name, arguments):
    if not isinstance(arguments, dict):
        return "Arguments must be an object"
    allowed = {"expectedPhotoId"}
    if name in {"lr_select_mask", "lr_delete_mask", "lr_delete_mask_tool", "lr_update_mask"}:
        allowed.add("maskId")
    if name in {"lr_select_mask", "lr_delete_mask_tool"}:
        allowed.add("toolId")
    if name in {"lr_add_mask", "lr_update_mask"}:
        allowed.add("adjustments")
    if name == "lr_add_mask":
        allowed.update({"maskType", "params"})
    if set(arguments) - allowed:
        return "Unknown arguments: " + ", ".join(sorted(set(arguments) - allowed))
    for key in ("maskId", "toolId", "expectedPhotoId"):
        if key in arguments and (not isinstance(arguments[key], str) or not arguments[key].strip()):
            return f"{key} must be a non-empty string"
    if name in {"lr_select_mask", "lr_delete_mask", "lr_delete_mask_tool"} and "maskId" not in arguments:
        return "maskId is required"
    if name == "lr_delete_mask_tool" and "toolId" not in arguments:
        return "toolId is required"
    if name == "lr_add_mask":
        if not isinstance(arguments.get("maskType"), str) or arguments["maskType"] not in MASK_TYPES:
            return "Unknown or missing maskType"
        if "params" in arguments and arguments["params"] != {}:
            return "params must be empty; mask geometry is not supported by the SDK creation API"
    if name == "lr_update_mask" and not arguments.get("adjustments"):
        return "No adjustments provided"
    if "adjustments" in arguments:
        values = arguments["adjustments"]
        if not isinstance(values, dict):
            return "adjustments must be an object"
        seen = set()
        for key, value in values.items():
            canonical = LOCAL_INDEX.get(key.lower()) if isinstance(key, str) else None
            if not canonical:
                return f"Unsupported local parameter: {key}"
            if canonical in seen:
                return f"Duplicate local parameter: {key}"
            seen.add(canonical)
            if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value):
                return f"{key} must be a finite number"
    return None
