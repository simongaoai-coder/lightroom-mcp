import asyncio,json
import pytest
import server
from history_tools import HISTORY_COMMANDS

def call(n,**a):return json.loads(asyncio.run(server.call_tool(n,a))[0].text)
@pytest.mark.parametrize('n,a',[
 ('lr_paste_settings',{'copyId':'x'}),('lr_undo',{}),('lr_redo',{'historyToken':''}),
 ('lr_copy_settings',{'mode':'all'}),('lr_copy_settings',{'parameters':[]}),
 ('lr_get_history_state',{'historyToken':'caller'}),
])
def test_invalid_not_sent(monkeypatch,n,a):
 monkeypatch.setattr(server,'send_to_lightroom',lambda *a,**k:pytest.fail('unexpected transport'))
 assert call(n,**a)['code']=='invalid_arguments'

def test_history_over_ipc(mock_lr):
 r=call('lr_copy_settings',mode='explicit',parameters=['Exposure']);assert len(r['data']['copyId'])==32
 assert call('lr_paste_settings',copyId=r['data']['copyId'],expectedPhotoId='mock-photo-1')['success']
 s=call('lr_get_history_state')['data'];assert s['canUndo'] and len(s['historyToken'])==32
 assert call('lr_undo',historyToken=s['historyToken'])['success']
 assert call('lr_undo',historyToken=s['historyToken'])['code']=='history_token_invalid'
 s=call('lr_get_history_state')['data'];assert call('lr_redo',historyToken=s['historyToken'])['success']

def test_registration():
 names={t.name for t in asyncio.run(server.list_tools())};assert len(names)==112 and set(HISTORY_COMMANDS)<=names
