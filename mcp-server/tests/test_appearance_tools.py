import asyncio,json
import pytest
import server
from appearance_tools import APPEARANCE_COMMANDS

def call(name,**args):return json.loads(asyncio.run(server.call_tool(name,args))[0].text)
@pytest.mark.parametrize('name,args',[
 ('lr_set_treatment',{'treatment':'sepia'}),('lr_set_white_balance',{'mode':'Sunny'}),
 ('lr_set_profile',{'profileId':'arbitrary'}),('lr_set_profile',{'profileId':'x','expectedProfile':{}}),
 ('lr_list_profiles',{'sourcePhotoIds':[]}),('lr_list_profiles',{'limit':201}),
 ('lr_get_appearance',{'write':True}),
])
def test_invalid_not_sent(monkeypatch,name,args):
 monkeypatch.setattr(server,'send_to_lightroom',lambda *a,**k:pytest.fail('unexpected transport'))
 assert call(name,**args)['code']=='invalid_arguments'

def test_transport(mock_lr):
 assert call('lr_set_treatment',treatment='grayscale')['data']['treatment']=='grayscale'
 assert call('lr_set_white_balance',mode='As Shot')['data']['whiteBalance']=='As Shot'
 e=call('lr_list_profiles')['data']['profiles'][0]
 assert call('lr_set_profile',profileId=e['profileId'],expectedProfile=e['expectedProfile'])['success']
 assert call('lr_get_appearance')['success']

def test_registration():
 names={t.name for t in asyncio.run(server.list_tools())};assert len(names)==77 and set(APPEARANCE_COMMANDS)<=names
