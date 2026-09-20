from pathlib import Path
import hashlib
import pytest
from lupa.lua51 import LuaRuntime
PLUGIN=Path(__file__).resolve().parents[2]/'lrplugin/lightroom-mcp.lrdevplugin'

@pytest.fixture
def sdk():
 lua=LuaRuntime(unpack_returned_tuples=True)
 lua.execute(Path(__file__).with_name('library_fixture.lua').read_text())
 lua.globals().pyDigest=lambda s:hashlib.md5(s.encode()).hexdigest()
 lua.execute(Path(__file__).with_name('healing_fixture.lua').read_text())
 lua.globals().libraryModule=lua.execute((PLUGIN/'Library.lua').read_text())
 lua.execute('function require(name)assert(name=="Library");return libraryModule end')
 m=lua.execute((PLUGIN/'Healing.lua').read_text())
 def call(cmd,**args):return m.handle(lua.table_from({'command':cmd,**args},recursive=True))
 return lua,lua.globals().state,call

def target():return {'spotIndex':1,'expectedSpot':{'id':'s1','x':.4}}

def test_list_select_and_stale_guards(sdk):
 lua,s,c=sdk
 d=c('list_spots',limit=1)['data'];assert d['count']==2 and d['hasMore'] and d['spotIndex']==1
 assert c('select_spot',**target())['success']
 assert c('select_spot',spotIndex=1,expectedSpot={'id':'other'})['code']=='spot_changed'
 assert c('select_spot',spotIndex=5,expectedSpot={'id':'s1'})['code']=='spot_not_found'
 assert c('list_spots',expectedPhotoId='b')['code']=='photo_changed'
 assert c('list_spots',expectedCatalogPath='/other')['code']=='catalog_changed'
 assert s.module=='develop' and s.tool=='dust'

def test_unavailable_is_not_empty(sdk):
 lua,s,c=sdk;s.listNil=True
 assert c('list_spots')['code']=='spots_unavailable'
 s.spots=lua.table();s.spotIndex=None
 assert c('list_spots')['data']['count']==0

def test_count_mismatch_and_no_selection(sdk):
 _,s,c=sdk;s.countOverride=3
 assert c('list_spots')['code']=='spots_unavailable'
 s.countOverride=None;s.spotIndex=None
 assert not c('get_selected_spot')['data']['hasSelection']

def test_params_readback_and_rejections(sdk):
 _,s,c=sdk
 assert c('update_spot',**target(),changes={'Opacity':.75})['data']['params']['Opacity']==.75
 for changes in ({'unknown':1},{'id':1},{'size':float('inf')}):
  assert c('update_spot',**target(),changes=changes)['code']=='unsupported_parameter'
 s.noop=True
 assert c('update_spot',**target(),changes={'Opacity':.5})['code']=='readback_failed'

def test_selection_noop_never_edits_other(sdk):
 _,s,c=sdk;s.spotIndex=2;s.noop=True
 assert c('delete_spot',**target())['code']=='selection_failed'
 assert len(s.spots)==2

def test_types_movement_and_variations(sdk):
 _,s,c=sdk
 assert c('cycle_spot_variation',**target(),direction='next')['code']=='not_generative_spot'
 assert c('set_spot_type',**target(),spotType='clone',useGenerativeAI=True)['code']=='invalid_arguments'
 assert c('set_spot_type',**target(),spotType='clone')['success']
 assert c('move_spot',**target(),horizontal='right',horizontalUnits=2,sourceArea=True)['success']
 assert s.move.hu==2 and s.move.source
 s.spots[1].x=.4
 assert c('move_spot',**target(),horizontalUnits=2)['code']=='invalid_arguments'
 assert c('set_spot_type',**target(),spotType='heal_patchmatch',useGenerativeAI=True)['success']
 assert c('move_spot',**target(),horizontal='right',sourceArea=True)['code']=='unsupported_operation'
 assert c('refresh_spot',**target())['code']=='generative_refresh_not_authorized'
 assert c('refresh_spot',**target(),allowGenerativeRefresh=True)['success'] and s.refreshed
 assert c('cycle_spot_variation',**target(),direction='next')['success'] and s.variation=='next'
 assert c('cycle_spot_variation',**target(),direction='previous')['success'] and s.variation=='previous'

def test_delete_and_reset_verify_state(sdk):
 _,s,c=sdk
 revision=c('list_spots')['data']['revision']
 assert c('delete_spot',**target())['data']['remainingCount']==1
 assert s.spots[1]['id']=='s2'
 assert c('reset_healing',expectedRevision=revision)['code']=='spots_changed'
 revision=c('list_spots')['data']['revision']
 s.noop=True;assert c('reset_healing',expectedRevision=revision)['code']=='readback_failed'
 s.noop=False;assert c('reset_healing',expectedRevision=revision)['data']['removedCount']==1

