import asyncio,json
import pytest
import server


def call(tool,**args):return json.loads(asyncio.run(server.call_tool(tool,args))[0].text)

@pytest.mark.parametrize('tool,args',[
 ('lr_get_settings',{'photoIds':[]}),('lr_get_settings',{'photoIds':['a'],'scope':'current'}),
 ('lr_get_settings',{'parameters':[]}),('lr_get_settings',{'parameters':['Exposure','Exposure']}),
 ('lr_get_settings',{'includeRaw':'true'}),
 ('lr_preflight_settings',{}),('lr_preflight_settings',{'mode':'relative','settings':{'Exposure':1}}),
 ('lr_preflight_settings',{'settings':{'Exposure':1},'deltas':{'Exposure':1}}),
 ('lr_preflight_settings',{'settings':{'Exposure':True}}),
 ('lr_preflight_settings',{'mode':'relative','deltas':{'Exposure':float('nan')}}),
])
def test_invalid_inputs_never_reach_lightroom(monkeypatch,tool,args):
 monkeypatch.setattr(server,'send_to_lightroom',lambda *a,**kw:pytest.fail('unexpected transport'))
 assert call(tool,**args)['code']=='invalid_arguments'


def test_read_preflight_transport_is_read_only(mock_lr):
 ids=['mock-photo-1','mock-photo-2']
 before=call('lr_get_settings',photoIds=ids,parameters=['Exposure'])
 assert [p['settings']['Exposure']for p in before['data']['photos']]==[0,1]
 r=call('lr_preflight_settings',photoIds=ids,mode='relative',deltas={'Exposure':.5})
 assert r['data']['canApply'] and [p['target']['Exposure']for p in r['data']['photos']]==[.5,1.5]
 assert call('lr_get_settings',photoIds=ids,parameters=['Exposure'])['data']==before['data']


def test_registration():
 tools={t.name:t for t in asyncio.run(server.list_tools())}
 assert len(tools)==112 and 'lr_preflight_settings' in tools
 assert tools['lr_get_settings'].inputSchema['properties']['photoIds']['maxItems']==200
