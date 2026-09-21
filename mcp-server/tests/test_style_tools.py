import asyncio
import json
import pytest
import server
from style_tools import TARGET_TOOLS


def call(tool,**args):return json.loads(asyncio.run(server.call_tool(tool,args))[0].text)


@pytest.mark.parametrize('name,args',[
    ('lr_save_style',{'name':'empty'}),
    ('lr_save_style',{'name':'x','parameters':[]}),
    ('lr_save_style',{'name':'x','groups':['profile']}),
    ('lr_save_style',{'name':'x','groups':['grain','grain']}),
    ('lr_save_style',{'name':'\n','parameters':['Exposure']}),
    ('lr_apply_settings',{'settings':{'Exposure':1},'photoIds':['a'],'scope':'selected'}),
    ('lr_apply_preset',{'presetId':'x','photoIds':[]}),
    ('lr_set_treatment',{'treatment':'grayscale','photoIds':['a','a']}),
    ('lr_rotate_photo',{'direction':'left','photoIds':['a']*201}),
])
def test_schema_rejects_before_ipc(monkeypatch,name,args):
    monkeypatch.setattr(server,'send_to_lightroom',lambda *a,**kw:pytest.fail('unexpected IPC'))
    assert call(name,**args)['code']=='invalid_arguments'


def test_save_list_apply_round_trip(mock_lr):
    r=call('lr_save_style',name='旅行风格',groups=['grain'])
    assert r['success']
    entries=call('lr_list_presets',query='旅行风格')['data']['presets']
    assert len(entries)==1 and entries[0]['presetId']==r['data']['presetId'] and entries[0]['pluginOwned']
    r=call('lr_apply_preset',presetId=r['data']['presetId'],photoIds=['mock-photo-1','mock-photo-2'])
    assert r['success'] and r['applied']==2
    assert call('lr_save_style',name='旅行风格',groups=['grain'])['code']=='style_exists'


@pytest.mark.parametrize('name,args',[
    ('lr_apply_settings',{'settings':{'Exposure':.2}}),
    ('lr_batch_apply_settings',{'settings':{'Contrast':10}}),
    ('lr_apply_preset',{'presetId':'preset-warm'}),
    ('lr_set_treatment',{'treatment':'grayscale'}),
    ('lr_set_white_balance',{'mode':'Auto'}),
    ('lr_rotate_photo',{'direction':'right'}),
])
def test_explicit_target_transport(mock_lr,name,args):
    r=call(name,photoIds=['mock-photo-2'],expectedCatalogPath='/mock/catalog.lrcat',**args)
    assert r['success'] and r['data']['results'][0]['photoId']=='mock-photo-2'


def test_targets_schema_defaults():
    tools={t.name:t for t in asyncio.run(server.list_tools())}
    assert len(tools)==112
    for name in TARGET_TOOLS:
        props=tools[name].inputSchema['properties']
        assert props['photoIds']['maxItems']==200
        assert props['scope']['default']==('selected' if name=='lr_batch_apply_settings' else 'current')
