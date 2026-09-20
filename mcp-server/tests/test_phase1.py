import asyncio
import json
import threading
import time
from pathlib import Path
import pytest
import server


def test_ping_reports_actual_process_tools(mock_lr):
    result = json.loads(asyncio.run(server.call_tool('lr_ping', {}))[0].text)
    assert result['compatible']
    assert result['server']['toolCount'] == 55
    assert 'lr_list_masks' in result['server']['tools']


@pytest.mark.parametrize('settings', [{}, {'Exposure': True}, {'Exposure': float('nan')},
                                     {'Exposure': float('inf')}, {'Exposure': '1'},
                                     {'Exposure': 1, 'exposure': 2}])
def test_bad_input_never_reaches_lightroom(monkeypatch, settings):
    def unexpected(*a, **kw):
        pytest.fail('Invalid input reached Lightroom')
    monkeypatch.setattr(server, 'send_to_lightroom', unexpected)
    for tool in ['lr_apply_settings', 'lr_batch_apply_settings']:
        result = json.loads(asyncio.run(server.call_tool(tool, {'settings': settings}))[0].text)
        assert result['code'] == 'invalid_arguments'


def test_old_plugin_blocks_writes(tmp_path, monkeypatch):
    monkeypatch.setattr(server, 'REQ_FILE', str(tmp_path / 'req'))
    calls = []
    def exchange(command, timeout):
        calls.append(command['command'])
        return {'success': True, 'version': '1.1.4'}
    monkeypatch.setattr(server, '_exchange', exchange)
    result = server.send_to_lightroom({'command': 'apply_settings', 'settings': {'Exposure': 1}})
    assert result['code'] == 'version_mismatch' and calls == ['ping']


def test_correlated_response_ignores_late_previous_result(tmp_path, monkeypatch):
    req, res = tmp_path / 'req', tmp_path / 'res'
    monkeypatch.setattr(server, 'REQ_FILE', str(req))
    monkeypatch.setattr(server, 'RES_FILE', str(res))
    def respond():
        deadline = time.monotonic()+2
        while not req.exists() and time.monotonic()<deadline:
            time.sleep(.005)
        payload=json.loads(req.read_text())
        res.write_text(json.dumps({'success':True,'requestId':'stale'}))
        while res.exists() and time.monotonic()<deadline:
            time.sleep(.005)
        res.write_text(json.dumps({'success':True,'requestId':payload['requestId'],'correct':True}))
    thread=threading.Thread(target=respond)
    thread.start()
    try:
        assert server._exchange({'command':'get_settings'},2)['correct']
    finally:
        thread.join(3)


def test_timeout_states_uncertain_outcome(tmp_path, monkeypatch):
    monkeypatch.setattr(server, 'REQ_FILE', str(tmp_path / 'req'))
    monkeypatch.setattr(server, 'RES_FILE', str(tmp_path / 'res'))
    result=server._exchange({'command':'apply_settings'},.01)
    assert result['code']=='timeout' and result['outcomeUnknown']
    assert not Path(server.REQ_FILE).exists()
