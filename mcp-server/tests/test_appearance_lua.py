from pathlib import Path
import pytest
from lupa.lua51 import LuaRuntime
PLUGIN=Path(__file__).resolve().parents[2]/'lrplugin/lightroom-mcp.lrdevplugin'
@pytest.fixture
def sdk():
 lua=LuaRuntime(unpack_returned_tuples=True)
 for name in ['library_fixture.lua','appearance_fixture.lua']:lua.execute(Path(__file__).with_name(name).read_text())
 module=lua.execute((PLUGIN/'Fine.lua').read_text())
 def call(cmd,**args):return module.handle(lua.table_from({'command':cmd,**args},recursive=True))
 return lua,lua.globals().state,lua.globals().photos,call

def test_read_does_not_switch_module(sdk):
 _,s,p,c=sdk;r=c('get_appearance')['data']
 assert r['treatment']=='color' and r['whiteBalance']=='Custom' and s.module=='library' and s.writes==0
 assert c('get_appearance',expectedPhotoId='b')['code']=='photo_changed'
 assert c('get_appearance',expectedCatalogPath='/wrong')['code']=='catalog_changed'

def test_treatment_native_isolated(sdk):
 _,s,p,c=sdk
 assert c('set_treatment',treatment='grayscale')['data']['treatment']=='grayscale'
 assert p.b.raw.ConvertToGrayscale is False and p.a.raw.Exposure2012==.6
 assert c('set_treatment',treatment='color')['success']
 assert c('set_treatment',treatment='sepia')['code']=='invalid_arguments'
 s.noop=True;assert c('set_treatment',treatment='grayscale')['code']=='readback_failed'

@pytest.mark.parametrize('mode',['As Shot','Auto','Daylight','Cloudy','Shade','Tungsten','Fluorescent','Flash'])
def test_white_balance_modes(sdk,mode):
 _,s,p,c=sdk
 assert c('set_white_balance',mode=mode)['data']['whiteBalance']==mode
 assert p.a.raw.Exposure2012==.6

def test_rendered_white_balance_restrictions_and_failure(sdk):
 _,s,p,c=sdk;p.a.meta.fileFormat='JPG'
 assert c('set_white_balance',mode='Daylight')['code']=='unsupported_mode' and s.writes==0
 assert c('set_white_balance',mode='Auto')['success']
 s.noop=True;assert c('set_white_balance',mode='As Shot')['code']=='readback_failed'
 s.noop=False;s.lockTimeout=True;assert c('set_white_balance',mode='As Shot')['code']=='write_timeout'

def test_profile_candidates_and_only_profile_fields(sdk):
 _,s,p,c=sdk
 rows=c('list_profiles')['data'];assert rows['total']==2 and rows['completeInstalledList'] is False
 e=rows['profiles'][2];assert e['profileId']=='preset:preset1'
 assert e['expectedProfile']['Exposure2012'] is None
 r=c('set_profile',profileId=e['profileId'],expectedProfile=e['expectedProfile']);assert r['success']
 assert p.a.raw.Look.Name=='Adobe Neutral' and p.a.raw.Exposure2012==.6 and p.a.raw.WhiteBalance=='Custom'

def test_profile_source_stale_and_camera_guard(sdk):
 lua,s,p,c=sdk
 e=c('list_profiles',sourcePhotoIds=['b'],includePresets=False)['data']['profiles'][1]
 p.b.raw.Look.Name='changed';assert c('set_profile',profileId=e['profileId'],expectedProfile=e['expectedProfile'])['code']=='profile_changed'
 e=c('list_profiles',sourcePhotoIds=['b'],includePresets=False)['data']['profiles'][1]
 p.b.meta.cameraModel='Other';assert c('set_profile',profileId=e['profileId'],expectedProfile=e['expectedProfile'])['code']=='incompatible_profile'
 assert s.writes==0

def test_profile_noop_and_gate_switch(sdk):
 _,s,p,c=sdk;e=c('list_profiles',query='Neutral')['data']['profiles'][1]
 s.noop=True;assert c('set_profile',profileId=e['profileId'],expectedProfile=e['expectedProfile'])['code']=='readback_failed'
 s.noop=False;s.switchBeforeWrite=True;assert c('set_profile',profileId=e['profileId'],expectedProfile=e['expectedProfile'])['code']=='photo_changed'

def test_empty_look_clears_previous_creative_profile(sdk):
 _,s,p,c=sdk;p.b.raw.Look=None
 e=c('list_profiles',sourcePhotoIds=['b'],includePresets=False)['data']['profiles'][1]
 assert c('set_profile',profileId=e['profileId'],expectedProfile=e['expectedProfile'])['success']
 assert len(p.a.raw.Look)==0

def test_presets_errors_and_pagination(sdk):
 _,s,p,c=sdk
 assert c('list_profiles',limit=1)['data']['hasMore']
 assert c('list_profiles',sourcePhotoIds=['missing'])['code']=='photo_not_found'
 assert c('list_profiles',sourcePhotoIds=['a','a'])['code']=='invalid_arguments'
 s.presetError=True;r=c('list_profiles')['data'];assert r['total']==1 and len(r['presetErrors'])==1

def test_video_and_missing_api(sdk):
 _,s,p,c=sdk;p.a.meta.isVideo=True
 assert c('get_appearance')['code']=='unsupported_photo'
 p.a.meta.isVideo=False;p.a.quickDevelopSetTreatment=None
 assert c('set_treatment',treatment='grayscale')['code']=='unsupported_api'


def test_auto_and_as_shot_do_not_report_stale_effective_values(sdk):
 _,s,p,c=sdk;p.a.raw.WhiteBalance='As Shot';p.a.raw.Temperature=5000
 d=c('get_appearance')['data'];assert d['temperature'] is None and d['storedTemperature']==5000
 assert d['whiteBalanceValuesSource']=='catalog_stored_not_resolved'
 assert c('set_white_balance',mode='Custom')['code']=='invalid_arguments'

def test_profile_infers_treatment_from_look_when_preset_omits_it(sdk):
 lua,s,p,c=sdk;preset=lua.globals().preset;preset.settings.ConvertToGrayscale=None
 preset.settings.Look.Parameters=lua.table_from({'ConvertToGrayscale':True})
 e=c('list_profiles',query='Neutral')['data']['profiles'][1]
 assert e['expectedProfile']['ConvertToGrayscale'] is True
 assert c('set_profile',profileId=e['profileId'],expectedProfile=e['expectedProfile'])['data']['treatment']=='grayscale'
