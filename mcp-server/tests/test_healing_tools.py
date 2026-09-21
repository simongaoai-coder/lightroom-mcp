import asyncio,json
import pytest
import server
from healing_tools import HEALING_COMMANDS

def call(name,**args):return json.loads(asyncio.run(server.call_tool(name,args))[0].text)

@pytest.mark.parametrize('name,args',[
 ('lr_select_spot',{'spotIndex':1}),('lr_select_spot',{'spotIndex':-1,'expectedSpot':{'id':'a'}}),
 ('lr_update_spot',{'spotIndex':1,'expectedSpot':{'id':'a'},'changes':{'Opacity':float('nan')}}),
 ('lr_set_remove_preferences',{'changes':{'brushSize':101}}),('lr_set_remove_preferences',{'changes':{'unknown':1}}),
 ('lr_reset_healing',{}),('lr_cycle_spot_variation',{'spotIndex':1,'expectedSpot':{'id':'a'},'direction':'all'}),
 ('lr_update_ai_settings',{'photoIds':[]}),('lr_get_ai_update_status',{}),
])
def test_invalid_arguments_never_sent(monkeypatch,name,args):
 monkeypatch.setattr(server,'send_to_lightroom',lambda *a,**kw:pytest.fail('unexpected transport'))
 assert call(name,**args)['code']=='invalid_arguments'

def test_spots_over_ipc(mock_lr):
 r=call('lr_list_spots')['data'];target={'spotIndex':r['spots'][0]['spotIndex'],'expectedSpot':r['spots'][0]['spot']}
 assert call('lr_select_spot',**target)['success']
 assert call('lr_update_spot',**target,changes={'Opacity':.8})['data']['params']['Opacity']==.8
 assert call('lr_cycle_spot_variation',**target,direction='next')['code']=='not_generative_spot'
 assert call('lr_delete_spot',**target)['data']['remainingCount']==0
 assert not call('lr_get_selected_spot')['data']['hasSelection']

def test_ai_jobs_over_ipc(mock_lr):
 r=call('lr_update_ai_settings',photoIds=['mock-photo-1']);assert len(r['jobId'])==32
 assert call('lr_get_ai_update_status',jobId=r['jobId'])['data']['completed']==1
 assert call('lr_cleanup_empty_masks',photoIds=['mock-photo-1'])['success']

def test_uncertain_start_keeps_id(monkeypatch):
 sent=[]
 def exchange(payload,**kw):sent.append(payload);return {'success':False,'code':'timeout','outcomeUnknown':True}
 monkeypatch.setattr(server,'send_to_lightroom',exchange)
 r=call('lr_update_ai_settings');assert r['jobId']==sent[0]['jobId'] and r['outcomeUnknown']

def test_registration():
 tools=asyncio.run(server.list_tools());assert len(tools)==111 and set(HEALING_COMMANDS)<={t.name for t in tools}
