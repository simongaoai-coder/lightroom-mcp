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
