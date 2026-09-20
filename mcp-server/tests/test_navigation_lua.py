from pathlib import Path
import pytest
from lupa.lua51 import LuaRuntime
PLUGIN=Path(__file__).resolve().parents[2]/'lrplugin/lightroom-mcp.lrdevplugin'
@pytest.fixture
def sdk():
 lua=LuaRuntime(unpack_returned_tuples=True)
 for n in ['library_fixture.lua','navigation_fixture.lua']:lua.execute(Path(__file__).with_name(n).read_text())
 fine=lua.execute((PLUGIN/'Fine.lua').read_text());lib=lua.execute((PLUGIN/'Library.lua').read_text())
 def call(cmd,**args):
  module=fine if fine.commands[cmd] else lib
  return module.handle(lua.table_from({'command':cmd,**args},recursive=True))
 return lua,lua.globals().state,lua.globals().photos,call

def test_geometry_read_and_rotation(sdk):
 _,s,p,c=sdk;assert c('get_geometry')['data']['orientation']=='AB' and s.module=='library'
 assert c('rotate_photo',direction='right')['data']['orientation']=='BC'
 assert c('rotate_photo',direction='left')['data']['orientation']=='AB'
 assert p.b.meta.orientation=='AB'
 s.noop=True;assert c('rotate_photo',direction='right')['code']=='rotation_unverified'

@pytest.mark.parametrize('orientation',['AB','BC','CD','DA','BA','AD','DC','CB'])
def test_rotation_mirrored_roundtrip(sdk,orientation):
 _,s,p,c=sdk;p.a.meta.orientation=orientation
 assert c('rotate_photo',direction='right')['success']
 assert c('rotate_photo',direction='left')['data']['orientation']==orientation

def test_geometry_guards_and_crop(sdk):
 _,s,p,c=sdk
 assert c('rotate_photo',direction='right',expectedPhotoId='b')['code']=='photo_changed'
 assert c('set_crop_aspect',width=4,height=5)['data']['effectiveRatio']==.8
 assert c('set_crop_aspect',preset='original')['data']['effectiveRatio']==1.5
 assert c('set_crop_aspect',preset='asshot')['data']['verification']=='native_call_and_observation'
 assert c('set_crop_aspect',preset='original',width=1,height=1)['code']=='invalid_arguments'
 assert c('set_crop_aspect',width=0,height=1)['code']=='invalid_arguments'
 s.noop=True;assert c('set_crop_aspect',width=1,height=1)['code']=='crop_unverified'

def test_scoped_resets_and_noop(sdk):
 _,s,p,c=sdk
 assert c('reset_adjustments',parameter='exposure')['data']['value']==0
 assert p.a.raw.PerspectiveVertical==12
 assert c('reset_adjustments',parameter='local_Exposure')['code']=='unsupported_parameter'
 assert c('reset_adjustments',parameter='Exposure',group='crop')['code']=='invalid_arguments'
 assert c('reset_adjustments',group='transforms')['success'] and p.a.raw.PerspectiveVertical==0
 assert c('reset_adjustments',group='masking')['success'] and len(p.a.raw.MaskGroupBasedCorrections)==0
 assert len(p.b.raw.MaskGroupBasedCorrections)==1
 s.noop=True;assert c('reset_adjustments',group='redeye')['code']=='reset_unverified'
 s.noop=False;assert c('reset_adjustments',group='redeye')['success']

def test_folders_sources_and_preflight(sdk):
 _,s,p,c=sdk
 assert c('list_folders')['data']['folders'][1]['path']=='/photos'
 assert c('list_folder_photos',folderPath='/photos',includeChildren=True,limit=1)['data']['hasMore'] and s.includeChildren
 assert c('set_sources',folderPaths=['/photos','/missing'])['code']=='folder_not_found'
 assert s.sources[1]=='all'
 assert c('set_sources',folderPaths=['/photos'])['data']['sources'][1]['kind']=='folder'
 assert c('set_sources',allPhotos=True)['data']['sources'][1]['id']=='all'
 assert c('set_sources',allPhotos=True,folderPaths=['/photos'])['code']=='invalid_arguments'

def test_view_navigation_preserves_filters(sdk):
 _,s,p,c=sdk;s.filter.minRating=3
 assert c('show_view',view='develop_before')['data']['verification']=='module_only'
 assert s.module=='develop'
 assert c('show_view',view='grid')['success']
 assert c('navigate_photos',action='next')['data']['activePhotoId']=='b'
 assert c('navigate_photos',action='previous')['data']['activePhotoId']=='a'
 assert c('navigate_photos',action='all')['data']['total']==2
 assert s.filter.minRating==3 and s.sources[1]=='all'
 s.noop=True;assert c('navigate_photos',action='next')['data']['status']=='unchanged_or_boundary'

def test_filters_patch_stale_and_noop(sdk):
 _,s,p,c=sdk;before=c('get_navigation')['data']['viewFilter']
 assert c('set_view_filter',changes={'filtersActive':True,'minRating':4},expectedFilter=before)['success']
 assert s.filter.searchString==''
 assert c('set_view_filter',changes={'minRating':2},expectedFilter=before)['code']=='filter_changed'
 assert c('set_view_filter',presetId='missing')['code']=='preset_not_found'
 assert c('set_view_filter',presetId='off')['success']
 s.noop=True;assert c('set_view_filter',changes={'minRating':2})['code']=='filter_unverified'
 assert c('set_view_filter',changes={'unknown':True})['code']=='invalid_arguments'

def test_navigation_no_photo_and_missing_api(sdk):
 lua,s,p,c=sdk;s.selected='missing'
 assert c('get_navigation')['data']['total']==0
 assert c('show_view',view='develop_loupe')['code']=='no_photo'
 s.selected='a';lua.globals().selection.nextPhoto=None
 assert c('navigate_photos',action='next')['code']=='unsupported_api'


def test_invalid_orientation_and_missing_original_dimensions_preflight(sdk):
 _,s,p,c=sdk;p.a.meta.orientation='AA'
 assert c('rotate_photo',direction='right')['code']=='unsupported_orientation'
 p.a.meta.dimensions=None
 assert c('set_crop_aspect',preset='original')['code']=='dimensions_unavailable'
 assert p.a.raw.HasCrop is False

def test_crop_reset_uses_catalog_fields_and_preserves_other_edits(sdk):
 _,s,p,c=sdk;p.a.raw.CropLeft=.2;p.a.raw.CropRight=.8;p.a.raw.HasCrop=True;p.a.raw.CropAngle=5
 r=c('reset_adjustments',group='crop')
 assert r['success'] and r['data']['backend']=='catalog_crop_fields'
 assert p.a.raw.CropLeft==0 and p.a.raw.CropRight==1 and p.a.raw.CropAngle==0
 assert p.a.raw.Exposure2012==1 and p.b.raw.Exposure2012==1
 p.a.raw.CropLeft=.2;s.noop=True
 assert c('reset_adjustments',group='crop')['code']=='reset_unverified'

def test_folder_sort_does_not_call_yielding_metadata_inside_comparator(sdk):
 lua,s,p,c=sdk
 lua.execute('''
  for _,photo in pairs(photos)do
   local original=photo.getRawMetadata
   function photo:getRawMetadata(key)
    for level=2,10 do local info=debug.getinfo(level,'n');if not info then break end;assert(info.name~='sort','SDK metadata cannot be called from table.sort')end
    return original(self,key)
   end
  end
 ''')
 r=c('list_folder_photos',folderPath='/photos');assert r['success'] and r['data']['photos'][1]['photoId']=='a'
