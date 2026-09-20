from pathlib import Path
import pytest
from lupa.lua51 import LuaRuntime

PLUGIN = Path(__file__).resolve().parents[2] / 'lrplugin/lightroom-mcp.lrdevplugin'

@pytest.fixture
def sdk():
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.execute(Path(__file__).with_name('develop_fixture.lua').read_text())
    module = lua.execute((PLUGIN / 'Develop.lua').read_text())
    def call(command, **args):
        return module.handle(lua.table_from({'command': command, **args}, recursive=True))
    return lua, lua.globals().state, lua.globals().photos, call


def test_single_and_batch_map_modern_keys(sdk):
    _, state, photos, call = sdk
    assert call('apply_settings', settings={'exposure': 0.73})['success']
    assert photos.a.raw.Exposure2012 == .73 and photos.a.raw.Exposure == 4
    result = call('batch_apply_settings', settings={'Exposure': -.4, 'Shadows': 18})
    assert result['success'] and result['applied'] == 2
    for p in (photos.a, photos.b):
        assert p.raw.Exposure2012 == -.4 and p.raw.Shadows2012 == 18 and p.raw.Exposure == 4


def test_legacy_mapping_ignores_inactive_modern_keys(sdk):
    _, _, photos, call = sdk
    photos.a.raw.ProcessVersion = '5.7'
    photos.a.raw.FillLight = 0
    photos.a.raw.Shadows = 5
    result = call('apply_settings', settings={'Exposure': .2, 'Shadows': 25, 'Blacks': 7})
    assert result['success']
    assert photos.a.raw.Exposure == .2 and photos.a.raw.Exposure2012 == 0
    assert photos.a.raw.FillLight == 25 and photos.a.raw.Shadows == 7


def test_reads_without_develop_ui_and_preserves_complex_raw(sdk):
    _, _, _, call = sdk
    data = call('get_settings', includeRaw=True)['data']
    assert data['settings']['Exposure'] == 0
    assert data['parameterKeys']['Exposure'] == 'Exposure2012'
    assert data['rawSettings']['ToneCurvePV2012'][3] == 255
    assert data['processVersion'] == '15.4'
    assert call('get_settings')['data']['rawSettings'] is None


@pytest.mark.parametrize('settings', [{}, {'Unknown': 1}, {'Exposure': True}, {'Exposure': float('nan')},
                                     {'Exposure': float('inf')}, {'Exposure': 1, 'exposure': 2},
                                     {'LensBlurActive': 2}, {'CropTop': .9, 'CropBottom': .2}])
def test_invalid_requests_never_write(sdk, settings):
    _, state, _, call = sdk
    assert not call('apply_settings', settings=settings)['success']
    assert state.writes == 0


def test_batch_preflights_all_photos(sdk):
    _, state, photos, call = sdk
    photos.b.raw.RedHue = None
    assert not call('batch_apply_settings', settings={'RedHue': 8})['success']
    assert state.writes == 0


def test_partial_batch_is_reported_and_stops(sdk):
    _, state, photos, call = sdk
    state.failPhoto = 'b'
    result = call('batch_apply_settings', settings={'Exposure': 1})
    assert not result['success'] and result['applied'] == 1 and result['failed'] == 1
    assert result['data']['results'][2]['code'] == 'sdk_error'
    assert photos.a.raw.Exposure2012 == 1 and photos.b.raw.Exposure2012 == 0


def test_noop_is_readback_failure(sdk):
    _, state, _, call = sdk
    state.noop = True
    result = call('apply_settings', settings={'Exposure': 1})
    assert not result['success']
    assert result['data']['results'][1]['code'] == 'readback_failed'
    assert result['data']['settings']['Exposure'] == 0


def test_lock_timeout_never_claims_success(sdk):
    _, state, _, call = sdk
    state.lockTimeout = True
    result = call('apply_settings', settings={'Exposure': 1})
    assert not result['success'] and state.writes == 0
    assert result['data']['results'][1]['code'] == 'write_timeout'


def test_selection_change_and_stale_identity(sdk):
    _, state, _, call = sdk
    assert call('apply_settings', expectedPhotoId='wrong', settings={'Exposure': 1})['code'] == 'photo_changed'
    state.switchBeforeWrite = True
    assert not call('apply_settings', settings={'Exposure': 1})['success']
    assert state.writes == 0


def test_rendered_white_balance_and_boolean_conversion(sdk):
    _, _, photos, call = sdk
    photos.a.raw.IncrementalTemperature = 0
    assert call('apply_settings', settings={'Temperature': 15, 'LensBlurActive': 1})['success']
    assert photos.a.raw.IncrementalTemperature == 15 and photos.a.raw.Temperature == 6500
    assert photos.a.raw.WhiteBalance == 'Custom' and photos.a.raw.LensBlurActive is True


def test_absent_sdk_and_no_photo(sdk):
    _, state, photos, call = sdk
    photos.a.applyDevelopSettings = None
    assert call('apply_settings', settings={'Exposure': 1})['code'] == 'unsupported_api'
    state.selected = None
    assert call('get_settings')['code'] == 'no_photo'


def test_real_dispatch_version_gate_and_sdk_errors(sdk):
    import json
    lua, state, _, _ = sdk
    lua.execute('''
        local originalImport = import
        function import(name)
            if name == "LrFileUtils" then return {} end
            if name == "LrLogger" then return function() return {enable=function() end} end end
            if name == "LrApplicationView" then return {getCurrentModuleName=function() return "develop" end} end
            return originalImport(name)
        end
        _PLUGIN = {path="/test/plugin"}
    ''')
    develop = lua.execute((PLUGIN / 'Develop.lua').read_text())
    lua.globals().developModule = develop
    lua.execute('function require(name) if name=="Develop" then return developModule end; return {commands={}, VERSION="1.1.4", capabilities=function() return {} end} end')
    module = lua.execute((PLUGIN / 'Server.lua').read_text())
    info = lua.execute((PLUGIN / 'Info.lua').read_text())['VERSION']
    version = '.'.join(str(info[k]) for k in ['major','minor','revision'])
    def call(**args):
        return json.loads(module.handleRequest(json.dumps(args)))
    result=call(command='apply_settings',settings={'Exposure':1},expectedPluginVersion='1.1.4',requestId='old')
    assert result['code']=='version_mismatch' and result['requestId']=='old' and state.writes==0
    result=call(command='apply_settings',settings={'Exposure':.3},expectedPluginVersion=version,requestId='new')
    assert result['success'] and result['data']['settings']['Exposure']==.3
    result=call(command='enhance',params={'denoise':True},expectedPluginVersion=version)
    assert result['code']=='unsupported_api'
    assert call(command='ping')['version']==version
    assert json.loads(module.handleRequest('{bad json'))['code']=='invalid_request'
