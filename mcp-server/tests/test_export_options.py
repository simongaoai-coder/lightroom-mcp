import asyncio,json
from pathlib import Path
import pytest
import server


def call(tool,**args):return json.loads(asyncio.run(server.call_tool(tool,args))[0].text)


@pytest.mark.parametrize('args',[
 {'longEdge':100,'shortEdge':50},{'width':1200},{'height':800},
 {'longEdge':100,'width':100,'height':100},{'shortEdge':500,'megapixels':2},
 {'megapixels':float('nan')},{'megapixels':0},{'maxFileSizeKB':0},
 {'maxFileSizeKB':100,'quality':90},{'maxFileSizeKB':100,'format':'TIFF'},
 {'format':'TIFF','quality':90},{'bitDepth':16},
 {'naming':{'mode':'custom_sequence'}},{'naming':{'mode':'original','sequenceDigits':3}},
 {'naming':{'customText':'x'}},{'naming':{'mode':'custom_sequence','customText':'../x'}},
 {'naming':{'mode':'custom_sequence','customText':'{{image_name}}'}},
 {'naming':{'mode':'custom_sequence','customText':'x.'}},
 {'naming':{'mode':'custom_sequence','customText':'x\n'}},
 {'naming':{'mode':'custom_sequence','customText':'旅'*67}},
 {'naming':{'mode':'custom_sequence','customText':'\ud800'}},
 {'naming':{'extensionCase':'invalid'}},{'naming':{'sequenceStart':0}},
])
def test_bad_export_options_do_not_reach_lightroom(monkeypatch,args):
 monkeypatch.setattr(server,'send_to_lightroom',lambda *a,**kw:pytest.fail('Invalid IPC'))
 assert call('lr_export_photos',destination='/tmp',**args)['code']=='invalid_arguments'


def test_options_and_names_over_file_ipc(mock_lr,tmp_path):
 r=call('lr_export_photos',destination=str(tmp_path),photoIds=['mock-photo-2','mock-photo-1'],
        width=1200,height=800,maxFileSizeKB=300,
        naming={'mode':'custom_sequence','customText':'交付','sequenceStart':42,'sequenceDigits':3,'extensionCase':'uppercase'})
 assert r['success']
 status=call('lr_get_export_status',jobId=r['jobId'])['data']
 assert status['resize']=={'mode':'wh','width':1200,'height':800}
 assert status['maxFileSizeKB']==300 and 'quality' not in status
 assert [Path(x['path']).name for x in status['results']]==['交付-042.JPG','交付-043.JPG']
 assert all(x['sizeLimitMet'] for x in status['results'])


def test_tiff_dimensions_and_original_names(mock_lr,tmp_path):
 r=call('lr_export_photos',destination=str(tmp_path),format='TIFF',bitDepth=16,
        shortEdge=1000,naming={'mode':'original'})
 assert r['success']
 status=call('lr_get_export_status',jobId=r['jobId'])['data']
 assert status['resize']=={'mode':'shortEdge','value':1000}
 assert Path(status['results'][0]['path']).name=='DSC_001.tif'
