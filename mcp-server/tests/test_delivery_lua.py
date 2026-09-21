from pathlib import Path
import pytest
from lupa.lua51 import LuaRuntime
PLUGIN=Path(__file__).resolve().parents[2]/'lrplugin/lightroom-mcp.lrdevplugin'

@pytest.fixture
def sdk(tmp_path):
 lua=LuaRuntime(unpack_returned_tuples=True)
 lua.execute(Path(__file__).with_name('library_fixture.lua').read_text())
 lua.globals().py_exists=lambda p:'directory' if Path(p).is_dir() else 'file' if Path(p).is_file() else None
 lua.globals().py_mkdir=lambda p:Path(p).mkdir(parents=True,exist_ok=True)
 lua.globals().py_resolve=lambda p:str(Path(p).resolve())
 lua.execute(Path(__file__).with_name('delivery_fixture.lua').read_text())
 lua.globals().libraryModule=lua.execute((PLUGIN/'Library.lua').read_text())
 lua.execute('function require(name)assert(name=="Library");return libraryModule end')
 module=lua.execute((PLUGIN/'Delivery.lua').read_text())
 def call(cmd,**args):return module.handle(lua.table_from({'command':cmd,**args},recursive=True))
 return lua,lua.globals().state,call,tmp_path


def test_export_runs_async_and_verifies_files(sdk):
 lua,state,call,path=sdk
 job='a'*32
 r=call('export_photos',jobId=job,destination=str(path),photoIds=['a','b'],longEdge=1200,quality=85)
 assert r['success'] and r['data']['status']=='queued'
 assert call('get_export_status',jobId=job)['data']['completed']==0
 lua.globals().runAsync()
 r=call('get_export_status',jobId=job)['data']
 assert r['status']=='completed' and r['completed']==2 and r['failed']==0
 assert Path(r['results'][1]['path']).is_file()
 assert state.lastExportSettings.LR_jpeg_quality==.85
 assert state.lastExportSettings.LR_size_maxHeight==1200
 assert state.lastExportSettings.LR_collisionHandling=='rename'
 assert not state.lastExportSettings.LR_reimportExportedPhoto


def test_cancel_between_photos_preserves_completed_file(sdk):
 lua,state,call,path=sdk
 state.cancelAfterFirst=True
 job='b'*32
 assert call('export_photos',jobId=job,destination=str(path),photoIds=['a','b'])['success']
 lua.globals().runAsync()
 r=call('get_export_status',jobId=job)['data']
 assert r['status']=='cancelled' and r['completed']==1 and r['notStarted']==1
 assert Path(r['results'][1]['path']).is_file()


def test_cancel_queued_job_renders_nothing(sdk):
 lua,_,call,path=sdk
 job='c'*32
 call('export_photos',jobId=job,destination=str(path))
 assert call('cancel_export',jobId=job)['data']['cancelRequested']
 lua.globals().runAsync()
 r=call('get_export_status',jobId=job)['data']
 assert r['status']=='cancelled' and r['completed']==0


def test_render_failure_and_empty_output_are_reported(sdk):
 lua,state,call,path=sdk
 state.failRender='b'
 job='d'*32;call('export_photos',jobId=job,destination=str(path),photoIds=['a','b'],format='TIFF',bitDepth=16)
 lua.globals().runAsync()
 r=call('get_export_status',jobId=job)['data']
 assert r['status']=='failed' and r['completed']==1 and r['failed']==1
 assert r['results'][2]['code']=='render_failed'
 state.emptyRender=True
 job='e'*32;call('export_photos',jobId=job,destination=str(path))
 lua.globals().runAsync()
 assert call('get_export_status',jobId=job)['data']['results'][1]['code']=='empty_output'


