import asyncio,json
import pytest
import server
from fine_tools import FINE_COMMANDS,MASK_FINE_COMMANDS


def call(tool,**args):return json.loads(asyncio.run(server.call_tool(tool,args))[0].text)


@pytest.mark.parametrize('tool,args',[
 ('lr_set_curve',{'points':[[0,0]]}),('lr_set_curve',{'points':[[0,0],[255,256]]}),
 ('lr_get_curve',{'channel':'cyan'}),('lr_add_point_color',{'swatch':{'SrcHue':1}}),
 ('lr_add_point_color',{'swatch':{'SrcHue':7,'SrcSat':.5,'SrcLum':.5}}),
 ('lr_update_point_color',{'index':1,'changes':{'HueShift':.3}}),
 ('lr_update_point_color',{'index':1,'expectedSwatch':{'SrcHue':1},'changes':{'HueShift':float('nan')}}),
 ('lr_delete_point_color',{'index':0,'expectedSwatch':{'SrcHue':1}}),
 ('lr_combine_mask',{'maskId':'a','operation':'union','maskType':'sky'}),
 ('lr_set_mask_visibility',{'maskId':'a','hidden':'true'}),
 ('lr_set_mask_tool_inverted',{'maskId':'a','inverted':True}),
 ('lr_auto_white_balance',{'command':'reset'}),
])
def test_schema_rejects_before_transport(monkeypatch,tool,args):
 monkeypatch.setattr(server,'send_to_lightroom',lambda *a,**kw:pytest.fail('Unexpected transport'))
 assert call(tool,**args)['code']=='invalid_arguments'


def test_typed_fine_controls_over_ipc(mock_lr):
 assert call('lr_auto_white_balance')['data']['whiteBalance']=='Auto'
 points=[[0,0],[128,140],[255,255]]
 assert call('lr_set_curve',points=points)['success']
 assert call('lr_get_curve')['data']['points']==points
 created=call('lr_add_point_color',swatch={'SrcHue':1,'SrcSat':.5,'SrcLum':.5})['data']
 updated=call('lr_update_point_color',index=1,expectedSwatch=created['swatch'],changes={'HueShift':.2})
 assert updated['success']
 assert call('lr_delete_point_color',index=1,expectedSwatch=created['swatch'])['code']=='swatch_changed'
 assert call('lr_delete_point_color',index=1,expectedSwatch=updated['data']['swatches'][0])['success']


def test_mask_fine_controls_over_ipc(mock_lr):
 assert call('lr_combine_mask',maskId='mask-1',operation='subtract',maskType='sky')['data']['status']=='component_created'
 assert call('lr_set_mask_visibility',maskId='mask-1',hidden=True)['data']['changed']
 assert not call('lr_set_mask_visibility',maskId='mask-1',hidden=True)['data']['changed']
 assert call('lr_invert_mask',maskId='mask-1')['success']
 assert call('lr_duplicate_inverted_mask',maskId='mask-1')['data']['maskId']!='mask-1'


def test_registered_fine_commands():
 names={t.name for t in asyncio.run(server.list_tools())}
 assert set(FINE_COMMANDS)|set(MASK_FINE_COMMANDS)<=names
 assert len(names)==111
