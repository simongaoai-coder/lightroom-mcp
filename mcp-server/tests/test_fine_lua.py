from pathlib import Path
import pytest
from lupa.lua51 import LuaRuntime
PLUGIN=Path(__file__).resolve().parents[2]/'lrplugin/lightroom-mcp.lrdevplugin'

@pytest.fixture
def sdk():
    lua=LuaRuntime(unpack_returned_tuples=True)
    for name in ['masking_fixture.lua','fine_fixture.lua']:
        lua.execute(Path(__file__).with_name(name).read_text())
    lua.globals().maskModule=lua.execute((PLUGIN/'Masking.lua').read_text())
    lua.execute('function require(name) assert(name=="Masking");return maskModule end')
    module=lua.execute((PLUGIN/'Fine.lua').read_text())
    def call(cmd,**args):return module.handle(lua.table_from({'command':cmd,**args},recursive=True))
    return lua,lua.globals().state,call


def test_global_curve_roundtrip_and_no_local_writes(sdk):
    _,state,call=sdk
    points=[[0,0],[64,48],[128,138],[255,255]]
    result=call('set_curve',channel='red',points=points)
    assert result['success'] and state.raw.ToneCurvePV2012Red[4]==48
    assert state.raw.ToneCurvePV2012[3]==255
    assert state['values'].B.local_Redcurve[3]==1


def test_local_curve_scale_and_explicit_target(sdk):
    _,state,call=sdk
    result=call('set_curve',maskId='A',points=[[0,0],[127.5,140.25],[255,255]])
    assert result['success'] and result['data']['nativeScale']==1
    assert state['values'].A.local_Maincurve[3]==.5
    assert state['values'].A.local_Maincurve[4]==.55
    assert state['values'].B.local_Maincurve[3]==1


@pytest.mark.parametrize('points', [[],[[0,0]],[[0,0],[0,12],[255,255]],[[1,0],[255,255]],
                                   [[0,0],[255,256]],[[0,0],[float('nan'),20],[255,255]]])
def test_curve_validation_before_writes(sdk,points):
    _,state,call=sdk
    assert call('set_curve',points=points)['code']=='invalid_arguments'
    assert state.writes==0


def test_curve_noop_and_missing_parameter(sdk):
    _,state,call=sdk
    state.writeNoop=True
    assert call('set_curve',points=[[0,20],[255,255]])['code']=='readback_failed'
    state.raw.ToneCurvePV2012Red=None
    assert call('get_curve',channel='red')['code']=='unsupported_curve'


def test_auto_white_balance(sdk):
    _,state,call=sdk
    r=call('auto_white_balance')
    assert r['success'] and r['data']['whiteBalance']=='Auto' and r['data']['temperature']==6100
    state.raw.WhiteBalance='Custom';state.writeNoop=True
    assert call('auto_white_balance')['code']=='readback_failed'


def add(call,**extra):
    r=call('add_point_color',swatch={'SrcHue':1.2,'SrcSat':.5,'SrcLum':.5},**extra)
    assert r['success']
    return r['data']['swatches'][1]


def test_point_color_lifecycle_preserves_fields(sdk):
    _,state,call=sdk
    s=add(call)
    r=call('update_point_color',index=1,expectedSwatch=s,changes={'HueShift':.2})
    assert r['success'] and r['data']['swatches'][1]['HueShift']==.2
    assert r['data']['swatches'][1]['RangeAmount']==.5
    assert call('delete_point_color',index=1,expectedSwatch=s)['code']=='swatch_changed'
    assert call('delete_point_color',index=1,expectedSwatch=r['data']['swatches'][1])['success']
    assert len(state.points)==0


def test_local_point_color_stays_on_target_mask(sdk):
    _,state,call=sdk
    s=add(call,maskId='A')
    assert call('update_point_color',maskId='A',index=1,expectedSwatch=s,changes={'SatScale':-.3})['success']
    assert state['values'].A.local_PointColors[1]['SatScale']==-.3
    assert len(state['values'].B.local_PointColors)==len(state.points)==0


def test_duplicate_source_is_not_claimed_as_applied_update(sdk):
    _,state,call=sdk
    add(call)
    r=call('add_point_color',swatch={'SrcHue':1.2,'SrcSat':.5,'SrcLum':.5,'HueShift':.5})
    assert r['data']['status']=='existing_selected'
    assert state.points[1].HueShift==0


