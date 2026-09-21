from pathlib import Path
import json
import pytest
from lupa.lua51 import LuaRuntime
PLUGIN=Path(__file__).resolve().parents[2]/'lrplugin/lightroom-mcp.lrdevplugin'

@pytest.fixture
def sdk():
    lua=LuaRuntime(unpack_returned_tuples=True)
    for name in ['library_fixture.lua','workflow_fixture.lua','styles_fixture.lua']:
        lua.execute(Path(__file__).with_name(name).read_text())
    modules={}
    def load(name):
        if name not in modules:
            modules[name]=lua.execute((PLUGIN/(name+'.lua')).read_text())
        return modules[name]
    lua.globals().require=load
    batch=load('Batch');develop=load('Develop')
    def call(command,**args):
        module=develop if command in {'apply_settings','batch_apply_settings'} else batch
        return module.handle(lua.table_from({'command':command,**args},recursive=True))
    return lua,lua.globals().state,lua.globals().photos,call,modules,load


def test_save_selective_style_reload_and_apply_to_offscreen_photo(sdk):
    lua,s,p,call,modules,load=sdk
    saved=call('save_style',name='旅行胶片',parameters=['SplitToningHighlightHue'],groups=['grain','pointCurve'])
    assert saved['success'] and s.writes==0
    pid=saved['data']['presetId'];settings=saved['data']['settings']
    assert settings['Exposure2012'] is None and settings['WhiteBalance'] is None and settings['CropTop'] is None
    assert settings['GrainAmount']==20 and settings['ToneCurvePV2012Red'][3]==255
    p.a.raw.GrainAmount=40;p.b.raw.GrainAmount=1;p.b.raw.Exposure2012=2
    # Both module caches reset; SDK presets/preferences remain (native persistence double).
    modules.clear();batch=load('Batch')
    r=batch.handle(lua.table_from({'command':'apply_preset','presetId':pid,'photoIds':['b']},recursive=True))
    assert r['success'] and r['data']['results'][1]['verification']=='saved_fields_readback'
    assert p.b.raw.GrainAmount==20 and p.b.raw.Exposure2012==2 and p.a.raw.GrainAmount==40
    assert s.selected=='a' and s.module=='library'


def test_style_explicit_source_no_selection_and_native_enumeration(sdk):
    lua,s,p,call,modules,load=sdk
    s.selected='missing'
    r=call('save_style',name='offscreen',sourcePhotoId='b',parameters=['Exposure'])
    assert r['success'] and r['data']['settings']['Exposure2012']==1
    r=load('Versions').handle(lua.table_from({'command':'list_presets'}))
    assert r['data']['presets'][1]['name']=='offscreen' and r['data']['presets'][1]['pluginOwned']
    assert call('apply_preset',presetId='style-1',photoIds=['a'])['success']
    assert p.a.raw.Exposure2012==1 and s.selected=='missing'


@pytest.mark.parametrize('args',[
    {'name':'empty'}, {'name':'x','parameters':['unknown']},
    {'name':'x','parameters':['Exposure','exposure']}, {'name':'x','groups':['unknown']},
    {'name':'\n','parameters':['Exposure']}, {'name':'x','groups':[]},
])
def test_invalid_save_no_native_creation(sdk,args):
    _,s,_,call,_,_=sdk
    assert not call('save_style',**args)['success'] and s.nativeCreates==0


def test_style_collision_does_not_overwrite(sdk):
    _,s,p,call,_,_=sdk
    call('save_style',name='My Look',groups=['grain'])
    assert call('save_style',name='my look',groups=['grain'])['code']=='style_exists'
    assert s.nativeCreates==1


def test_style_failed_native_readback_is_not_applicable(sdk):
    _,s,p,call,_,_=sdk
    s.dropPresetField='GrainSize'
    assert call('save_style',name='broken',groups=['grain'])['code']=='style_save_unverified'
    assert call('apply_preset',presetId='style-1',photoIds=['a'])['code']=='style_unverified'
    assert s.presetCalls is None


def test_style_compatibility_preflights_every_photo(sdk):
    _,s,p,call,_,_=sdk
    call('save_style',name='wb',parameters=['Temperature'])
    p.b.raw.IncrementalTemperature=0
    assert call('apply_preset',presetId='style-1',photoIds=['a','b'])['code']=='incompatible_style'
    p.b.raw.IncrementalTemperature=None;p.b.raw.ProcessVersion='6.7'
    assert call('apply_preset',presetId='style-1',photoIds=['a','b'])['code']=='incompatible_style'
    assert s.presetCalls is None


def test_modified_native_style_rejected(sdk):
    lua,s,p,call,_,_=sdk
    call('save_style',name='look',groups=['grain'])
    lua.globals().nativePresets[1].settings.GrainAmount=99
    assert call('apply_preset',presetId='style-1')['code']=='style_changed' and s.presetCalls is None


def test_style_amount_and_noop_readback(sdk):
    _,s,p,call,_,_=sdk
    call('save_style',name='look',groups=['grain'])
    assert call('apply_preset',presetId='style-1',amount=50)['code']=='unsupported_amount'
    p.b.raw.GrainAmount=0;s.noop=True
    r=call('apply_preset',presetId='style-1',photoIds=['b'])
    assert not r['success'] and r['data']['results'][1]['code']=='readback_failed'