def test_export_preflight_and_busy_guard(sdk):
 lua,_,call,path=sdk
 lua.globals().photos.a.offline=True
 assert call('export_photos',jobId='f'*32,destination=str(path))['code']=='photo_unavailable'
 assert not list(path.iterdir())
 lua.globals().photos.a.offline=False
 call('export_photos',jobId='f'*32,destination=str(path))
 assert call('export_photos',jobId='0'*32,destination=str(path))['code']=='export_busy'
 assert call('get_export_status',jobId='unknown')['code']=='job_not_found'


@pytest.mark.parametrize('args',[
 {'destination':'relative'}, {'format':'ORIGINAL'},{'quality':101},
 {'format':'TIFF','quality':90},{'format':'JPEG','bitDepth':8}, {'longEdge':0},
])
def test_invalid_export_does_not_start(sdk,args):
 _,state,call,path=sdk
 req={'jobId':'1'*32,'destination':str(path),**args}
 assert not call('export_photos',**req)['success']
 assert len(state['async'])==0 and not list(path.iterdir())


def test_equivalent_parent_paths_are_canonicalized(sdk):
 lua,state,call,path=sdk
 state.parentTrailingSlash=True
 job='2'*32
 assert call('export_photos',jobId=job,destination=str(path))['success']
 lua.globals().runAsync()
 assert call('get_export_status',jobId=job)['data']['status']=='completed'


@pytest.mark.parametrize('args,mode,height,width,mp',[
 ({},'longEdge',0,0,None),
 ({'longEdge':1400},'longEdge',1400,1400,None),
 ({'shortEdge':800},'shortEdge',800,800,None),
 ({'width':1200,'height':900},'wh',900,1200,None),
 ({'megapixels':2.5},'megapixels',0,0,2.5),
])
def test_native_resize_settings_and_effective_status(sdk,args,mode,height,width,mp):
 lua,s,c,path=sdk
 r=c('export_photos',jobId='3'*32,destination=str(path),doNotEnlarge=False,**args)
 assert r['success']
 lua.globals().runAsync();native=s.lastExportSettings
 assert native.LR_size_resizeType==mode and native.LR_size_maxHeight==height and native.LR_size_maxWidth==width
 assert native.LR_size_megapixels==mp and native.LR_size_units=='pixels' and native.LR_size_doNotEnlarge is False
 assert native.LR_size_doConstrain==bool(args)
 status=c('get_export_status',jobId='3'*32)['data']
 assert status['resize']['mode']==(mode if args else 'none')


@pytest.mark.parametrize('args',[
 {'longEdge':1000,'shortEdge':500}, {'width':1200}, {'height':900},
 {'width':1200,'height':900,'megapixels':2}, {'shortEdge':0}, {'megapixels':0},
 {'maxFileSizeKB':0}, {'maxFileSizeKB':100,'quality':90}, {'format':'TIFF','maxFileSizeKB':100},
 {'naming':False}, {'naming':{'mode':'unknown'}}, {'naming':{'mode':'custom_sequence'}},
 {'naming':{'customText':'Test'}}, {'naming':{'mode':'original','sequenceStart':3}},
 {'naming':{'mode':'original','sequenceDigits':2}}, {'naming':{'sequenceDigits':6}},
 {'naming':{'extensionCase':'upper'}}, {'naming':{'unexpected':1}},
])
def test_invalid_extended_options_fail_before_folder_or_job(sdk,args):
 _,s,c,path=sdk
 r=c('export_photos',jobId='4'*32,destination=str(path),**args)
 assert r['code']=='invalid_arguments' and not list(path.iterdir()) and len(s['async'])==0


@pytest.mark.parametrize('text',['../escape','a/b','a\\b','name:stream','x\n','x\x00','{{image_name}}','x.','x ',' ','x'*201])
def test_custom_name_is_literal_safe_leaf(sdk,text):
 _,s,c,path=sdk
 r=c('export_photos',jobId='5'*32,destination=str(path),naming={'mode':'custom_sequence','customText':text})
 assert r['code']=='invalid_arguments' and not list(path.iterdir())


