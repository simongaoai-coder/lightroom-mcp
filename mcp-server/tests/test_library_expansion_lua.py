from pathlib import Path
import pytest
from lupa.lua51 import LuaRuntime
PLUGIN=Path(__file__).resolve().parents[2]/'lrplugin/lightroom-mcp.lrdevplugin'
@pytest.fixture
def sdk():
 lua=LuaRuntime(unpack_returned_tuples=True)
 for name in ['library_fixture.lua','library_expansion_fixture.lua']:lua.execute(Path(__file__).with_name(name).read_text())
 m=lua.execute((PLUGIN/'Library.lua').read_text())
 def call(cmd,**args):return m.handle(lua.table_from({'command':cmd,**args},recursive=True))
 return lua,lua.globals().state,lua.globals().photos,call

def ids(r):return [r['data']['photos'][i]['photoId']for i in range(1,len(r['data']['photos'])+1)]
def test_nested_search_and_boolean_false(sdk):
 _,s,p,c=sdk
 assert ids(c('search_photos',filters={'any':[{'cameraModel':'Camera A'},{'minISO':600}]}))==['a','b']
 assert ids(c('search_photos',filters={'any':[{'cameraModel':'Camera A'},{'minISO':600}],'none':[{'hasAdjustments':False}]}))==['a']
 assert ids(c('search_photos',filters={'hasGPS':False}))==['b']
 assert ids(c('search_photos',filters={'minISO':100,'maxISO':400,'lens':'Lens A'}))==['a']
 assert s.search.combine=='intersect'

def test_search_bounds_and_empty_groups(sdk):
 _,s,p,c=sdk
 for f in [{'any':[]},{'any':[{}]},{'minISO':500,'maxISO':100},{'hasAdjustments':'false'},{'cameraModel':''}]:assert c('search_photos',filters=f)['code']=='invalid_arguments'
 f={'minRating':1}
 for _ in range(10):f={'all':[f]}
 assert c('search_photos',filters=f)['code']=='invalid_arguments'
 assert c('search_photos',filters={'any':[{'minRating':1}for _ in range(50)],'all':[{'minRating':1}for _ in range(50)]})['code']=='invalid_arguments'

def test_smart_collection_uses_same_compiler(sdk):
 _,s,p,c=sdk
 r=c('create_collection',name='smart',kind='smart',filters={'any':[{'minRating':3},{'minISO':600}]});assert r['success']
 assert ids(c('search_photos',collectionId=r['data']['collectionId']))==['a','b']

def test_keyword_move_cycle_collision_and_members(sdk):
 _,s,p,c=sdk
 a=c('create_keyword',name='parent')['data']['keywordId'];b=c('create_keyword',name='child',parentId=a)['data']['keywordId'];d=c('create_keyword',name='other')['data']['keywordId']
 assert c('move_keyword',keywordId=a,parentId=b)['code']=='hierarchy_cycle'
 assert c('move_keyword',keywordId=b,parentId=d)['success']
 assert c('move_keyword',keywordId=b,parentId=0)['data']['parentId']==0
 e=c('create_keyword',name='child',parentId=a)['data']['keywordId']
 assert c('move_keyword',keywordId=e,parentId=0)['code']=='keyword_exists'
 c('update_photo_keywords',photoIds=['b'],keywordIds=[b],operation='add')
 assert ids(c('list_keyword_photos',keywordId=b))==['b']
 assert c('list_keywords')['data']['keywords'][1]['attributes'] is not None

def test_collection_move_cycle_and_gate(sdk):
 _,s,p,c=sdk
 a=c('create_collection',name='parent',kind='set')['data']['collectionId'];b=c('create_collection',name='child',kind='set',parentId=a)['data']['collectionId'];d=c('create_collection',name='photos')['data']['collectionId']
 assert c('move_collection',collectionId=a,parentId=b)['code']=='hierarchy_cycle'
 assert c('move_collection',collectionId=d,parentId=b)['success']
 assert c('move_collection',collectionId=b,parentId=d)['code']=='invalid_parent'
 s.noop=True;assert c('move_collection',collectionId=d,parentId=0)['code']=='readback_failed'

def test_virtual_copy_preflight_and_removal(sdk):
 _,s,p,c=sdk
 assert c('rename_virtual_copy',photoId='a',copyName='x')['code']=='not_virtual_copy'
 assert c('rename_virtual_copy',photoId='b',copyName='new',expectedCopyName='copy b')['success']
 assert c('remove_virtual_copy',photoId='b',expectedMasterPhotoId='wrong')['code']=='master_changed'
 assert s.removeCalls is None
 r=c('remove_virtual_copy',photoId='b',expectedMasterPhotoId='a',expectedCopyName='new');assert r['success'] and p.b is None and p.a is not None

def test_copy_selection_noop_never_removes_original(sdk):
 _,s,p,c=sdk;s.selectionNoop=True
 assert c('remove_virtual_copy',photoId='b',expectedMasterPhotoId='a')['code']=='selection_failed'
 assert s.removeCalls is None

def test_copy_removal_noop_is_reported(sdk):
 _,s,p,c=sdk;s.removeNoop=True
 assert c('remove_virtual_copy',photoId='b',expectedMasterPhotoId='a')['code']=='removal_unverified'
 assert p.b is not None and p.a is not None

def test_target_toggle_single_photo(sdk):
 lua,s,p,c=sdk
 r=c('toggle_target_collection',expectedPhotoId='a');assert r['success'] and r['data']['afterCollectionIds'][1]==99
 s.selection=lua.table_from([p.a,p.b]);assert c('toggle_target_collection',expectedPhotoId='a')['code']=='multiple_selection'

def test_metadata_preset_preflight_and_partial_results(sdk):
 _,s,p,c=sdk
 assert c('list_metadata_presets')['data']['presets'][1]['presetId']=='meta1'
 assert c('apply_metadata_preset',presetId='missing')['code']=='preset_not_found'
 assert c('apply_metadata_preset',presetId='meta1',photoIds=['a','missing'])['code']=='photo_not_found'
 s.failPhoto='b';r=c('apply_metadata_preset',presetId='meta1',photoIds=['a','b'],readbackFields=['title'])
 assert not r['success'] and r['applied']==1 and r['failed']==1 and p.a.meta.title=='preset title'


def test_master_remove_rejected_before_selection_changes(sdk):
 _,s,p,c=sdk
 assert c('remove_virtual_copy',photoId='a',expectedMasterPhotoId='a')['code']=='not_virtual_copy'
 assert s.removeCalls is None and s.sourceWrites is None

def test_target_toggle_can_intentionally_change_selection(sdk):
 lua,s,p,c=sdk
 lua.execute("function photos.a:addOrRemoveFromTargetCollection()state.selected='b';state.selection={photos.b}end")
 assert c('toggle_target_collection',expectedPhotoId='a')['success']
