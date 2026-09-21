import asyncio
import json
import os
import sys
from pathlib import Path
import pytest
import server
from version_tools import VERSION_COMMANDS


def call(tool_name, **args):
    return json.loads(asyncio.run(server.call_tool(tool_name, args))[0].text)


@pytest.mark.parametrize('name,args',[
    ('lr_create_snapshot',{}),('lr_create_snapshot',{'name':'  '}),
    ('lr_create_snapshot',{'name':'x','updateExisting':1}),
    ('lr_apply_snapshot',{'snapshotId':''}),('lr_delete_snapshot',{'snapshotId':'x','expectedPhotoId':' '}),
    ('lr_create_virtual_copies',{'scope':'catalog'}),('lr_select_virtual_copy',{'photoId':123}),
    ('lr_list_presets',{'limit':201}),('lr_list_presets',{'offset':-1}),
    ('lr_apply_preset',{'presetId':'x','amount':float('nan')}),
    ('lr_apply_preset',{'presetId':'x','amount':20.5}),('lr_apply_preset',{'presetId':'x','updateAISettings':'true'}),
    ('lr_list_snapshots',{'command':'reset'}),
])
def test_invalid_requests_stop_before_transport(monkeypatch,name,args):
    monkeypatch.setattr(server,'send_to_lightroom',lambda *a,**kw: pytest.fail('Invalid input reached transport'))
    assert call(name,**args)['code']=='invalid_arguments'


def test_snapshot_and_preset_roundtrip(mock_lr):
    listed=call('lr_list_snapshots')
    photo=listed['data']['photoId']
    snapshot=call('lr_create_snapshot',name='原始版本',expectedPhotoId=photo)['data']['snapshotId']
    assert call('lr_create_snapshot',name='原始版本')['code']=='snapshot_exists'
    preset=call('lr_list_presets',query='暖色')['data']['presets'][0]['presetId']
    assert call('lr_apply_preset',presetId=preset)['success']
    assert call('lr_get_settings')['data']['settings']['Temperature']==7200
    assert call('lr_apply_snapshot',snapshotId=snapshot)['success']
    assert call('lr_get_settings')['data']['settings']['Temperature']==6500
    assert call('lr_list_snapshots')['data']['snapshots'][0]['name']=='原始版本'
    assert call('lr_delete_snapshot',snapshotId=snapshot)['success']
    assert call('lr_list_snapshots')['data']['snapshots']==[]


def test_copy_family_roundtrip(mock_lr):
    result=call('lr_create_virtual_copies',copyName='风格 B')
    copy_id=result['data']['created'][0]['photoId']
    assert len(call('lr_list_virtual_copies')['data']['versions'])==2
    assert call('lr_select_virtual_copy',photoId='mock-photo-1')['success']
    assert call('lr_select_virtual_copy',photoId=copy_id)['success']
    assert call('lr_select_virtual_copy',photoId='unrelated')['code']=='copy_not_found'


def test_new_tools_over_stdio(mock_lr):
    from mcp import ClientSession,StdioServerParameters
    from mcp.client.stdio import stdio_client
    async def run():
        args=StdioServerParameters(command=sys.executable,args=[str(Path(server.__file__))],env=dict(os.environ))
        async with stdio_client(args) as (r,w):
            async with ClientSession(r,w) as session:
                await session.initialize()
                names={t.name for t in (await session.list_tools()).tools}
                assert set(VERSION_COMMANDS)<=names and len(names)==112
                result=json.loads((await session.call_tool('lr_create_snapshot',{'name':'测试快照'})).content[0].text)
                assert result['success'] and result['data']['name']=='测试快照'
    asyncio.run(run())


def test_transport_encodes_chinese_names_as_utf8(tmp_path,monkeypatch):
    monkeypatch.setattr(server,'REQ_FILE',str(tmp_path/'request'))
    monkeypatch.setattr(server,'RES_FILE',str(tmp_path/'response'))
    captured=[]
    original_replace=server.os.replace
    def replace(source,destination):
        captured.append(Path(source).read_text())
        original_replace(source,destination)
    monkeypatch.setattr(server.os,'replace',replace)
    server._exchange({'command':'create_snapshot','name':'修图前'},0)
    assert '修图前' in captured[0] and '\\u' not in captured[0]


def test_updated_snapshot_returns_new_apply_id(mock_lr):
    first=call('lr_create_snapshot',name='更新版本')['data']
    updated=call('lr_create_snapshot',name='更新版本',updateExisting=True)['data']
    assert first['snapshotId'] != updated['snapshotId']
    assert first['globalId'] == updated['globalId']
    assert call('lr_apply_snapshot',snapshotId=first['snapshotId'])['code']=='snapshot_not_found'
    assert call('lr_apply_snapshot',snapshotId=updated['snapshotId'])['success']
