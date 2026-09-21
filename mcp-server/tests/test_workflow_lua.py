from pathlib import Path
import pytest
from lupa.lua51 import LuaRuntime

PLUGIN = Path(__file__).resolve().parents[2] / 'lrplugin/lightroom-mcp.lrdevplugin'


@pytest.fixture
def sdk():
    lua = LuaRuntime(unpack_returned_tuples=True)
    for f in ['library_fixture.lua', 'workflow_fixture.lua']:
        lua.execute(Path(__file__).with_name(f).read_text())
    lua.globals().libraryModule = lua.execute((PLUGIN / 'Library.lua').read_text())
    lua.execute('function require(name)assert(name=="Library");return libraryModule end')
    preview = lua.execute((PLUGIN / 'Previews.lua').read_text())
    develop = lua.execute((PLUGIN / 'Develop.lua').read_text())
    def call(cmd, **args):
        module = develop if cmd in {'batch_adjust_relative', 'apply_settings', 'get_settings', 'batch_apply_settings'} else preview
        return module.handle(lua.table_from({'command': cmd, **args}, recursive=True))
    return lua, lua.globals().state, lua.globals().photos, call, preview


def test_previews_create_observe_and_delete(sdk):
    lua, s, p, call, _ = sdk
    assert not call('get_smart_previews')['data']['photos'][1]['hasSmartPreview']
    r = call('build_smart_previews', jobId='a'*32, photoIds=['a', 'b'])
    assert r['success'] and r['data']['status']=='queued' and s.previewCalls is None
    lua.globals().runAsync()
    job = call('get_smart_preview_job', jobId='a'*32)['data']
    assert job['status']=='completed' and job['completed']==2
    assert job['results'][1]['after']['bytes']==123
    assert call('get_smart_previews')['data']['photos'][1]['hasSmartPreview']
    assert call('delete_smart_previews', jobId='b'*32, photoIds=['a'])['success']
    lua.globals().runAsync()
    assert call('get_smart_preview_job', jobId='b'*32)['data']['results'][1]['status']=='deleted'
    assert p.b.meta.smartPreviewInfo.smartPreviewPath and s.writes==0
    assert p.a.meta.path=='/photos/a.ARW'


def test_preview_preflight_whole_batch_and_offline_protection(sdk):
    lua, s, p, call, _ = sdk
    p.b.offline=True
    assert call('build_smart_previews', jobId='a'*32, photoIds=['a','b'])['code']=='photo_unavailable'
    assert len(s["async"])==0 and s.previewCalls is None
    p.b.meta.smartPreviewInfo=lua.table_from({'smartPreviewPath':'/offline.dng'})
    assert call('delete_smart_previews', jobId='b'*32, photoIds=['a','b'])['code']=='offline_preview_protected'
    assert call('delete_smart_previews', jobId='c'*32, photoIds=['b'],allowOffline=True)['success']
    lua.globals().runAsync()
    assert call('get_smart_preview_job',jobId='c'*32)['data']['status']=='completed'


def test_preview_unknown_is_not_absent_and_video_rejected(sdk):
    lua, s, p, call, _ = sdk
    p.a.meta.smartPreviewInfo=None
    assert call('get_smart_previews')['code']=='preview_state_unknown'
    p.a.meta.smartPreviewInfo=lua.table_from({'unexpected':1})
    assert call('delete_smart_previews',jobId='a'*32)['code']=='preview_state_unknown'
    p.a.meta.smartPreviewInfo=lua.table_from({});p.a.meta.isVideo=True
    assert call('build_smart_previews',jobId='a'*32)['code']=='unsupported_photo'
    assert s.previewCalls is None


def test_preview_existing_and_absent_are_noops(sdk):
    lua,s,p,call,_=sdk
    p.a.offline=True;p.a.meta.smartPreviewInfo=lua.table_from({'smartPreviewPath':'/offline.dng'})
    call('build_smart_previews',jobId='a'*32)
    lua.globals().runAsync()
    assert call('get_smart_preview_job',jobId='a'*32)['data']['results'][1]['status']=='unchanged'
    call('delete_smart_previews',jobId='b'*32,photoIds=['b'])
    lua.globals().runAsync()
    assert s.previewCalls is None


