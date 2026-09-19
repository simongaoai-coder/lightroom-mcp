"""Execute the actual mask implementation in Lua 5.1 with a controlled SDK double."""
from pathlib import Path

import pytest
from lupa.lua51 import LuaRuntime

ROOT = Path(__file__).resolve().parents[2]
PLUGIN = ROOT / "lrplugin/lightroom-mcp.lrdevplugin"


@pytest.fixture
def sdk():
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.execute(Path(__file__).with_name("masking_fixture.lua").read_text())
    module = lua.execute((PLUGIN / "Masking.lua").read_text())
    def call(command, **kwargs):
        return module.handle(lua.table_from({"command": command, **kwargs}, recursive=True))
    return lua, lua.globals().state, call


def test_list_and_read_selected(sdk):
    _, state, call = sdk
    result = call("list_masks")
    assert result["success"]
    assert result["data"]["masks"][1]["id"] == "A"
    assert result["data"]["masks"][1]["name"] == "天空"
    assert result["data"]["masks"][1]["tools"][1]["subtype"] == "sky"
    assert result["data"]["selectedMaskId"] == "B"
    assert state.module == "develop" and state.panel == "masking"
    assert call("get_selected_mask")["data"]["adjustments"]["Exposure"] == 0


def test_update_a_while_b_selected(sdk):
    _, state, call = sdk
    result = call("update_mask", maskId="A", adjustments={"exposure": 1.25})
    assert result["success"]
    assert result["data"]["adjustments"]["Exposure"] == 1.25
    assert state["values"].A.local_Exposure == 1.25
    assert state["values"].B.local_Exposure == 0


@pytest.mark.parametrize("command,kwargs", [
    ("update_mask", {"maskId": "missing", "adjustments": {"Exposure": 1}}),
    ("delete_mask", {"maskId": "missing"}),
    ("select_mask", {"maskId": "A", "toolId": "B1"}),
    ("delete_mask_tool", {"maskId": "A", "toolId": "B1"}),
])
def test_invalid_target_preserves_state(sdk, command, kwargs):
    _, state, call = sdk
    assert not call(command, **kwargs)["success"]
    assert state.selected == "B" and state.writes == 0 and len(state.masks) == 2


def test_no_selected_mask_and_empty_list(sdk):
    lua, state, call = sdk
    state.selected, state.tool = None, None
    state.masks = lua.table()
    assert len(call("list_masks")["data"]["masks"]) == 0
    assert call("get_selected_mask")["data"]["selectedMaskId"] is None
    assert call("update_mask", adjustments={"Exposure": 1})["code"] == "no_mask_selected"


def test_select_tool_then_delete(sdk):
    _, state, call = sdk
    assert call("select_mask", maskId="A", toolId="A2")["data"]["selectedToolId"] == "A2"
    result = call("delete_mask_tool", maskId="A", toolId="A2")
    assert result["success"] and result["data"]["deletedToolId"] == "A2"
    assert len(state.masks[1].Tools) == 1
    assert call("delete_mask", maskId="A")["success"]
    assert len(state.masks) == 1 and state.masks[1].ID == "B"
    assert not call("delete_mask", maskId="A")["success"]


def test_delete_last_tool(sdk):
    _, state, call = sdk
    result = call("delete_mask_tool", maskId="B", toolId="B1")
    assert result["success"] and result["data"]["parentMaskDeleted"]
    assert len(state.masks) == 1


@pytest.mark.parametrize("flag,command,kwargs,code", [
    ("selectionNoop", "update_mask", {"maskId": "A", "adjustments": {"Exposure": 1}}, "selection_failed"),
    ("toolNoop", "select_mask", {"maskId": "A", "toolId": "A2"}, "selection_failed"),
    ("deleteNoop", "delete_mask", {"maskId": "A"}, "deletion_failed"),
    ("selectionError", "select_mask", {"maskId": "A"}, "sdk_error"),
    ("badSummary", "list_masks", {}, "unsupported_mask_data"),
])
def test_sdk_failure_is_reported(sdk, flag, command, kwargs, code):
    _, state, call = sdk
    state[flag] = True
    assert call(command, **kwargs)["code"] == code
    assert state.writes == 0


def test_photo_change_during_wait(sdk):
    _, state, call = sdk
    state.selectionNoop, state.switchPhoto = True, True
    assert call("update_mask", maskId="A", adjustments={"Exposure": 1})["code"] == "photo_changed"
    assert state.writes == 0


def test_expected_photo_and_missing_api(sdk):
    lua, state, call = sdk
    assert call("delete_mask", maskId="A", expectedPhotoId="other")["code"] == "photo_changed"
    lua.globals().controller.deleteMask = None
    assert call("delete_mask", maskId="A")["code"] == "unsupported_api"
    assert len(state.masks) == 2


