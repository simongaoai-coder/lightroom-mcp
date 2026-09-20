from pathlib import Path
import pytest
from lupa.lua51 import LuaRuntime
PLUGIN=Path(__file__).resolve().parents[2]/'lrplugin/lightroom-mcp.lrdevplugin'

@pytest.fixture
def sdk():
 lua=LuaRuntime(unpack_returned_tuples=True)
 lua.execute(Path(__file__).with_name('library_fixture.lua').read_text())
 m=lua.execute((PLUGIN/'Library.lua').read_text())
 def call(cmd,**args):return m.handle(lua.table_from({'command':cmd,**args},recursive=True))
 return lua,lua.globals().state,lua.globals().photos,call


def test_search_uses_native_filters_and_pagination(sdk):
 _,state,_,call=sdk
 r=call('search_photos',filters={'minRating':3,'filename':'a'},limit=1)['data']
 assert r['total']==1 and r['photos'][1]['photoId']=='a'
 assert state.search.combine=='intersect'
 assert call('search_photos',limit=1)['data']['hasMore']
 assert call('search_photos',offset=1)['data']['photos'][1]['photoId']=='b'


def test_selection_explicit_and_verified(sdk):
 _,state,_,call=sdk
 r=call('select_photos',photoIds=['a','b'],activePhotoId='b')
 assert r['success'] and state.selected=='b' and len(state.selection)==2
 assert state.sources[1]=='all'
 assert call('select_photos',photoIds=['missing'])['code']=='photo_not_found'
 assert state.selected=='b'


def test_selection_noop_and_catalog_guard(sdk):
 _,state,_,call=sdk
 state.selectionNoop=True
 assert call('select_photos',photoIds=['b'])['code']=='selection_failed'
 assert call('search_photos',expectedCatalogPath='/other')['code']=='catalog_changed'


def test_metadata_read_write_clear_and_isolation(sdk):
 _,_,photos,call=sdk
 r=call('set_metadata',photoIds=['a'],values={'rating':5,'pickStatus':1,'title':'中文标题','gps':{'latitude':30,'longitude':120}})
 assert r['success'] and photos.a.meta.title=='中文标题' and photos.b.meta.rating==1
 assert call('set_metadata',photoIds=['a'],clearFields=['gps','title'])['success']
 assert photos.a.meta.gps is None and photos.a.meta.title==''
 r=call('get_metadata',photoIds=['a'],fields=['title','gps'])['data']['photos'][1]
 assert r['metadata']['title']=='' and r['missingFields'][1]=='gps'


def test_batch_metadata_partial_failure_and_preflight(sdk):
 _,state,photos,call=sdk
 assert call('set_metadata',photoIds=['a','missing'],values={'rating':5})['code']=='photo_not_found'
 assert state.writes==0
 state.failPhoto='b'
 r=call('set_metadata',photoIds=['a','b'],values={'rating':5})
 assert not r['success'] and r['applied']==1 and r['failed']==1
 assert photos.a.meta.rating==5 and photos.b.meta.rating==1


def test_silent_metadata_failure_and_lock_timeout(sdk):
 _,state,_,call=sdk
 state.noop=True
 assert call('set_metadata',values={'rating':2})['data']['results'][1]['code']=='readback_failed'
 state.noop=False;state.lockTimeout=True
 assert call('set_metadata',values={'rating':2})['data']['results'][1]['code']=='write_timeout'


def test_keyword_hierarchy_and_assignments(sdk):
 _,_,photos,call=sdk
 parent=call('create_keyword',name='旅行')['data']['keywordId']
 child=call('create_keyword',name='杭州',parentId=parent,synonyms=['Hangzhou'])['data']['keywordId']
 assert call('create_keyword',name='杭州',parentId=parent)['data']['status']=='existing'
 assert call('list_keywords',query='旅行')['data']['total']==2
 assert call('update_keyword',keywordId=child,includeOnExport=False,name='西湖')['success']
 assert call('update_photo_keywords',photoIds=['a','b'],keywordIds=[child],operation='add')['success']
 assert len(photos.a.meta.keywords)==len(photos.b.meta.keywords)==1
 assert call('update_photo_keywords',photoIds=['a'],keywordIds=[child],operation='remove')['success']
 assert len(photos.a.meta.keywords)==0 and len(photos.b.meta.keywords)==1