def test_preview_cancel_and_busy(sdk):
    lua,s,p,call,preview=sdk
    call('build_smart_previews',jobId='a'*32,photoIds=['a','b'])
    assert call('build_smart_previews',jobId='b'*32)['code']=='preview_busy'
    assert call('build_smart_previews',jobId='a'*32)['code']=='duplicate_job'
    lua.globals().previewModule=preview
    lua.execute("state.afterPreview=function()previewModule.handle{command='cancel_smart_preview_job',jobId=string.rep('a',32)}end")
    lua.globals().runAsync()
    job=call('get_smart_preview_job',jobId='a'*32)['data']
    assert job['status']=='cancelled' and job['completed']==1 and job['notStarted']==1
    assert len(p.b.meta.smartPreviewInfo)==0


@pytest.mark.parametrize('flag,code', [('nativeFail','preview_operation_failed'),('nativeThrow','sdk_error'),('noop','readback_failed')])
def test_preview_failed_result_stops_batch(sdk,flag,code):
    lua,s,p,call,_=sdk
    s[flag]=True if flag=='noop' else 'a'
    call('build_smart_previews',jobId='a'*32,photoIds=['a','b']);lua.globals().runAsync()
    job=call('get_smart_preview_job',jobId='a'*32)['data']
    assert job['status']=='failed' and job['notStarted']==1 and job['results'][1]['code']==code


def test_preview_catalog_switch_and_removed_photo(sdk):
    lua,s,p,call,_=sdk
    call('build_smart_previews',jobId='a'*32)
    s.path='/other';lua.globals().runAsync()
    assert call('get_smart_preview_job',jobId='a'*32)['data']['results'][1]['code']=='catalog_changed'
    assert s.previewCalls is None
    s.path='/test/catalog.lrcat'
    call('build_smart_previews',jobId='b'*32);p.a=None;lua.globals().runAsync()
    assert call('get_smart_preview_job',jobId='b'*32)['data']['results'][1]['code']=='photo_not_found'


def test_preview_selection_change_keeps_captured_targets_and_paging(sdk):
    lua,s,p,call,_=sdk
    call('build_smart_previews',jobId='a'*32,photoIds=['a','b']);s.selected='b';lua.globals().runAsync()
    job=call('get_smart_preview_job',jobId='a'*32,limit=1)['data']
    assert job['completed']==2 and job['hasMore'] and len(job['results'])==1
    assert call('get_smart_preview_job',jobId='a'*32,offset=1)['data']['results'][1]['photoId']=='b'
    assert call('get_smart_preview_job',jobId='f'*32)['code']=='job_not_found'


def test_relative_preserves_differences_and_negative_delta(sdk):
    _,s,p,call,_=sdk
    r=call('batch_adjust_relative',photoIds=['a','b'],deltas={'Exposure':.5,'Contrast':-10})
    assert r['success'] and r['applied']==2
    assert p.a.raw.Exposure2012==.5 and p.b.raw.Exposure2012==1.5
    assert p.a.raw.Contrast2012==p.b.raw.Contrast2012==-10
    assert r['data']['results'][2]['before']['Exposure']==1
    assert r['data']['results'][2]['after']['Exposure']==1.5
    assert s.selected=='a' and s.module=='library'


@pytest.mark.parametrize('problem', ['range','video','legacy','missing','mixed'])
def test_relative_whole_batch_preflight(sdk,problem):
    _,s,p,call,_=sdk
    deltas={'Exposure':.5}
    if problem=='range':p.b.raw.Exposure2012=4.9
    elif problem=='video':p.b.meta.isVideo=True
    elif problem=='legacy':p.b.raw.Exposure2012=None
    elif problem=='missing':deltas={'Texture':10}
    else:p.b.raw.IncrementalTemperature=0;deltas={'Temperature':10}
    assert not call('batch_adjust_relative',photoIds=['a','b'],deltas=deltas)['success']
    assert s.writes==0