def test_default_names_and_custom_sequence_continue_across_sessions(sdk):
 lua,s,c,path=sdk
 c('export_photos',jobId='6'*32,destination=str(path),photoIds=['a','b'])
 lua.globals().runAsync()
 rows=c('get_export_status',jobId='6'*32)['data']['results']
 assert [Path(rows[i]['path']).name for i in [1,2]]==['a-0001.jpg','b-0002.jpg']
 r=c('export_photos',jobId='7'*32,destination=str(path),photoIds=['b','a'],
     naming={'mode':'custom_sequence','customText':'旅行精选','sequenceStart':9,'sequenceDigits':2,'extensionCase':'uppercase'})
 assert r['success']
 # Mutating the returned status cannot change the saved job settings.
 r['data']['naming']['sequenceStart']=100
 lua.globals().runAsync()
 rows=c('get_export_status',jobId='7'*32)['data']['results']
 assert [Path(rows[i]['path']).name for i in [1,2]]==['旅行精选-09.JPG','旅行精选-10.JPG']
 assert s.exportSettingsHistory[3].LR_initialSequenceNumber==9
 assert s.exportSettingsHistory[4].LR_initialSequenceNumber==10
 assert s.lastExportSettings.LR_tokens=='{{custom_token}}-{{naming_sequenceNumber_2Digits}}'


def test_original_names_keep_collision_rename(sdk):
 lua,s,c,path=sdk;s.sameBasename=True
 c('export_photos',jobId='8'*32,destination=str(path),photoIds=['a','b'],naming={'mode':'original'})
 lua.globals().runAsync();job=c('get_export_status',jobId='8'*32)['data']
 assert job['completed']==2 and job['results'][1]['path']!=job['results'][2]['path']
 assert s.lastExportSettings.LR_renamingTokensOn is False and s.lastExportSettings.LR_tokens is None
 assert all(Path(job['results'][i]['path']).is_file() for i in [1,2])


@pytest.mark.parametrize('size,passed',[(1024,True),(1025,False)])
def test_actual_jpeg_byte_limit_enforced_and_oversize_retained(sdk,size,passed):
 lua,s,c,path=sdk;s.renderBytes=size
 c('export_photos',jobId='9'*32,destination=str(path),maxFileSizeKB=1)
 lua.globals().runAsync();job=c('get_export_status',jobId='9'*32)['data'];row=job['results'][1]
 assert row['bytes']==size and row['maxBytes']==1024 and row['sizeLimitMet']==passed
 assert row['success']==passed and Path(row['path']).stat().st_size==size
 assert job['quality'] is None and job['maxFileSizeKB']==1
 assert s.lastExportSettings.LR_jpeg_useLimitSize and s.lastExportSettings.LR_jpeg_limitSize==1
 if not passed:assert row['code']=='file_size_limit_exceeded' and job['status']=='failed'


def test_single_digit_token_and_sequence_overflow(sdk):
 lua,s,c,path=sdk
 r=c('export_photos',jobId='a'*32,destination=str(path),photoIds=['a','b'],naming={'sequenceStart':999999999})
 assert r['code']=='invalid_arguments' and not list(path.iterdir())
 c('export_photos',jobId='b'*32,destination=str(path),naming={'sequenceDigits':1})
 lua.globals().runAsync()
 assert s.lastExportSettings.LR_tokens=='{{image_name}}-{{naming_sequenceNumber_1Digit}}'


def test_utf8_name_byte_limit_before_creating_folder(sdk):
 lua,s,c,path=sdk
 assert c('export_photos',jobId='c'*32,destination=str(path),naming={'mode':'custom_sequence','customText':'旅'*67})['code']=='invalid_arguments'
 assert not list(path.iterdir())
 assert c('export_photos',jobId='d'*32,destination=str(path),naming={'mode':'custom_sequence','customText':'旅'*60})['success']
 lua.globals().runAsync()
 assert c('get_export_status',jobId='d'*32)['data']['status']=='completed'
