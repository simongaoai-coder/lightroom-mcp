from pathlib import Path
import pytest
from lupa.lua51 import LuaRuntime
PLUGIN=Path(__file__).resolve().parents[2]/'lrplugin/lightroom-mcp.lrdevplugin'
@pytest.fixture
def sdk():
 lua=LuaRuntime(unpack_returned_tuples=True)
 for f in ['develop_fixture.lua','versions_fixture.lua','history_fixture.lua']:lua.execute(Path(__file__).with_name(f).read_text())
 lua.globals().developModule=lua.execute((PLUGIN/'Develop.lua').read_text())
 m=lua.execute((PLUGIN/'Versions.lua').read_text())
 def call(cmd,**args):m.beforeCommand(cmd);return m.handle(lua.table_from({'command':cmd,**args},recursive=True))
 return lua,lua.globals().state,lua.globals().photos,call,m

def test_explicit_freezes_values_not_source_or_native_clipboard(sdk):
 _,s,p,c,_=sdk
 r=c('copy_settings',copyId='a'*32,mode='explicit',parameters=['Exposure']);assert r['success'] and r['data']['settings']['Exposure']==0
 p.a.raw.Exposure2012=3;s.selected='b'
 r=c('paste_settings',copyId='a'*32,expectedPhotoId='b');assert r['success'] and p.b.raw.Exposure2012==0 and s.copyCalls==s.pasteCalls==0
 assert c('copy_settings',copyId='b'*32,mode='explicit',parameters=['Exposure','exposure'])['code']=='invalid_arguments'
 assert c('copy_settings',copyId='c'*32,mode='explicit',parameters=['arbitrary'])['code']=='unsupported_parameter'

def test_native_recopy_and_single_target(sdk):
 lua,s,p,c,_=sdk;p.a.raw.Exposure2012=1.2
 r=c('copy_settings',copyId='a'*32);assert r['success'] and r['data']['scope']=='ui_categories_unenumerated'
 s.clipboard=lua.table_from({'Exposure2012':4});s.selected='b'
 r=c('paste_settings',copyId='a'*32,expectedPhotoId='b');assert r['success'] and p.b.raw.Exposure2012==1.2 and s.copyCalls==2
 assert r['data']['verification']=='native_call_and_observation' and not r['data']['clipboardScopeVerified']

def test_native_source_changed_and_guard(sdk):
 _,s,p,c,_=sdk
 c('copy_settings',copyId='a'*32);p.a.raw.Exposure2012=4;s.selected='b'
 assert c('paste_settings',copyId='a'*32,expectedPhotoId='b')['code']=='source_changed' and s.pasteCalls==0
 assert c('paste_settings',copyId='a'*32,expectedPhotoId='a')['code']=='photo_changed'
 s.path='/other';assert c('paste_settings',copyId='a'*32,expectedPhotoId='b')['code']=='catalog_changed'

def test_failed_copy_never_produces_receipt(sdk):
 _,s,p,c,_=sdk;s.copyFail=True
 assert c('copy_settings',copyId='a'*32)['code']=='copy_failed'
 assert c('paste_settings',copyId='a'*32,expectedPhotoId='a')['code']=='copy_not_found'

def test_explicit_readback_failure_propagates(sdk):
 _,s,p,c,_=sdk;p.a.raw.Exposure2012=2;c('copy_settings',copyId='a'*32,mode='explicit',parameters=['Exposure']);s.selected='b';s.noop=True
 r=c('paste_settings',copyId='a'*32,expectedPhotoId='b');assert not r['success']

def native_paste(s,p,c):
 p.a.raw.Exposure2012=2;c('copy_settings',copyId='a'*32);s.selected='b';c('paste_settings',copyId='a'*32,expectedPhotoId='b')

def test_undo_redo_context_and_single_use(sdk):
 _,s,p,c,_=sdk;native_paste(s,p,c)
 assert c('get_history_state',historyToken='b'*32)['data']['canUndo']
 r=c('undo',historyToken='b'*32);assert r['success'] and p.b.raw.Exposure2012==0
 assert c('undo',historyToken='b'*32)['code']=='history_token_invalid'
 assert c('get_history_state',historyToken='c'*32)['data']['canRedo']
 assert c('redo',historyToken='c'*32)['success'] and p.b.raw.Exposure2012==2

def test_manual_context_change_and_expiry(sdk):
 _,s,p,c,_=sdk;native_paste(s,p,c)
 c('get_history_state',historyToken='b'*32);p.b.raw.Exposure2012=3
 assert c('undo',historyToken='b'*32)['code']=='history_state_changed'
 c('get_history_state',historyToken='c'*32);s.now+=61
 assert c('undo',historyToken='c'*32)['code']=='history_token_expired'

def test_intervening_mcp_mutation_invalidates(sdk):
 _,s,p,c,m=sdk;native_paste(s,p,c)
 c('get_history_state',historyToken='b'*32);m.beforeCommand('get_settings')
 assert c('undo',historyToken='b'*32)['success']
 c('get_history_state',historyToken='c'*32);m.beforeCommand('rotate_photo')
 assert c('redo',historyToken='c'*32)['code']=='history_token_invalid'

def test_unavailable_and_uncertain_undo_consume_token(sdk):
 _,s,p,c,_=sdk
 c('get_history_state',historyToken='b'*32);assert c('undo',historyToken='b'*32)['code']=='history_unavailable'
 native_paste(s,p,c);c('get_history_state',historyToken='c'*32);s.undoError=True
 assert c('undo',historyToken='c'*32)['code']=='sdk_error'
 assert c('undo',historyToken='c'*32)['code']=='history_token_invalid' and s.undoCalls==1

def test_receipt_eviction(sdk):
 _,s,p,c,_=sdk
 for n in range(21):assert c('copy_settings',copyId=f'{n:032x}',mode='explicit',parameters=['Exposure'])['success']
 assert c('paste_settings',copyId='0'*32,expectedPhotoId='a')['code']=='copy_not_found'
