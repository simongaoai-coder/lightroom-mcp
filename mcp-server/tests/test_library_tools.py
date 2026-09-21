import asyncio,json
import pytest
import server
from library_tools import LIBRARY_COMMANDS,DELIVERY_COMMANDS


def call(tool,**args):return json.loads(asyncio.run(server.call_tool(tool,args))[0].text)


@pytest.mark.parametrize('tool,args',[
 ('lr_select_photos',{'photoIds':[]}),('lr_select_photos',{'photoIds':['a','a']}),
 ('lr_set_metadata',{'values':{'rating':6}}),('lr_set_metadata',{'values':{'gps':{'latitude':99,'longitude':0}}}),
 ('lr_set_metadata',{'values':{'arbitrary':1}}),('lr_create_keyword',{'name':' '}),
 ('lr_update_photo_keywords',{'keywordIds':[1],'operation':'delete'}),
 ('lr_create_collection',{'name':'x','kind':'published'}),('lr_delete_collection',{'collectionId':0}),
 ('lr_export_photos',{'destination':'relative'}),('lr_export_photos',{'destination':'/tmp','format':'RAW'}),
 ('lr_export_photos',{'destination':'/tmp','longEdge':0}),('lr_cancel_export',{}),
])
def test_bad_arguments_do_not_reach_lightroom(monkeypatch,tool,args):
 monkeypatch.setattr(server,'send_to_lightroom',lambda *a,**kw:pytest.fail('Invalid transport'))
 assert call(tool,**args)['code']=='invalid_arguments'


def test_library_flow_over_file_ipc(mock_lr):
 rows=call('lr_search_photos',filters={'filename':'DSC_001'})['data']['photos'];pid=rows[0]['photoId']
 assert call('lr_select_photos',photoIds=[pid])['success']
 assert call('lr_set_metadata',photoIds=[pid],values={'rating':5,'title':'交付照片'})['success']
 assert call('lr_get_metadata',photoIds=[pid])['data']['photos'][0]['metadata']['title']=='交付照片'
 kid=call('lr_create_keyword',name='MCP验收')['data']['keywordId']
 assert call('lr_update_photo_keywords',photoIds=[pid],keywordIds=[kid],operation='add')['success']
 col=call('lr_create_collection',name='交付测试')['data']['collectionId']
 assert call('lr_update_collection_photos',collectionId=col,photoIds=[pid],operation='add')['success']
 assert call('lr_search_photos',collectionId=col)['data']['total']==1
 assert call('lr_delete_collection',collectionId=col)['code']=='collection_not_empty'
 assert call('lr_update_collection_photos',collectionId=col,photoIds=[pid],operation='remove')['success']
 assert call('lr_delete_collection',collectionId=col)['success']


def test_export_job_id_and_results_over_transport(mock_lr,tmp_path):
 result=call('lr_export_photos',destination=str(tmp_path),photoIds=['mock-photo-1'])
 assert result['success'] and len(result['jobId'])==32
 status=call('lr_get_export_status',jobId=result['jobId'])['data']
 assert status['status']=='completed' and status['completed']==1
 assert status['results'][0]['path'].startswith(str(tmp_path))


def test_library_and_delivery_tools_registered():
 tools={t.name for t in asyncio.run(server.list_tools())}
 assert set(LIBRARY_COMMANDS)|set(DELIVERY_COMMANDS)<=tools
 assert len(tools)==111


@pytest.mark.parametrize('tool,args',[
 ('lr_get_metadata',{'fieldGroup':'capture','fields':['flash']}),
 ('lr_get_metadata',{'fieldGroup':'unknown'}),
 ('lr_get_metadata',{'fields':['undocumentedMakerNote']}),
 ('lr_set_metadata',{'values':{'isoSpeedRating':800}}),
 ('lr_set_metadata',{'clearFields':['shutterSpeed']}),
])
def test_capture_validation_before_ipc(monkeypatch,tool,args):
 monkeypatch.setattr(server,'send_to_lightroom',lambda *a,**kw:pytest.fail('Invalid transport'))
 assert call(tool,**args)['code']=='invalid_arguments'


def test_capture_metadata_over_file_ipc(mock_lr):
 rows=call('lr_get_metadata',photoIds=['mock-photo-1','mock-photo-2'],fieldGroup='capture')['data']['photos']
 assert len(rows)==2
 for row in rows:
  assert row['metadata']['shutterSpeed']==pytest.approx(1/125)
  assert row['metadata']['isoSpeedRating']==400
  assert row['metadata']['flash'] is False and row['metadata']['exposureBias']==0
  assert 'cameraSerialNumber' in row['missingFields']
 assert call('lr_get_metadata',fields=['flash'])['data']['photos'][0]['metadata']=={'flash':False}
 assert 'shutterSpeed' not in call('lr_get_metadata')['data']['photos'][0]['metadata']
