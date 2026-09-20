import asyncio
import json
import os
from pathlib import Path
import sys

import pytest
import server
from mask_tools import MASK_COMMANDS


def call(name, **kwargs):
    return json.loads(asyncio.run(server.call_tool(name, kwargs))[0].text)


def test_all_tools_registered_with_valid_schemas():
    from jsonschema import Draft202012Validator
    tools = asyncio.run(server.list_tools())
    names = [t.name for t in tools]
    assert len(names) == len(set(names)) ==93
    assert set(MASK_COMMANDS) <= set(names)
    for tool in tools:
        Draft202012Validator.check_schema(tool.inputSchema)


@pytest.mark.parametrize("name,args", [
    ("lr_select_mask", {}), ("lr_select_mask", {"maskId": " "}),
    ("lr_delete_mask", {}), ("lr_delete_mask_tool", {"maskId": "mask-1"}),
    ("lr_update_mask", {"maskId": "", "adjustments": {"Exposure": 1}}),
    ("lr_update_mask", {"adjustments": {"Exposure": True}}),
    ("lr_update_mask", {"adjustments": {"Exposure": float("nan")}}),
    ("lr_update_mask", {"adjustments": {"Exposure": float("inf")}}),
    ("lr_update_mask", {"adjustments": {"Exposure": 1, "exposure": 2}}),
    ("lr_update_mask", {"adjustments": {"global_Exposure": 1}}),
    ("lr_add_mask", {"maskType": "invalid"}),
    ("lr_add_mask", {"maskType": "sky", "params": {"angle": 10}}),
    ("lr_add_mask", {"maskType": "sky", "adjustments": []}),
    ("lr_list_masks", {"command": "delete_mask"}),
])
def test_invalid_input_never_reaches_ipc(monkeypatch, name, args):
    def forbidden(*args, **kwargs):
        raise AssertionError("Invalid input must not contact Lightroom")
    monkeypatch.setattr(server, "send_to_lightroom", forbidden)
    assert call(name, **args)["code"] == "invalid_arguments"


def test_mask_lifecycle_over_file_ipc(mock_lr):
    result = call("lr_list_masks")
    assert result["success"] and len(result["data"]["masks"]) == 2
    photo_id = result["data"]["photoId"]
    assert call("lr_select_mask", maskId="mask-2")["success"]
    updated = call("lr_update_mask", maskId="mask-1", expectedPhotoId=photo_id, adjustments={"Exposure": 1})
    assert updated["data"]["selectedMaskId"] == "mask-1"
    call("lr_select_mask", maskId="mask-2")
    assert call("lr_get_selected_mask")["data"]["adjustments"]["Exposure"] == 0
    assert not call("lr_update_mask", maskId="missing", adjustments={"Exposure": 2})["success"]
    assert call("lr_get_selected_mask")["data"]["selectedMaskId"] == "mask-2"
    assert not call("lr_delete_mask_tool", maskId="mask-1", toolId="tool-3")["success"]
    assert call("lr_select_mask", maskId="mask-1", toolId="tool-2")["data"]["selectedToolId"] == "tool-2"
    assert call("lr_delete_mask_tool", maskId="mask-1", toolId="tool-2")["success"]
    created = call("lr_add_mask", maskType="sky", adjustments={"Exposure": -0.5})
    mask_id = created["data"]["maskId"]
    assert call("lr_update_mask", maskId=mask_id, adjustments={"Highlights": -20})["success"]
    assert call("lr_delete_mask", maskId=mask_id)["success"]
    assert not call("lr_delete_mask", maskId=mask_id)["success"]
    assert not call("lr_delete_mask", maskId="mask-1", expectedPhotoId="wrong")["success"]


def test_deferred_creation_and_no_selection(mock_lr):
    before = call("lr_get_selected_mask")["data"]
    result = call("lr_add_mask", maskType="gradient", adjustments={"Exposure": 1})
    assert result["data"]["status"] == "awaiting_user_input"
    assert result["data"]["adjustmentsDeferred"]
    assert call("lr_get_selected_mask")["data"] == before
    call("lr_delete_mask", maskId="mask-1")
    assert not call("lr_update_mask", adjustments={"Exposure": 1})["success"]
    call("lr_delete_mask", maskId="mask-2")
    assert call("lr_list_masks")["data"]["masks"] == []


def test_mcp_stdio_roundtrip(mock_lr):
    from mcp import ClientSession, StdioServerParameters
    from mcp.client.stdio import stdio_client
    async def run():
        params = StdioServerParameters(command=sys.executable, args=[str(Path(server.__file__))], env=dict(os.environ))
        async with stdio_client(params) as (read, write):
            async with ClientSession(read, write) as session:
                await session.initialize()
                listing = await session.list_tools()
                assert len(listing.tools) ==93
                result = await session.call_tool("lr_list_masks", {})
                assert json.loads(result.content[0].text)["success"]
                result = await session.call_tool("lr_update_mask", {"maskId": "mask-2", "adjustments": {"Exposure": 0.75}})
                assert json.loads(result.content[0].text)["data"]["adjustments"]["Exposure"] == 0.75
    asyncio.run(run())
