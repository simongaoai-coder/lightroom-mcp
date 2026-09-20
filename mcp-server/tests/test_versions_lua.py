from pathlib import Path
import pytest
from lupa.lua51 import LuaRuntime

PLUGIN=Path(__file__).resolve().parents[2]/'lrplugin/lightroom-mcp.lrdevplugin'

@pytest.fixture
def sdk():
    lua=LuaRuntime(unpack_returned_tuples=True)
    for name in ['develop_fixture.lua','versions_fixture.lua']:
        lua.execute(Path(__file__).with_name(name).read_text())
    module=lua.execute((PLUGIN/'Versions.lua').read_text())
    def call(command,**args):
        return module.handle(lua.table_from({'command':command,**args},recursive=True))
    return lua,lua.globals().state,lua.globals().photos,call


def test_snapshot_lifecycle_uses_different_apply_and_delete_ids(sdk):
    _,state,photos,call=sdk
    saved=call('create_snapshot',name='修图前')['data']
    assert saved['snapshotId']=='local-1' and saved['globalId']=='global-1'
    photos.a.raw.Exposure2012=2
    restored=call('apply_snapshot',snapshotId=saved['snapshotId'])
    assert restored['success'] and photos.a.raw.Exposure2012==0 and state.module=='develop'
    assert call('delete_snapshot',snapshotId=saved['snapshotId'])['success']
    assert len(call('list_snapshots')['data']['snapshots'])==0


def test_duplicate_snapshot_requires_explicit_update(sdk):
    _,_,photos,call=sdk
    first=call('create_snapshot',name='before')['data']['snapshotId']
    photos.a.raw.RedHue=20
    assert call('create_snapshot',name='before')['code']=='snapshot_exists'
    updated=call('create_snapshot',name='before',updateExisting=True)['data']['snapshotId']
    assert updated != first
    assert call('apply_snapshot',snapshotId=first)['code']=='snapshot_not_found'
    photos.a.raw.RedHue=0
    assert call('apply_snapshot',snapshotId=updated)['success']
    assert photos.a.raw.RedHue==20


@pytest.mark.parametrize('cmd,args',[
    ('apply_snapshot',{'snapshotId':'unknown'}),('delete_snapshot',{'snapshotId':'unknown'}),
    ('select_virtual_copy',{'photoId':'b'}),('apply_preset',{'presetId':'same name is not an ID'}),
])
def test_invalid_ids_never_fall_back(sdk,cmd,args):
    _,state,photos,call=sdk
    assert not call(cmd,**args)['success']
    assert state.selected=='a' and state.presetCalls is None and photos.a.raw.Exposure2012==0


def test_creation_and_deletion_silent_failures(sdk):
    _,state,_,call=sdk
    state.createNoop=True
    assert call('create_snapshot',name='test')['code']=='snapshot_not_verified'
    state.createNoop=False
    saved=call('create_snapshot',name='test')['data']['snapshotId']
    state.deleteNoop=True
    assert call('delete_snapshot',snapshotId=saved)['code']=='deletion_failed'
    state.badSnapshots=True
    assert call('list_snapshots')['code']=='unsupported_snapshot_data'


def test_photo_guard_and_write_timeout(sdk):
    _,state,_,call=sdk
    assert call('create_snapshot',name='test',expectedPhotoId='b')['code']=='photo_changed'
    state.lockTimeout=True
    assert call('create_snapshot',name='test')['code']=='write_timeout'
    state.lockTimeout=False;state.switchBeforeWrite=True
    assert call('create_snapshot',name='test')['code']=='photo_changed'


def test_snapshots_from_other_photo_rejected(sdk):
    _,state,_,call=sdk
    saved=call('create_snapshot',name='test')['data']['snapshotId']
    state.selected='b'
    assert call('apply_snapshot',snapshotId=saved)['code']=='snapshot_not_found'


def test_presets_search_pagination_and_duplicate_names(sdk):
    _,_,_,call=sdk
    result=call('list_presets',query='同名',limit=1)['data']
    assert result['total']==2 and result['hasMore']
    assert result['presets'][1]['presetId']=='p-a'
    next_page=call('list_presets',query='同名',limit=1,offset=1)['data']
    assert next_page['presets'][1]['presetId']=='p-b' and not next_page['hasMore']
    assert len(call('list_presets',query='missing')['data']['presets'])==0


def test_apply_exact_preset_and_native_options(sdk):
    _,state,photos,call=sdk
    assert call('apply_preset',presetId='p-b')['success']
    assert photos.a.raw.Exposure2012==-.8 and photos.b.raw.Exposure2012==0
    assert call('apply_preset',presetId='p-owned',amount=50,updateAISettings=True)['success']
    assert state.lastAmount==50 and state.lastAI and state.lastPlugin.id=='test.plugin'