@pytest.mark.parametrize("adjustments", [
    {"Exposure": 9}, {"Exposure": True}, {"Exposure": float("inf")},
    {"Exposure": float("nan")}, {"Exposure": 1, "exposure": 2},
    {"Unknown": 1}, {"ColorNoise": 1, "Exposure": 1}, {},
])
def test_validate_all_before_writing(sdk, adjustments):
    _, state, call = sdk
    assert not call("update_mask", adjustments=adjustments)["success"]
    assert state.writes == 0


def test_automatic_creation_and_update(sdk):
    _, state, call = sdk
    result = call("add_mask", maskType="sky", adjustments={"Exposure": -1})
    assert result["success"] and result["data"]["status"] == "created"
    mask_id = result["data"]["maskId"]
    assert mask_id not in {"A", "B"}
    assert state["values"][mask_id].local_Exposure == -1
    assert call("update_mask", maskId=mask_id, adjustments={"Exposure": 0.5})["success"]


@pytest.mark.parametrize("kind", ["brush", "gradient", "radialGradient", "people", "objects", "landscape", "color", "luminance", "depth"])
def test_interactive_creation_never_writes_old_mask(sdk, kind):
    _, state, call = sdk
    result = call("add_mask", maskType=kind, adjustments={"Exposure": -1})
    assert result["success"]
    assert result["data"]["status"] == "awaiting_user_input"
    assert result["data"]["adjustmentsDeferred"]
    assert state.writes == 0 and state["values"].B.local_Exposure == 0


def test_pending_automatic_creation_does_not_modify_existing(sdk):
    _, state, call = sdk
    state.createNoop = True
    result = call("add_mask", maskType="sky", adjustments={"Exposure": 1})
    assert result["data"]["status"] == "pending"
    assert result["data"]["maskId"] is None and state.writes == 0


def test_reject_ignored_geometry(sdk):
    _, state, call = sdk
    assert not call("add_mask", maskType="gradient", params={"angle": 30})["success"]
    assert state.creations is None


def test_all_plugin_files_parse_as_lua51():
    lua = LuaRuntime(unpack_returned_tuples=True)
    parse = lua.eval('function(code) local f, err = loadstring(code); assert(f, err) end')
    for path in PLUGIN.glob("*.lua"):
        parse(path.read_text())


def test_silent_slider_failure_is_not_success(sdk):
    _, state, call = sdk
    state.writeNoop = True
    result = call("update_mask", maskId="A", adjustments={"Exposure": 1})
    assert result["code"] == "readback_failed"
    assert result["data"]["adjustments"]["Exposure"] == 0


def test_selection_change_during_readback(sdk):
    _, state, call = sdk
    state.writeNoop, state.switchSelection = True, True
    result = call("update_mask", maskId="A", adjustments={"Exposure": 1})
    assert result["code"] == "selection_changed"
    assert state["values"].B.local_Exposure == 0


def test_sdk_slider_exception_does_not_kill_handler(sdk):
    _, state, call = sdk
    state.writeError = True
    assert call("update_mask", adjustments={"Exposure": 1})["code"] == "adjustment_failed"
    assert call("list_masks")["success"]


def test_created_id_survives_adjustment_failure(sdk):
    _, state, call = sdk
    state.writeError = True
    result = call("add_mask", maskType="sky", adjustments={"Exposure": 1})
    assert not result["success"]
    assert result["data"]["creationStatus"] == "created"
    assert result["data"]["maskId"] == "new-1"
    state.writeError = False
    assert call("update_mask", maskId="new-1", adjustments={"Exposure": 1})["success"]
    assert state.creations == 1


def test_no_photo_prevents_mutation(sdk):
    _, state, call = sdk
    state.photo = None
    assert call("delete_mask", maskId="A")["code"] == "no_photo"
    assert len(state.masks) == 2


@pytest.mark.parametrize("pending_value", [None, False])
def test_creation_waits_for_transient_nil_summary(sdk, pending_value):
    _, state, call = sdk
    state.createPendingReads = 3
    state.pendingValue = pending_value
    result = call("add_mask", maskType="sky", adjustments={"Exposure": -0.25})
    assert result["success"] and result["data"]["status"] == "created"
    assert result["data"]["adjustments"]["Exposure"] == -0.25


def test_deletion_waits_for_transient_nil_summary(sdk):
    _, state, call = sdk
    state.deletePendingReads = 3
    assert call("delete_mask", maskId="A")["success"]


def test_pending_summary_is_not_proof_of_deletion(sdk):
    _, state, call = sdk
    state.deletePendingReads, state.deleteNoop = 1000, True
    result = call("delete_mask", maskId="A")
    assert result["code"] == "deletion_failed"
    assert len(state.masks) == 2


def test_initial_empty_ui_summary_waits_for_catalog_masks(sdk):
    _, state, call = sdk
    state.emptyReads = 3
    result = call("list_masks")
    assert result["success"] and len(result["data"]["masks"]) == 2


def test_stale_ui_summary_is_not_reported_as_no_masks(sdk):
    _, state, call = sdk
    state.emptyReads = 1000
    assert call("list_masks")["code"] == "context_timeout"
