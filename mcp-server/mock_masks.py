"""Stateful mask backend for the development-only Lightroom simulator."""
from copy import deepcopy

from mask_tools import AUTOMATIC_TYPES, LOCAL_INDEX, validate_mask_call


class MockMasks:
    def __init__(self):
        self.photo_id = "mock-photo-1"
        self.next_id = 3
        self.selected = "mask-1"
        self.tool = "tool-1"
        self.masks = [
            {"id": "mask-1", "name": "Sky", "tools": [
                {"id": "tool-1", "type": "aiSelection", "subtype": "sky"},
                {"id": "tool-2", "type": "brush"},
            ], "adjustments": {"Exposure": 0}},
            {"id": "mask-2", "name": "Subject", "tools": [
                {"id": "tool-3", "type": "aiSelection", "subtype": "subject"},
            ], "adjustments": {"Exposure": 0}},
        ]

    def snapshot(self):
        data = {"photoId": self.photo_id}
        if self.selected:
            data["selectedMaskId"] = self.selected
        if self.tool:
            data["selectedToolId"] = self.tool
        return data

    def listing(self):
        return [{k: deepcopy(v) for k, v in m.items() if k != "adjustments"} for m in self.masks]

    def handle(self, req):
        cmd = req["command"]
        error = validate_mask_call("lr_" + cmd, {k: v for k, v in req.items() if k != "command"})
        if error:
            return {"success": False, "code": "invalid_arguments", "error": error}
        if req.get("expectedPhotoId", self.photo_id) != self.photo_id:
            return {"success": False, "code": "photo_changed", "error": "Current photo does not match expectedPhotoId"}
        mask_id = req.get("maskId", self.selected)
        mask = next((m for m in self.masks if m["id"] == mask_id), None)
        if cmd in {"select_mask", "update_mask", "delete_mask", "delete_mask_tool"}:
            if not mask:
                return {"success": False, "code": "mask_not_found" if mask_id else "no_mask_selected", "error": "Mask not found or no mask selected"}
            tool_id = req.get("toolId")
            if tool_id and not any(t["id"] == tool_id for t in mask["tools"]):
                return {"success": False, "code": "tool_not_found", "error": "Tool does not belong to mask"}
            if "maskId" in req:
                self.selected = mask_id
                self.tool = tool_id or (mask["tools"][0]["id"] if mask["tools"] else None)
        data = self.snapshot()
        if cmd == "list_masks":
            data["masks"] = self.listing()
        elif cmd == "get_selected_mask":
            if mask:
                data["adjustments"] = dict(mask["adjustments"])
        elif cmd == "update_mask":
            values = {LOCAL_INDEX[k.lower()]: v for k, v in req["adjustments"].items()}
            mask["adjustments"].update(values)
            data.update(maskId=mask_id, adjustments=values)
        elif cmd in {"delete_mask", "delete_mask_tool"}:
            if cmd == "delete_mask_tool":
                mask["tools"] = [t for t in mask["tools"] if t["id"] != req["toolId"]]
                if not mask["tools"]:
                    self.masks.remove(mask)
                    self.selected = None
                self.tool = mask["tools"][0]["id"] if mask["tools"] else None
            else:
                self.masks.remove(mask)
                self.selected = self.tool = None
            data = self.snapshot()
            data.update(maskId=mask_id, masks=self.listing())
            if cmd == "delete_mask_tool":
                data.update(deletedToolId=req["toolId"], parentMaskDeleted=not mask["tools"])
            else:
                data["deletedMaskId"] = mask_id
        elif cmd == "add_mask":
            kind = req["maskType"]
            values = {LOCAL_INDEX[k.lower()]: v for k, v in req.get("adjustments", {}).items()}
            data["maskType"] = kind
            if kind not in AUTOMATIC_TYPES:
                data.update(status="awaiting_user_input", adjustmentsDeferred=bool(values))
            else:
                new_id = f"mask-{self.next_id}"
                new_tool = f"new-tool-{self.next_id}"
                self.next_id += 1
                self.masks.append({"id": new_id, "name": kind, "tools": [
                    {"id": new_tool, "type": "aiSelection", "subtype": kind},
                ], "adjustments": values})
                self.selected, self.tool = new_id, new_tool
                data = self.snapshot()
                data.update(maskId=new_id, maskType=kind, status="created")
                if values:
                    data["adjustments"] = values
        return {"success": True, "data": deepcopy(data), "message": f"{cmd}: {data.get('status', 'verified')}"}
