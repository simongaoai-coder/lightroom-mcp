from pathlib import Path
import asyncio,json
import pytest
from lupa.lua51 import LuaRuntime
import server
PLUGIN=Path(__file__).resolve().parents[2]/'lrplugin/lightroom-mcp.lrdevplugin'
@pytest.fixture
def sdk():
 lua=LuaRuntime(unpack_returned_tuples=True)
 for f in ['library_fixture.lua','appearance_fixture.lua']:lua.execute(Path(__file__).with_name(f).read_text())
 lua.execute('''
  for _,p in pairs(photos)do p.raw.ProcessVersion='11.0' end
  state.process='Version 5';state.processCalls=0
  local old=import
  controller={getProcessVersion=function()return state.process end,
   setProcessVersion=function(value)
    assert(not state.inWrite);state.processCalls=state.processCalls+1
    if state.reject then return false end
    if not state.noop then
     state.process=value
     if not state.catalogNoop then photos[state.selected].raw.ProcessVersion=({['Version 1']='5.0',['Version 2']='5.7',['Version 3']='6.7',['Version 4']='10.0',['Version 5']='11.0',['Version 6']='15.4'})[value] end
    end
    if state.switchAfterSet then state.selected='b' end
   end}
  function import(name)if name=='LrDevelopController'then return controller end;return old(name)end
 ''')
 m=lua.execute((PLUGIN/'Fine.lua').read_text())
 def call(cmd,**args):return m.handle(lua.table_from({'command':cmd,**args},recursive=True))
 return lua,lua.globals().state,lua.globals().photos,call

def test_get_distinguishes_sdk_and_catalog_versions(sdk):
 _,s,p,c=sdk;r=c('get_process_version')['data']
 assert r['version']=='Version 5' and r['rawVersion']=='11.0' and s.module=='develop' and s.processCalls==0

@pytest.mark.parametrize('version',[f'Version {n}'for n in range(1,7)])
def test_set_version_isolated_and_readback(sdk,version):
 _,s,p,c=sdk;r=c('set_process_version',version=version,expectedPhotoId='a')
 assert r['success'] and r['data']['version']==version and p.b.raw.ProcessVersion=='11.0'
 assert s.processCalls==(0 if version=='Version 5'else 1)

def test_stale_invalid_and_identity_preflight(sdk):
 _,s,p,c=sdk
 assert c('set_process_version',version='11.0',expectedPhotoId='a')['code']=='invalid_arguments'
 assert c('set_process_version',version='Version 6')['code']=='invalid_arguments'
 assert c('set_process_version',version='Version 6',expectedPhotoId='b')['code']=='photo_changed'
 assert c('set_process_version',version='Version 6',expectedPhotoId='a',expectedVersion='Version 4')['code']=='process_version_changed'
 assert c('get_process_version',expectedCatalogPath='/wrong')['code']=='catalog_changed' and s.processCalls==0

def test_silent_and_partial_noop_are_not_success(sdk):
 _,s,p,c=sdk;s.noop=True
 assert c('set_process_version',version='Version 6',expectedPhotoId='a')['code']=='process_version_unverified'
 s.noop=False;s.catalogNoop=True
 assert c('set_process_version',version='Version 6',expectedPhotoId='a')['code']=='process_version_unverified'

def test_photo_change_and_missing_sdk(sdk):
 lua,s,p,c=sdk;s.switchAfterSet=True
 assert c('set_process_version',version='Version 6',expectedPhotoId='a')['code']=='photo_changed'
 s.selected='a';s.switchAfterSet=False;lua.globals().controller.setProcessVersion=None
 assert c('set_process_version',version='Version 6',expectedPhotoId='a')['code']=='unsupported_api'
 p.a.meta.isVideo=True;assert c('get_process_version')['code']=='unsupported_photo'

def test_unknown_future_read_not_silently_mapped(sdk):
 _,s,p,c=sdk;s.process='Version 7';p.a.raw.ProcessVersion='future'
 assert c('get_process_version')['data']['recognized'] is False

def call(n,**args):return json.loads(asyncio.run(server.call_tool(n,args))[0].text)
@pytest.mark.parametrize('args',[{'version':6,'expectedPhotoId':'a'},{'version':'15.4','expectedPhotoId':'a'},{'version':'Version 6'}])
def test_schema_no_transport(monkeypatch,args):
 monkeypatch.setattr(server,'send_to_lightroom',lambda *a,**k:pytest.fail('unexpected transport'))
 assert call('lr_set_process_version',**args)['code']=='invalid_arguments'

def test_ipc(mock_lr):
 assert call('lr_get_process_version')['data']['version']=='Version 5'
 assert call('lr_set_process_version',version='Version 6',expectedPhotoId='mock-photo-1',expectedVersion='Version 5')['data']['rawVersion']=='15.4'
 assert call('lr_set_process_version',version='Version 4',expectedPhotoId='mock-photo-1',expectedVersion='Version 5')['code']=='process_version_changed'


def test_multiple_selection_rejected_before_conversion(sdk):
 lua,s,p,c=sdk;s.selection=lua.table_from([p.a,p.b])
 assert c('set_process_version',version='Version 6',expectedPhotoId='a')['code']=='multiple_selection'
 assert s.processCalls==0
