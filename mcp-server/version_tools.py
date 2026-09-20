"""Schemas for photo versions and develop-preset reuse."""
from mcp import types

VERSION_COMMANDS = {f"lr_{name}": name for name in (
    "list_snapshots", "create_snapshot", "apply_snapshot", "delete_snapshot",
    "list_virtual_copies", "create_virtual_copies", "select_virtual_copy",
    "list_presets", "apply_preset",
)}


def version_tools():
    text = {"type": "string", "minLength": 1, "pattern": r"^(?=.*\S)[^\x00-\x1f\x7f]+$"}
    guard = {"expectedPhotoId": {**text, "description": "Reject if the active photo UUID changed."}}
    scope = {"type": "string", "enum": ["current", "selected"], "default": "current"}
    specs = [
        ("list_snapshots", "List current photo's develop snapshots with explicit IDs. Does not modify the photo.", {}, []),
        ("create_snapshot", "Save the current develop state as a named snapshot. A same-name snapshot fails unless updateExisting is explicitly true. Returns its ID after enumeration.",
         {"name": text, "updateExisting": {"type": "boolean", "default": False}}, ["name"]),
        ("apply_snapshot", "Restore an explicit snapshot ID on the current photo. Save a snapshot first if the current look must be preserved. Returns observed changes; SDK completion does not independently prove all snapshot values.",
         {"snapshotId": text}, ["snapshotId"]),
        ("delete_snapshot", "Delete an explicit snapshot ID on the current photo and verify its removal. Does not reset the current develop settings.",
         {"snapshotId": text}, ["snapshotId"]),
        ("list_virtual_copies", "List the current photo's master and sibling virtual copies with UUIDs and copy names.", {}, []),
        ("create_virtual_copies", "Create virtual copies of the current photo (default) or selected photos. Does not duplicate image files. Lightroom selects the new copies; returns their UUIDs. Do not blindly retry an uncertain outcome.",
         {"copyName": text, "scope": scope}, []),
        ("select_virtual_copy", "Select a master or virtual copy from the current photo's family by UUID, for comparing or editing saved versions. Other families are rejected.",
         {"photoId": text}, ["photoId"]),
        ("list_presets", "List SDK-visible develop presets with UUIDs and folder names. Search by literal name/folder text; pagination is sorted. Names may be duplicated; use presetId when applying.",
         {"query": {"type": "string"}, "offset": {"type": "integer", "minimum": 0, "default": 0},
          "limit": {"type": "integer", "minimum": 1, "maximum": 200, "default": 50}}, []),
        ("apply_preset", "Apply an explicit develop preset UUID to the current photo or selected photos. Optionally set amount (0-200) and request AI settings update. Returns per-photo SDK outcomes and observed changes, not guaranteed AI render completion. Save snapshots first when needed.",
         {"presetId": text, "scope": scope,
          "amount": {"type": "integer", "minimum": 0, "maximum": 200},
          "updateAISettings": {"type": "boolean", "default": False}}, ["presetId"]),
    ]
    return [types.Tool(name="lr_"+name, description=description, inputSchema={
        "type": "object", "properties": {**({} if name=="list_presets" else guard), **props},
        "required": required, "additionalProperties": False,
    }) for name, description, props, required in specs]
