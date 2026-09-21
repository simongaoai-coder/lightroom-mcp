import asyncio,json
import pytest
import server

def call(n,**args):return json.loads(asyncio.run(server.call_tool(n,args))[0].text)
@pytest.mark.parametrize('n,args',[
 ('lr_search_photos',{'filters':{'any':[]}}),('lr_search_photos',{'filters':{'minISO':0}}),
 ('lr_move_keyword',{'keywordId':1,'parentId':-1}),('lr_remove_virtual_copy',{'photoId':'a'}),
 ('lr_toggle_target_collection',{}),('lr_apply_metadata_preset',{}),
 ('lr_update_keyword',{'keywordId':1,'keywordType':'person'}),
])
def test_invalid_not_sent(monkeypatch,n,args):
 monkeypatch.setattr(server,'send_to_lightroom',lambda *a,**k:pytest.fail('unexpected transport'))
 assert call(n,**args)['code']=='invalid_arguments'

def test_recursive_search_and_structures_over_ipc(mock_lr):
 r=call('lr_search_photos',filters={'any':[{'filename':'001'},{'filename':'002'}]});assert r['success'] and r['data']['total']==2
 kid=call('lr_create_keyword',name='test')['data']['keywordId'];assert call('lr_move_keyword',keywordId=kid,parentId=0)['success']
 call('lr_update_photo_keywords',photoIds=['mock-photo-1'],keywordIds=[kid],operation='add')
 assert call('lr_list_keyword_photos',keywordId=kid)['data']['total']==1
 p=call('lr_list_metadata_presets')['data']['presets'][0]
 assert call('lr_apply_metadata_preset',presetId=p['presetId'])['success']

def test_count():assert len(asyncio.run(server.list_tools()))==111