def test_collection_tree_members_smart_and_delete(sdk):
 _,_,_,call=sdk
 parent=call('create_collection',name='交付',kind='set')['data']['collectionId']
 normal=call('create_collection',name='精选',parentId=parent)['data']['collectionId']
 smart=call('create_collection',name='高分',kind='smart',parentId=parent,filters={'minRating':3})['data']['collectionId']
 assert call('create_collection',name='精选',parentId=parent)['code']=='collection_exists'
 assert call('update_collection_photos',collectionId=normal,photoIds=['a','b'],operation='add')['success']
 assert call('search_photos',collectionId=normal)['data']['total']==2
 assert call('search_photos',collectionId=smart)['data']['total']==1
 assert call('update_collection',collectionId=smart,filters={'minRating':5},name='五星')['success']
 assert call('update_collection_photos',collectionId=smart,photoIds=['a'],operation='add')['code']=='unsupported_collection'
 assert call('delete_collection',collectionId=parent)['code']=='collection_not_empty'
 assert call('delete_collection',collectionId=normal)['code']=='collection_not_empty'
 assert call('update_collection_photos',collectionId=normal,photoIds=['a','b'],operation='remove')['success']
 assert call('delete_collection',collectionId=normal)['success']
 assert call('delete_collection',collectionId=smart)['success']
 assert call('delete_collection',collectionId=parent)['success']
 assert call('list_collections')['data']['total']==0


@pytest.mark.parametrize('cmd,args',[
 ('set_metadata',{'values':{'rating':7}}),('set_metadata',{'values':{'gps':{'latitude':91,'longitude':0}}}),
 ('set_metadata',{'values':{'title':'x'},'clearFields':['title']}),('set_metadata',{'values':{}}),
 ('get_metadata',{'photoIds':['a'],'scope':'selected'}),
 ('search_photos',{'filters':{'captureAfter':'2026-02-30'}}),('search_photos',{'filters':{'minRating':4,'maxRating':2}}),
 ('create_collection',{'name':'x','kind':'smart'}),('create_collection',{'name':'x','filters':{'minRating':2}}),
])
def test_preflight_validation_never_writes(sdk,cmd,args):
 _,state,_,call=sdk
 assert not call(cmd,**args)['success'] and state.writes==0


def test_expected_photo_protects_mutations(sdk):
 _,state,_,call=sdk
 assert call('set_metadata',values={'rating':5},expectedPhotoId='b')['code']=='photo_changed'
 state.switchBeforeWrite=True
 r=call('set_metadata',values={'rating':5},expectedPhotoId='a')
 assert not r['success'] and state.writes==0


def test_iptc_formatted_getters_and_unlabelled_gray(sdk):
 _,_,photos,call=sdk
 photos.a.meta.colorNameForLabel='gray'
 photos.a.meta.label=''
 r=call('get_metadata',fields=['title','label','colorNameForLabel'])['data']['photos'][1]
 assert r['metadata']['title']=='Original a' and r['metadata']['label']==''
 assert r['metadata']['colorNameForLabel']=='none' and r['colorNameForLabel']=='none'
 assert call('set_metadata',values={'label':'Custom label','caption':'中文说明'})['success']
 assert call('set_metadata',clearFields=['label','caption'])['success']


def test_missing_metadata_serializes_as_an_object(sdk):
 import json
 lua,_,_,_=sdk
 lua.execute('''
  local old=import
  function import(name)
   if name=="LrFileUtils" or name=="LrDevelopController" then return {} end
   if name=="LrLogger" then return function()return {enable=function()end}end end
   return old(name)
  end
  _PLUGIN={path="/test/plugin"}
 ''')
 lua.globals().libraryModule=lua.execute((PLUGIN/'Library.lua').read_text())
 lua.execute('function require(name)if name=="Library" then return libraryModule end;return {commands={}}end')
 module=lua.execute((PLUGIN/'Server.lua').read_text())
 v=lua.execute((PLUGIN/'Info.lua').read_text())['VERSION']
 request={'command':'get_metadata','fields':['gps'],'expectedPluginVersion':'.'.join(str(v[k]) for k in ['major','minor','revision'])}
 result=json.loads(module.handleRequest(json.dumps(request)))
 assert result['success']
 assert result['data']['photos'][0]['metadata']=={}
 assert result['data']['photos'][0]['missingFields']==['gps']


def test_source_refresh_finishes_before_selection_and_is_not_repeated(sdk):
 _,state,_,call=sdk
 state.deferSources=True
 assert call('select_photos',photoIds=['b'])['success']
 assert state.selected=='b' and state.sourceWrites==1
 assert call('select_photos',photoIds=['a'])['success']
 assert state.selected=='a' and state.sourceWrites==1