def test_batch_preset_partial_failure_stops(sdk):
    lua,state,photos,call=sdk
    state.selection=lua.table_from([photos.a,photos.b]);state.failPreset='b'
    result=call('apply_preset',presetId='p-a',scope='selected')
    assert not result['success'] and result['applied']==1 and result['failed']==1
    assert result['data']['results'][2]['outcomeUnknown']
    assert photos.a.raw.Exposure2012==1.2 and photos.b.raw.Exposure2012==0


def test_batch_preflight_rejects_video(sdk):
    lua,state,photos,call=sdk
    state.selection=lua.table_from([photos.a,photos.b]);photos.b.video=True
    assert call('apply_preset',presetId='p-a',scope='selected')['code']=='unsupported_photo'
    assert state.presetCalls is None


def test_create_copy_current_scope_narrows_selection(sdk):
    lua,state,photos,call=sdk
    state.selection=lua.table_from([photos.a,photos.b])
    result=call('create_virtual_copies',copyName='暖色方案')
    assert result['success'] and result['data']['count']==1
    copy_id=result['data']['created'][1]['photoId']
    assert state.selected==copy_id and photos[copy_id].copyName=='暖色方案'
    assert photos.a.raw.Exposure2012==0
    versions=call('list_virtual_copies')['data']['versions']
    assert len(versions)==2
    assert call('select_virtual_copy',photoId='a')['success']
    assert state.selected=='a'
    assert call('select_virtual_copy',photoId=copy_id)['success']


def test_batch_copy_returns_each_new_family_member(sdk):
    lua,state,photos,call=sdk
    state.selection=lua.table_from([photos.a,photos.b])
    result=call('create_virtual_copies',scope='selected')
    assert result['success'] and result['data']['count']==2
    assert result['data']['selectionMatchesCreated']
    assert len(photos.a.copies)==len(photos.b.copies)==1


def test_copy_silent_failure_and_selection_noop(sdk):
    lua,state,photos,call=sdk
    state.copyNoop=True
    assert call('create_virtual_copies')['code']=='partial_creation'
    state.copyNoop=False;state.selectionNoop=True;state.selection=lua.table_from([photos.a,photos.b])
    assert call('create_virtual_copies')['code']=='selection_changed'
    assert state.nextCopy==0


def test_missing_api_and_no_photo(sdk):
    _,state,photos,call=sdk
    photos.a.createDevelopSnapshot=None
    assert call('create_snapshot',name='test')['code']=='unsupported_api'
    state.selected=None
    assert call('list_snapshots')['code']=='no_photo'
    assert call('list_presets')['success']


@pytest.mark.parametrize('cmd,args',[
    ('create_snapshot',{'name':' '}),('apply_snapshot',{'snapshotId':''}),
    ('create_virtual_copies',{'scope':'all'}),('apply_preset',{'presetId':'p-a','amount':201}),
    ('list_presets',{'offset':-1}),('list_presets',{'limit':float('nan')}),
])
def test_lua_boundary_validation(sdk,cmd,args):
    _,_,_,call=sdk
    assert call(cmd,**args)['code']=='invalid_arguments'


def test_ai_update_requires_real_api_before_any_preset_write(sdk):
    _,state,photos,call=sdk
    photos.a.updateAISettings=None
    assert call('apply_preset',presetId='p-a',updateAISettings=True)['code']=='unsupported_api'
    assert state.presetCalls is None


def test_control_characters_in_snapshot_names_rejected(sdk):
    _,state,_,call=sdk
    assert call('create_snapshot',name='test\bname')['code']=='invalid_arguments'
    assert state.nextSnapshot==0


def test_production_json_dispatch_preserves_snapshot_names(sdk):
    import json
    lua,_,_,_=sdk
    lua.execute('''
        local baseImport=import
        function import(name)
            if name=="LrFileUtils" then return {} end
            if name=="LrLogger" then return function() return {enable=function() end} end end
            return baseImport(name)
        end
    ''')
    lua.globals().versionsModule=lua.execute((PLUGIN/'Versions.lua').read_text())
    lua.execute('function require(name) if name=="Versions" then return versionsModule end; return {commands={}} end')
    module=lua.execute((PLUGIN/'Server.lua').read_text())
    version=lua.execute((PLUGIN/'Info.lua').read_text())['VERSION']
    request={'command':'create_snapshot','name':'测试快照 🎞️',
             'expectedPluginVersion':'.'.join(str(version[k]) for k in ['major','minor','revision']),
             'requestId':'unicode-test'}
    result=json.loads(module.handleRequest(json.dumps(request,ensure_ascii=False)))
    assert result['success'] and result['data']['name']==request['name']
    assert result['requestId']=='unicode-test'