@pytest.mark.parametrize('command,args',[
    ('apply_settings',{'settings':{'Exposure':.5}}),
    ('batch_apply_settings',{'settings':{'Exposure':.5}}),
    ('set_treatment',{'treatment':'grayscale'}),
    ('set_white_balance',{'mode':'Daylight'}),
    ('rotate_photo',{'direction':'right'}),
])
def test_explicit_batch_does_not_change_selection(sdk,command,args):
    _,s,p,call,_,_=sdk
    r=call(command,photoIds=['b'],**args)
    assert r['success'] and r['applied']==1 and r['data']['results'][1]['photoId']=='b'
    assert s.selected=='a' and s.module=='library'
    assert p.a.raw.Exposure2012==0 and p.a.meta.orientation=='AB'


def test_numeric_explicit_no_active_and_legacy_batch_default(sdk):
    lua,s,p,call,_,_=sdk
    s.selected='missing'
    assert call('apply_settings',photoIds=['b'],settings={'Exposure':2})['success']
    s.selected='a';s.selection=lua.table_from([p.a,p.b])
    r=call('batch_apply_settings',expectedCatalogPath='/test/catalog.lrcat',settings={'Exposure':.2})
    assert r['success'] and r['applied']==2


@pytest.mark.parametrize('command,args',[
    ('apply_settings',{'settings':{'Exposure':1}}),
    ('set_treatment',{'treatment':'grayscale'}),
    ('set_white_balance',{'mode':'Auto'}),
    ('rotate_photo',{'direction':'left'}),
])
def test_batch_invalid_target_prevents_all_writes(sdk,command,args):
    _,s,p,call,_,_=sdk
    assert call(command,photoIds=['a','missing'],**args)['code']=='photo_not_found'
    assert s.writes==0
    assert call(command,photoIds=['a'],scope='selected',**args)['code']=='invalid_arguments'


def test_wb_rendered_preflight_and_rotation_noop(sdk):
    _,s,p,call,_,_=sdk
    p.b.meta.fileFormat='JPG'
    assert call('set_white_balance',photoIds=['a','b'],mode='Daylight')['code']=='unsupported_mode'
    assert s.writes==0
    s.noop=True
    r=call('rotate_photo',photoIds=['a','b'],direction='right')
    assert r['failed']==1 and r['notAttempted']==1 and r['data']['results'][1]['outcomeUnknown']


def test_preset_partial_failure_and_context_guards(sdk):
    _,s,p,call,_,_=sdk
    call('save_style',name='look',groups=['grain']);s.failPhoto='b'
    r=call('apply_preset',presetId='style-1',photoIds=['a','b'])
    assert r['applied']==1 and r['failed']==1
    assert call('set_treatment',photoIds=['b'],treatment='color',expectedPhotoId='b')['code']=='photo_changed'
    assert call('set_treatment',photoIds=['b'],treatment='color',expectedCatalogPath='/other')['code']=='catalog_changed'


def test_real_server_dispatch(sdk):
    lua,s,p,call,modules,load=sdk
    # Supply unrelated modules as stubs; exercise real new modules and JSON wire.
    for name in ['Fine','Healing','Previews','Delivery','Masking']:
        modules[name]=lua.table_from({'commands':lua.table_from({})})
    module=load('Server');version='2.12.0'
    def wire(command,**args):
        return json.loads(module.handleRequest(json.dumps({'command':command,'expectedPluginVersion':version,**args})))
    r=wire('save_style',name='saved',groups=['grain'])
    assert r['success']
    r=wire('apply_preset',presetId=r['data']['presetId'],photoIds=['b'])
    assert r['success'] and r['data']['results'][0]['photoId']=='b'
    assert wire('set_treatment',photoIds=['b'],treatment='grayscale')['success']
    assert p.b.raw.ConvertToGrayscale is True and p.a.raw.ConvertToGrayscale is None


def test_color_grading_group_excludes_tone_and_wb(sdk):
    _,s,p,call,_,_=sdk
    r=call('save_style',name='暖高光冷阴影',groups=['colorGrading'])
    assert r['success'] and len(list(r['data']['settings'].keys()))==14
    assert r['data']['settings']['Exposure2012'] is None
    assert r['data']['settings']['WhiteBalance'] is None


def test_native_extra_setting_is_rejected_on_save_and_after_edit(sdk):
    lua,s,p,call,_,_=sdk
    s.extraPresetField=True
    assert call('save_style',name='unsafe',groups=['grain'])['code']=='style_save_unverified'
    s.extraPresetField=False
    r=call('save_style',name='safe',groups=['grain']);assert r['success']
    lua.globals().nativePresets[2].settings.Exposure2012=3
    assert call('apply_preset',presetId='style-2')['code']=='style_changed'
    assert s.presetCalls is None


def test_numeric_catalog_change_after_write_never_claims_verified(sdk):
    lua,s,p,call,_,_=sdk
    lua.execute('''
    local old=photos.b.applyDevelopSettings
    function photos.b:applyDevelopSettings(values)
        old(self,values);state.path='/different/catalog.lrcat'
    end
    ''')
    r=call('apply_settings',photoIds=['b'],settings={'Exposure':.5})
    assert not r['success'] and r['data']['results'][1]['code']=='catalog_changed'
    assert r['data']['results'][1]['outcomeUnknown']
