from pathlib import Path
import json
import pytest
from lupa.lua51 import LuaRuntime
PLUGIN=Path(__file__).resolve().parents[2]/'lrplugin/lightroom-mcp.lrdevplugin'

@pytest.fixture
def sdk():
    lua=LuaRuntime(unpack_returned_tuples=True)
    for name in ['library_fixture.lua','workflow_fixture.lua']:
        lua.execute(Path(__file__).with_name(name).read_text())
    library=lua.execute((PLUGIN/'Library.lua').read_text())
    lua.globals().libraryModule=library
    lua.execute("function require(name) assert(name=='Library');return libraryModule end")
    develop=lua.execute((PLUGIN/'Develop.lua').read_text())
    def call(command,**args):return develop.handle(lua.table_from({'command':command,**args},recursive=True))
    return lua,lua.globals().state,lua.globals().photos,call,develop


def test_batch_filtered_read_without_active_photo(sdk):
    _,s,p,c,_=sdk;s.selected='missing'
    r=c('get_settings',photoIds=['b','a'],parameters=['exposure','Texture'])
    assert r['success'] and r['data']['read']==2
    rows=r['data']['photos']
    assert rows[1]['photoId']=='b' and rows[1]['settings']['Exposure']==1
    assert rows[2]['settings']['Exposure']==0 and rows[2]['parameterKeys']['Exposure']=='Exposure2012'
    assert list(rows[1]['unavailableParameters'].values())==['Texture']
    assert rows[1]['rawSettings'] is None and s.selected=='missing' and s.writes==0


def test_current_response_compatible_and_explicit_scope_is_batch(sdk):
    _,s,p,c,_=sdk
    r=c('get_settings',parameters=['Exposure'])['data']
    assert r['photos'] is None and r['settings']['Exposure']==0
    assert c('get_settings',expectedCatalogPath='/test/catalog.lrcat')['data']['photoId']=='a'
    assert c('get_settings',scope='current')['data']['photos'][1]['photoId']=='a'
    assert c('get_settings',photoIds=['a'],includeRaw=True)['data']['photos'][1]['rawSettings']['ProcessVersion']=='15.4'


def test_getter_error_keeps_other_photo_results(sdk):
    lua,s,p,c,_=sdk
    lua.execute("function photos.b:getDevelopSettings()error('photo getter failed')end")
    r=c('get_settings',photoIds=['a','b'],parameters=['Exposure'])
    assert not r['success'] and r['code']=='partial_failure'
    assert r['data']['read']==1 and r['data']['failed']==1
    assert r['data']['photos'][1]['settings']['Exposure']==0
    assert r['data']['photos'][2]['code']=='sdk_error' and s.writes==0


@pytest.mark.parametrize('args',[
    {'parameters':[]},{'parameters':['Exposure','exposure']},{'parameters':['unknown']},
    {'photoIds':['a'],'scope':'selected'},{'photoIds':['missing']},
    {'expectedPhotoId':'b'},{'expectedCatalogPath':'wrong'}, {'includeRaw':'true'},
])
def test_bad_read_requests_do_not_fallback_or_write(sdk,args):
    _,s,_,c,_=sdk
    assert not c('get_settings',**args)['success'] and s.writes==0 and s.selected=='a'


def test_preflight_absolute_discloses_implicit_changes_without_writes(sdk):
    lua,s,p,c,_=sdk
    lua.execute('''
    function catalog:withWriteAccessDo()error('must not acquire write access')end
    function catalog:setSelectedPhotos()error('must not change selection')end
    function photos.a:applyDevelopSettings()error('must not apply settings')end
    ''')
    r=c('preflight_settings',settings={'Temperature':6000,'Exposure':.3},photoIds=['a'])['data']
    row=r['photos'][1]
    assert r['canApply'] and r['readOnly']
    assert row['before']['Temperature']==6500 and row['target']['Temperature']==6000
    assert row['parameterKeys']['Exposure']=='Exposure2012'
    assert row['catalogChanges']['WhiteBalance']=='Custom' and row['catalogChanges']['Exposure2012']==.3
    assert p.a.raw.Temperature==6500 and p.a.raw.Exposure2012==0 and s.writes==0


def test_relative_targets_match_execution(sdk):
    _,s,p,c,_=sdk
    args={'photoIds':['a','b'],'deltas':{'Exposure':.5,'Contrast':-5}}
    preview=c('preflight_settings',mode='relative',**args)['data']
    assert preview['canApply'] and s.writes==0
    actual=c('batch_adjust_relative',**args)
    assert actual['success']
    for i in [1,2]:
        assert dict(preview['photos'][i]['target'].items())==dict(actual['data']['results'][i]['after'].items())