def test_preferences_separate_and_validated(sdk):
 _,s,c=sdk
 assert c('set_remove_preferences',changes={'brushSize':20,'toolOverlay':'selected'})['success']
 assert s.params.size==.03
 for changes in ({'brushSize':0},{'useGenerativeAI':1},{'x':1}):
  assert c('set_remove_preferences',changes=changes)['code']=='invalid_arguments'
 s.noop=True;assert c('set_remove_preferences',changes={'brushSize':30})['code']=='readback_failed'

def test_jobs_frozen_targets_and_write_gates(sdk):
 lua,s,c=sdk;j='a'*32
 assert c('update_ai_settings',jobId=j,photoIds=['a','b'])['data']['status']=='queued'
 assert c('update_ai_settings',jobId='b'*32)['code']=='ai_update_busy'
 s.selected='b';lua.globals().runAsync()
 r=c('get_ai_update_status',jobId=j)['data']
 assert r['status']=='sdk_completed' and r['completed']==2 and s.aiCalls==2
 assert c('get_ai_update_status',jobId='missing')['code']=='job_not_found'
 assert c('update_ai_settings',jobId=j)['code']=='duplicate_job'

def test_jobs_cancel_and_failure(sdk):
 lua,s,c=sdk;j='a'*32
 c('update_ai_settings',jobId=j,photoIds=['a','b']);c('cancel_ai_update',jobId=j);lua.globals().runAsync()
 assert c('get_ai_update_status',jobId=j)['data']['status']=='cancelled' and s.aiCalls is None
 s.failPhoto='b';c('update_ai_settings',jobId='b'*32,photoIds=['a','b']);lua.globals().runAsync()
 r=c('get_ai_update_status',jobId='b'*32)['data'];assert r['completed']==1 and r['failed']==1 and r['status']=='failed'

def test_cleanup_explicit_targets_and_write_gate(sdk):
 lua,s,c=sdk
 r=c('cleanup_empty_masks',photoIds=['a'])
 assert r['data']['results'][1]['removedMaskIds'][1]=='empty'
 assert len(lua.globals().photos.b.settings.MaskGroupBasedCorrections)==2
 s.lockTimeout=True;assert c('cleanup_empty_masks',photoIds=['b'])['code']=='partial_failure'

def test_missing_apis(sdk):
 lua,s,c=sdk;lua.globals().controller.getAllSpots=None
 assert c('list_spots')['code']=='unsupported_api'
 lua.globals().photos.a.updateAISettings=None
 assert c('update_ai_settings',jobId='a'*32)['code']=='unsupported_api'

def test_cancel_between_photos(sdk):
 lua,s,c=sdk;j='a'*32
 c('update_ai_settings',jobId=j,photoIds=['a','b'])
 lua.execute("state.onSleep=function()_lrMcpAIUpdateJobs[string.rep('a',32)].cancelRequested=true end")
 lua.globals().runAsync();r=c('get_ai_update_status',jobId=j)['data']
 assert r['status']=='cancelled' and r['completed']==1 and r['notStarted']==1

def test_catalog_change_stops_job_before_write(sdk):
 lua,s,c=sdk;j='a'*32
 c('update_ai_settings',jobId=j,photoIds=['a','b']);s.path='/other';lua.globals().runAsync()
 r=c('get_ai_update_status',jobId=j)['data'];assert r['status']=='failed' and r['completed']==0 and s.aiCalls is None

def test_observation_does_not_hide_photo_change(sdk):
 lua,s,c=sdk
 lua.execute("controller.moveSelectedSpot=function()state.selected='b' end")
 assert c('move_spot',**target(),horizontal='right')['code']=='photo_changed'

def test_batch_preflight_no_partial_writes(sdk):
 lua,s,c=sdk
 assert c('update_ai_settings',jobId='a'*32,photoIds=['a','missing'])['code']=='photo_not_found'
 assert len(s["async"])==0 and s.aiCalls is None
 assert c('cleanup_empty_masks',photoIds=['a','missing'])['code']=='photo_not_found'
 assert len(lua.globals().photos.a.settings.MaskGroupBasedCorrections)==2


def test_silent_move_failure_is_not_success(sdk):
 _,s,c=sdk;s.noop=True
 assert c("move_spot",**target(),horizontal="right")["code"]=="movement_unverified"