def test_stale_point_index_and_missing_api(sdk):
    lua,state,call=sdk
    s=add(call)
    state.points[1].SrcHue=2
    count=state.writes
    assert call('update_point_color',index=1,expectedSwatch=s,changes={'HueShift':.1})['code']=='swatch_changed'
    assert state.writes==count
    lua.globals().controller.addPointColorSwatch=None
    assert call('add_point_color',swatch={'SrcHue':1,'SrcSat':1,'SrcLum':1})['code']=='unsupported_api'


def test_swatch_noop_and_bad_request(sdk):
    _,state,call=sdk
    s=add(call);state.writeNoop=True
    assert call('update_point_color',index=1,expectedSwatch=s,changes={'HueShift':.1})['code']=='readback_failed'
    assert call('add_point_color',swatch={'SrcHue':7,'SrcSat':0,'SrcLum':0})['code']=='invalid_arguments'


def test_wrong_photo_or_mask_never_writes(sdk):
    _,state,call=sdk
    assert call('set_curve',points=[[0,0],[255,255]],expectedPhotoId='wrong')['code']=='photo_changed'
    assert call('set_curve',points=[[0,0],[255,255]],maskId='missing')['code']=='mask_not_found'
    assert state.writes==0


def test_empty_local_point_color_can_be_uninitialized(sdk):
    lua,state,call=sdk
    # Native nil is not proof of emptiness. Listing reports that uncertainty;
    # a documented add can initialize the local list and is then read back.
    lua.execute('''
        local oldGet=controller.getValue
        local oldAdd=controller.addPointColorSwatch
        state.uninitialized=true
        function controller.getValue(key)
            if key=="local_PointColors" and state.uninitialized then return nil end
            return oldGet(key)
        end
        function controller.addPointColorSwatch(s,localMode)
            state.uninitialized=false
            return oldAdd(s,localMode)
        end
    ''')
    assert call('list_point_colors',maskId='A')['data']['readState']=='unavailable_or_uninitialized'
    r=call('add_point_color',maskId='A',swatch={'SrcHue':1,'SrcSat':.5,'SrcLum':.5})
    assert r['success'] and r['data']['status']=='added_or_selected'
    assert len(state['values'].A.local_PointColors)==1


def test_auto_white_balance_waits_for_actual_values(sdk):
    lua,state,call=sdk
    lua.execute('controller.getValue=function() return nil end')
    assert call('auto_white_balance')['code']=='readback_failed'


def test_local_point_color_subtool_is_valid_masking_context(sdk):
    lua,state,call=sdk
    state.panel='local_point_color'
    lua.execute('controller.goToMasking=function() end')
    r=call('add_point_color',maskId='A',swatch={'SrcHue':1,'SrcSat':.5,'SrcLum':.5})
    assert r['success']
    assert call('list_point_colors',maskId='A')['success']


def test_delete_last_local_swatch_verifies_catalog_when_getter_is_nil(sdk):
    lua,state,call=sdk
    swatch=add(call,maskId='A')
    lua.execute('''
        local old=controller.getValue
        function controller.getValue(k)
            local v=old(k)
            if k=="local_PointColors" and type(v)=="table" and #v==0 then return nil end
            return v
        end
    ''')
    result=call('delete_point_color',maskId='A',index=1,expectedSwatch=swatch)
    assert result['success'] and result['data']['verification']=='sdk_and_catalog_empty'
    assert len(result['data']['swatches'])==0


def test_nil_getter_without_known_catalog_field_does_not_prove_deletion(sdk):
    lua,state,call=sdk
    swatch=add(call,maskId='A')
    lua.execute('''
        local old=controller.getValue
        function controller.getValue(k)
            local v=old(k)
            if k=="local_PointColors" and type(v)=="table" and #v==0 then return nil end
            return v
        end
        local get=state.photo.getDevelopSettings
        function state.photo:getDevelopSettings()
            local s=get(self)
            for _,m in ipairs(s.MaskGroupBasedCorrections) do m.LocalPointColors=nil end
            return s
        end
    ''')
    assert call('delete_point_color',maskId='A',index=1,expectedSwatch=swatch)['code']=='readback_failed'