def test_preflight_aggregates_per_photo_blockers(sdk):
    _,s,p,c,_=sdk
    p.b.raw.Exposure2012=4.9
    r=c('preflight_settings',mode='relative',photoIds=['a','b'],deltas={'Exposure':.5})
    assert r['success'] and not r['data']['canApply']
    assert r['data']['readyCount']==1 and r['data']['blockedCount']==1
    row=r['data']['photos'][2]
    assert row['code']=='out_of_range' and row['details']['target']==pytest.approx(5.4)
    assert not c('batch_adjust_relative',photoIds=['a','b'],deltas={'Exposure':.5})['success'] and s.writes==0


def test_preflight_mixed_wb_is_batch_issue(sdk):
    _,s,p,c,_=sdk;p.b.raw.IncrementalTemperature=0
    r=c('preflight_settings',mode='relative',photoIds=['a','b'],deltas={'Temperature':5})['data']
    assert not r['canApply'] and r['readyCount']==2 and r['blockedCount']==0
    assert r['batchIssues'][1]['code']=='mixed_parameter_units' and s.writes==0


def test_absolute_range_and_boolean_checks_shared_with_execution(sdk):
    _,s,p,c,_=sdk;p.a.raw.LensProfileEnable=False
    for settings in [{'Exposure':9},{'Temperature':1},{'LensProfileEnable':2}]:
        preview=c('preflight_settings',settings=settings)['data']
        assert not preview['canApply'] and preview['photos'][1]['code']=='out_of_range'
        assert c('apply_settings',settings=settings)['code']=='out_of_range'
    r=c('preflight_settings',settings={'LensProfileEnable':1})['data']['photos'][1]
    assert r['before']['LensProfileEnable']==0 and r['catalogChanges']['LensProfileEnable'] is True
    assert s.writes==0


def test_unchecked_ranges_are_explicit(sdk):
    _,s,p,c,_=sdk;p.a.raw.RedHue=0
    r=c('preflight_settings',settings={'RedHue':3})['data']['photos'][1]
    assert list(r['uncheckedRanges'].values())==['RedHue'] and s.writes==0


def test_unavailable_fields_video_missing_api_and_crop(sdk):
    _,s,p,c,_=sdk
    r=c('preflight_settings',settings={'Texture':10})['data']['photos'][1]
    assert r['code']=='unsupported_parameter' and list(r['unavailableParameters'].values())==['Texture']
    p.b.meta.isVideo=True
    assert c('preflight_settings',photoIds=['a','b'],settings={'Exposure':1})['data']['photos'][2]['code']=='unsupported_photo'
    p.a.applyDevelopSettings=None
    assert c('preflight_settings',settings={'Exposure':1})['data']['photos'][1]['code']=='unsupported_api'
    assert s.writes==0


def test_context_switch_during_read_fails_whole_request(sdk):
    lua,s,p,c,_=sdk
    lua.execute("local old=photos.b.getDevelopSettings;function photos.b:getDevelopSettings()state.path='/other';return old(self)end")
    assert c('get_settings',photoIds=['a','b'])['code']=='catalog_changed'


def test_empty_maps_remain_json_objects_in_real_dispatch(sdk):
    lua,s,p,c,develop=sdk
    lua.globals().developModule=develop
    lua.execute('''
    local old=import
    function import(name)
      if name=='LrFileUtils' then return {}end
      if name=='LrLogger' then return function()return {enable=function()end}end end
      return old(name)
    end
    function require(name)
      if name=='Develop' then return developModule end
      if name=='Library' then return libraryModule end
      return {commands={}}
    end
    _PLUGIN={path='/test/plugin'}
    ''')
    server=lua.execute((PLUGIN/'Server.lua').read_text())
    r=json.loads(server.handleRequest(json.dumps({'command':'get_settings','photoIds':['a'],'parameters':['Texture'],'expectedPluginVersion':'2.13.0'})))
    assert r['data']['photos'][0]['settings']=={} and r['data']['photos'][0]['parameterKeys']=={}
    r=json.loads(server.handleRequest(json.dumps({'command':'preflight_settings','mode':'relative','deltas':{'Exposure':0},'expectedPluginVersion':'2.13.0'})))
    assert r['success'] and r['data']['photos'][0]['catalogChanges']=={}


def test_crop_geometry_and_implicit_flag(sdk):
    _,s,p,c,_=sdk
    p.a.raw.CropTop=0;p.a.raw.CropBottom=1;p.a.raw.CropLeft=0;p.a.raw.CropRight=1
    r=c('preflight_settings',settings={'CropTop':.9,'CropBottom':.8})['data']
    assert not r['canApply'] and r['photos'][1]['code']=='invalid_arguments'
    row=c('preflight_settings',settings={'CropTop':.1})['data']['photos'][1]
    assert row['catalogChanges']['HasCrop'] is True and p.a.raw.CropTop==0 and s.writes==0


def test_execution_rechecks_state_after_preflight(sdk):
    _,s,p,c,_=sdk
    assert c('preflight_settings',mode='relative',deltas={'Exposure':1})['data']['canApply']
    p.a.raw.Exposure2012=5
    assert c('batch_adjust_relative',deltas={'Exposure':1})['code']=='out_of_range'
    assert s.writes==0
