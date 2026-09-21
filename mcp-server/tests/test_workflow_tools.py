import asyncio
import json
import pytest
import server
from workflow_tools import PREVIEW_COMMANDS, RELATIVE_COMMANDS


def call(tool, **args):
    return json.loads(asyncio.run(server.call_tool(tool,args))[0].text)


@pytest.mark.parametrize('tool,args', [
    ('lr_batch_adjust_relative', {'deltas':{}}),
    ('lr_batch_adjust_relative', {'deltas':{'Exposure':True}}),
    ('lr_batch_adjust_relative', {'deltas':{'Exposure':float('inf')}}),
    ('lr_batch_adjust_relative', {'deltas':{'LensProfileEnable':1}}),
    ('lr_batch_adjust_relative', {'deltas':{'Exposure':1},'photoIds':['a'],'scope':'selected'}),
    ('lr_build_smart_previews', {'photoIds':[]}),
    ('lr_build_smart_previews', {'photoIds':['a','a']}),
    ('lr_build_smart_previews', {'scope':'all'}),
    ('lr_build_smart_previews', {'jobId':'a'*32}),
    ('lr_delete_smart_previews', {'allowOffline':'yes'}),
    ('lr_get_smart_preview_job', {'jobId':'bad'}),
    ('lr_cancel_smart_preview_job', {}),
])
def test_invalid_arguments_never_reach_ipc(monkeypatch,tool,args):
    monkeypatch.setattr(server,'send_to_lightroom',lambda *a,**kw:pytest.fail('Invalid IPC'))
    assert call(tool,**args)['code']=='invalid_arguments'


def test_new_tools_registered_and_color_names_discoverable():
    tools={t.name:t for t in asyncio.run(server.list_tools())}
    assert len(tools)==110 and set(PREVIEW_COMMANDS)|set(RELATIVE_COMMANDS)<=tools.keys()
    assert 'SplitToningHighlightHue' in tools['lr_apply_settings'].description


def test_preview_and_relative_file_ipc(mock_lr):
    ids=['mock-photo-1','mock-photo-2']
    assert not call('lr_get_smart_previews')['data']['photos'][0]['hasSmartPreview']
    r=call('lr_build_smart_previews',photoIds=ids)
    assert r['success'] and len(r['jobId'])==32
    assert call('lr_get_smart_preview_job',jobId=r['jobId'])['data']['completed']==2
    assert call('lr_get_smart_previews')['data']['photos'][0]['hasSmartPreview']
    assert call('lr_delete_smart_previews')['success']
    assert not call('lr_get_smart_previews')['data']['photos'][0]['hasSmartPreview']
    r=call('lr_batch_adjust_relative',photoIds=ids,deltas={'Exposure':.5})
    assert r['success'] and r['applied']==2
    assert [row['after']['Exposure'] for row in r['data']['results']]==[.5,1.5]


def test_uncertain_job_start_returns_reconciliation_id(monkeypatch):
    requests=[]
    def timeout(payload,**kwargs):
        requests.append(payload)
        return {'success':False,'code':'timeout','outcomeUnknown':True}
    monkeypatch.setattr(server,'send_to_lightroom',timeout)
    result=call('lr_build_smart_previews')
    assert result['jobId']==requests[0]['jobId'] and len(requests)==1
    result=call('lr_batch_adjust_relative',deltas={'Exposure':.5})
    assert result['outcomeUnknown'] and len(requests)==2