def test_relative_stale_and_partial_failure(sdk):
    _,s,p,call,_=sdk
    s.staleBeforeWrite=True
    r=call('batch_adjust_relative',photoIds=['a','b'],deltas={'Exposure':.5})
    assert r['data']['results'][1]['code']=='settings_changed' and s.writes==0
    s.staleBeforeWrite=False;s.failPhoto='b'
    r=call('batch_adjust_relative',photoIds=['a','b'],deltas={'Exposure':.5})
    assert not r['success'] and r['applied']==1 and r['failed']==1
    assert p.a.raw.Exposure2012==2.5 and p.b.raw.Exposure2012==1
    assert r['data']['results'][2]['outcomeUnknown']


def test_relative_noop_clamp_lock_and_zero(sdk):
    _,s,p,call,_=sdk
    assert call('batch_adjust_relative',deltas={'Exposure':0})['success'] and s.writes==0
    s.noop=True
    r=call('batch_adjust_relative',deltas={'Exposure':.5})
    assert r['data']['results'][1]['code']=='readback_failed' and r['data']['results'][1]['after']['Exposure']==0
    s.noop=False;s.lockTimeout=True
    assert call('batch_adjust_relative',deltas={'Exposure':.5})['data']['results'][1]['code']=='write_timeout'


def test_relative_target_guards(sdk):
    _,s,p,call,_=sdk
    assert call('batch_adjust_relative',deltas={'Exposure':.5},expectedPhotoId='b')['code']=='photo_changed'
    assert call('batch_adjust_relative',deltas={'Exposure':.5},expectedCatalogPath='/other')['code']=='catalog_changed'
    s.switchBeforeWrite=True
    r=call('batch_adjust_relative',deltas={'Exposure':.5})
    assert r['data']['results'][1]['code']=='photo_changed' and s.writes==0


def test_color_grading_existing_keys_are_read_and_written(sdk):
    _,s,p,call,_=sdk
    settings={'SplitToningHighlightHue':45,'SplitToningHighlightSaturation':20,
              'SplitToningShadowHue':220,'SplitToningShadowSaturation':15,'SplitToningBalance':-10}
    assert call('apply_settings',settings=settings)['success']
    r=call('get_settings')['data']
    for key,value in settings.items():
        assert p.a.raw[key]==value and r['settings'][key]==value and r['parameterKeys'][key]==key
    assert call('apply_settings',settings={'ColorGradeHighlightHue':45})['code']=='unsupported_parameter'
    s.noop=True
    r=call('apply_settings',settings={'SplitToningHighlightHue':60})
    assert not r['success'] and r['data']['results'][1]['code']=='readback_failed'


def test_cancel_queued_and_job_eviction(sdk):
    lua,s,p,call,_=sdk
    call('build_smart_previews',jobId='a'*32)
    call('cancel_smart_preview_job',jobId='a'*32);lua.globals().runAsync()
    assert s.previewCalls is None
    assert call('get_smart_preview_job',jobId='a'*32)['data']['status']=='cancelled'
    for i in range(20):
        assert call('delete_smart_previews',jobId=f'{i:032x}')['success']
        lua.globals().runAsync()
    assert call('get_smart_preview_job',jobId='a'*32)['code']=='job_not_found'


def test_offline_protection_rechecked_when_job_runs(sdk):
    lua,s,p,call,_=sdk
    p.a.meta.smartPreviewInfo=lua.table_from({'smartPreviewPath':'/a.dng'})
    assert call('delete_smart_previews',jobId='a'*32)['success']
    p.a.offline=True;lua.globals().runAsync()
    assert call('get_smart_preview_job',jobId='a'*32)['data']['results'][1]['code']=='offline_preview_protected'
    assert s.previewCalls is None


