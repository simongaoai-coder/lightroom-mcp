from pathlib import Path
import pytest
from lupa.lua51 import LuaRuntime
PLUGIN=Path(__file__).resolve().parents[2]/'lrplugin/lightroom-mcp.lrdevplugin'

@pytest.fixture
def sdk():
    lua=LuaRuntime(unpack_returned_tuples=True)
    for name in ['masking_fixture.lua','mask_fine_fixture.lua']:
        lua.execute(Path(__file__).with_name(name).read_text())
    m=lua.execute((PLUGIN/'Masking.lua').read_text())
    def call(cmd,**args):return m.handle(lua.table_from({'command':cmd,**args},recursive=True))
    return lua,lua.globals().state,call


@pytest.mark.parametrize('operation',['add','subtract','intersect'])
def test_combination_targets_mask(sdk,operation):
    _,state,call=sdk
    r=call('combine_mask',maskId='A',operation=operation,maskType='sky')
    assert r['success'] and r['data']['status']=='component_created'
    assert len(state.masks[1].Tools)==3 and len(state.masks[2].Tools)==1
    assert state.lastOperation==operation


def test_interactive_and_pending_components(sdk):
    _,state,call=sdk
    assert call('combine_mask',maskId='A',operation='add',maskType='brush')['data']['status']=='awaiting_user_input'
    state.combineNoop=True
    assert call('combine_mask',maskId='A',operation='subtract',maskType='subject')['data']['status']=='pending'


def test_visibility_and_component_inversion_are_idempotent(sdk):
    _,state,call=sdk
    assert call('set_mask_visibility',maskId='A',hidden=True)['data']['changed']
    assert not call('set_mask_visibility',maskId='A',hidden=True)['data']['changed']
    assert call('set_mask_visibility',maskId='A',toolId='A2',hidden=True)['success']
    assert call('set_mask_tool_inverted',maskId='A',toolId='A2',inverted=True)['success']
    assert not call('set_mask_tool_inverted',maskId='A',toolId='A2',inverted=True)['data']['changed']
    assert state.masks[2].Hidden is False


def test_toggle_noop_and_unknown_state_fail(sdk):
    _,state,call=sdk
    state.toggleNoop=True
    assert call('set_mask_visibility',maskId='A',hidden=True)['code']=='readback_failed'
    state.masks[1].Hidden=None
    assert call('set_mask_visibility',maskId='A',hidden=True)['code']=='unsupported_mask_state'


def test_invert_and_duplicate_return_identity(sdk):
    _,state,call=sdk
    assert call('invert_mask',maskId='A')['success']
    assert state.masks[1].Tools[1].Inverted
    r=call('duplicate_inverted_mask',maskId='A')
    assert r['data']['maskId']=='duplicate' and len(state.masks)==3


def test_invert_failure_and_noop_creation(sdk):
    _,state,call=sdk
    state.invertFail=True
    assert call('invert_mask',maskId='A')['code']=='inversion_failed'
    state.invertFail=False;state.duplicateNoop=True
    assert call('duplicate_inverted_mask',maskId='A')['data']['status']=='pending'


def test_extended_sliders_use_existing_guarded_writer(sdk):
    _,state,call=sdk
    r=call('update_mask',maskId='A',adjustments={'Hue':10,'Amount':80,'Grain':5,'RefineSaturation':20})
    assert r['success'] and state['values'].A.local_Hue==10
    assert state['values'].B.local_Hue is None


def test_parent_and_photo_guards(sdk):
    _,state,call=sdk
    assert call('set_mask_visibility',maskId='A',toolId='B1',hidden=True)['code']=='tool_not_found'
    assert call('invert_mask',maskId='A',expectedPhotoId='wrong')['code']=='photo_changed'
    assert call('combine_mask',maskId='missing',operation='add',maskType='sky')['code']=='mask_not_found'
    assert state.lastOperation is None


def test_combination_tolerates_transient_nil_selection(sdk):
    lua,state,call=sdk
    lua.execute('''
        local old=controller.addToCurrentMask
        function controller.addToCurrentMask(k,s) old(k,s);state.selected=nil end
    ''')
    r=call('combine_mask',maskId='A',operation='add',maskType='subject')
    assert r['success'] and r['data']['status']=='component_created'
    assert r['data']['maskId']=='A'
