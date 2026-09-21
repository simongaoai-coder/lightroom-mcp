import asyncio,json
import pytest
import server
from navigation_tools import GEOMETRY_COMMANDS,NAVIGATION_COMMANDS

def call(n,**args):return json.loads(asyncio.run(server.call_tool(n,args))[0].text)
@pytest.mark.parametrize('n,args',[
 ('lr_rotate_photo',{'direction':'up'}),('lr_set_crop_aspect',{'width':0,'height':1}),
 ('lr_reset_adjustments',{'group':'all'}),('lr_show_view',{'view':'unknown'}),
 ('lr_navigate_photos',{'action':'delete'}),('lr_set_sources',{'folderPaths':[]}),
 ('lr_set_view_filter',{'changes':{'arbitrary':True}}),('lr_list_folders',{'limit':201}),
])
def test_schema_rejections(monkeypatch,n,args):
 monkeypatch.setattr(server,'send_to_lightroom',lambda *a,**k:pytest.fail('unexpected transport'))
 assert call(n,**args)['code']=='invalid_arguments'

def test_native_routes_over_ipc(mock_lr):
 assert call('lr_rotate_photo',direction='right')['data']['orientation']=='BC'
 assert call('lr_set_crop_aspect',width=4,height=5)['data']['effectiveRatio']==.8
 assert call('lr_reset_adjustments',group='crop')['success']
 assert call('lr_get_geometry')['success']
 assert call('lr_list_folders')['data']['total']==1
 assert call('lr_list_folder_photos',folderPath='/photos')['success']
 assert call('lr_set_sources',folderPaths=['/photos'])['success']
 assert call('lr_show_view',view='grid')['success']
 assert call('lr_navigate_photos',action='next')['data']['activePhotoId']=='mock-photo-2'
 assert call('lr_set_view_filter',changes={'minRating':4})['success']
 assert call('lr_get_navigation')['data']['viewFilter']['minRating']==4

def test_tool_registration():
 names={t.name for t in asyncio.run(server.list_tools())};assert len(names)==110 and set(GEOMETRY_COMMANDS)|set(NAVIGATION_COMMANDS)<=names