def test_relative_white_balance_units_and_zero_noop(sdk):
    _,s,p,call,_=sdk
    assert call('batch_adjust_relative',deltas={'Temperature':200,'Tint':-5})['success']
    assert p.a.raw.Temperature==6700 and p.a.raw.Tint==-5 and p.a.raw.WhiteBalance=='Custom'
    p.a.raw.IncrementalTemperature=10;p.a.raw.IncrementalTint=0
    assert call('batch_adjust_relative',deltas={'Temperature':5,'Tint':-2})['success']
    assert p.a.raw.IncrementalTemperature==15 and p.a.raw.IncrementalTint==-2
    assert p.a.raw.Temperature==6700


def test_selected_scope_and_missing_api_preflight(sdk):
    lua,s,p,call,_=sdk
    s.selection=lua.table_from([p.a,p.b])
    assert call('batch_adjust_relative',scope='selected',deltas={'Exposure':.5})['applied']==2
    p.b.buildSmartPreview=None
    assert call('build_smart_previews',scope='selected',jobId='a'*32)['code']=='unsupported_api'
    assert s.previewCalls is None


def test_real_server_dispatch_and_json_types(sdk):
    lua,s,p,call,preview=sdk
    lua.globals().previewModule=preview
    lua.globals().developModule=lua.execute((PLUGIN/'Develop.lua').read_text())
    lua.execute('''
    local old=import
    function import(name)
      if name=='LrFileUtils' then return {} end
      if name=='LrLogger' then return function()return {enable=function()end}end end
      return old(name)
    end
    function require(name)
      if name=='Library' then return libraryModule end
      if name=='Develop' then return developModule end
      if name=='Previews' then return previewModule end
      return {commands={}}
    end
    _PLUGIN={path='/test/plugin'}
    ''')
    import json
    module=lua.execute((PLUGIN/'Server.lua').read_text())
    v=lua.execute((PLUGIN/'Info.lua').read_text())['VERSION']
    def wire(cmd,**args):
        req={'command':cmd,'expectedPluginVersion':'.'.join(str(v[k]) for k in ['major','minor','revision']),**args}
        return json.loads(module.handleRequest(json.dumps(req)))
    row=wire('get_smart_previews')['data']['photos'][0]
    assert row['hasSmartPreview'] is False and row['originalAvailable'] is True
    result=wire('batch_adjust_relative',deltas={'Exposure':.5})
    assert result['success'] and result['data']['results'][0]['after']['Exposure']==.5


def test_relative_zero_wb_delta_preserves_auto_mode(sdk):
    _,s,p,call,_=sdk
    p.a.raw.WhiteBalance='Auto'
    assert call('batch_adjust_relative',deltas={'Exposure':.5,'Temperature':0})['success']
    assert p.a.raw.WhiteBalance=='Auto' and p.a.raw.Temperature==6500


def test_relative_legacy_with_stale_modern_fields_is_rejected(sdk):
    _,s,p,call,_=sdk
    p.a.raw.ProcessVersion='5.0'
    assert call('batch_adjust_relative',deltas={'Contrast':5})['code']=='unsupported_process_version'
    assert s.writes==0


def test_preview_delete_failure_and_deleted_noop(sdk):
    lua,s,p,call,_=sdk
    p.a.meta.smartPreviewInfo=lua.table_from({'smartPreviewPath':'/a.dng'})
    s.nativeFail='a';call('delete_smart_previews',jobId='a'*32);lua.globals().runAsync()
    row=call('get_smart_preview_job',jobId='a'*32)['data']['results'][1]
    assert row['code']=='preview_operation_failed' and row['after']['hasSmartPreview'] and row['outcomeUnknown']
    s.nativeFail=None;s.noop=True
    call('delete_smart_previews',jobId='b'*32);lua.globals().runAsync()
    row=call('get_smart_preview_job',jobId='b'*32)['data']['results'][1]
    assert row['code']=='readback_failed' and row['after']['hasSmartPreview']
