"""Each IPC test owns its files and mock subprocess; never contact live Lightroom."""
import os
from pathlib import Path
import select
import subprocess
import sys

import pytest

SERVER_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SERVER_DIR))


@pytest.fixture
def mock_lr(tmp_path, monkeypatch):
    import server
    req, res = str(tmp_path / "request.json"), str(tmp_path / "response.json")
    monkeypatch.setattr(server, "REQ_FILE", req)
    monkeypatch.setattr(server, "RES_FILE", res)
    monkeypatch.setenv("LR_MCP_REQ", req)
    monkeypatch.setenv("LR_MCP_RES", res)
    proc = subprocess.Popen([sys.executable, str(SERVER_DIR / "mock_lr.py")],
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=os.environ.copy())
    try:
        assert select.select([proc.stdout], [], [], 10)[0], "Mock did not start in time"
        assert b"Mock LR Bridge running" in proc.stdout.readline()
        yield proc
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait()
        proc.stdout.close()
        proc.stderr.close()
