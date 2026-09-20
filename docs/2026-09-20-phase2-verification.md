# Phase 2 verification — 2026-09-20

## Final deployment

Main plugin / Python server / Versions module: **2.1.1**, protocol 2.
Develop remains 2.0.0 and Masking remains 1.1.4. Nine new tools bring the total to 26.
The original 2.0.0 plugin was backed up before deployment to
`/tmp/lightroom-mcp-before-phase2-20260920-115237`.

All deployed Lua files match the working tree in
`~/Library/Application Support/Adobe/Lightroom/Modules/lightroom-mcp.lrdevplugin`.
A fresh real MCP stdio session initialized, listed 26 tools and reported
`compatible: true` with version 2.1.1. Existing client processes may need to reconnect
before using the new tool schemas. The test machine runs Lightroom Classic 15.2.

## Automated validation

**154 tests passed**, including production Lua 5.1 snapshot/copy/preset behavior,
distinct native snapshot apply/delete identifiers, replacement IDs, duplicate names,
stale-photo protection, missing AI-update APIs, write timeouts, silent no-ops,
partial preset batches, Unicode JSON dispatch, invalid schemas, isolated IPC and
MCP stdio. Existing phase-1 and masking tests remain included.

Command: `mcp-server/venv/bin/python -m pytest mcp-server/tests -q`.
`git diff --check` passed.

## Live acceptance completed

The user confirmed that the open photos are backup copies suitable for testing.
Tests used `_DSC1049.ARW` and one newly created virtual copy of that photo.

| Check | Result |
| --- | --- |
| API availability | Snapshot, virtual-copy and preset APIs reported by runtime capabilities |
| Preset enumeration | 381 SDK-visible presets with folder names, UUIDs and sorted pagination |
| Chinese copy name | Created `MCP 第二阶段验证`, returned its new UUID/master UUID and selected it |
| Copy-family navigation | Listed master and copy; switched between them by explicit UUID |
| Snapshot creation | Saved `MCP 测试前 2026-09-20` and returned both native identifiers |
| Duplicate snapshot name | Rejected as snapshot_exists without overwriting |
| Single preset | Applied Creative > Warm Contrast to the copy; observed tone, color, white-balance and process-version changes |
| Snapshot restore | Restored the saved state; observed SDK settings matched the baseline |
| Snapshot replacement | Updated another same-name snapshot at Exposure 0.81; its apply ID changed, global ID stayed the same |
| Stale snapshot ID | Old apply ID rejected as snapshot_not_found; new returned ID restored Exposure 0.81 correctly |
| Two-photo preset batch | Creative > Cool Light applied to both selected master and copy with applied=2 and per-photo changed keys |
| Restore after batch | Restored each photo's saved state; all normalized settings matched the original baseline |
| Snapshot deletion | Deleted all three test snapshots and verified empty lists on both photos |
| Final master comparison | Entire raw SDK develop table equaled its recorded pre-test baseline |
| Final stdio guards | Invalid snapshot ID and wrong expected photo UUID rejected |
| Existing regressions | Mask enumeration succeeded; preview returned MCP ImageContent |

The restored virtual copy `MCP 第二阶段验证` remains for inspection. The master is
reselected. No duplicate image file was created. Test-generated snapshot entries
were removed; Lightroom history entries from validation remain. Restoring develop
settings does not imply the catalog database is byte-identical.

## Live finding: snapshot IDs change on update

Lightroom changes `snapshotID` when replacing a snapshot, while `id_global` can
remain stable. The implementation already re-enumerates and returns the new ID.
The original test assumption that the apply ID would stay fixed was corrected in
both the Lua fixture and transport simulator. Documentation now explicitly tells
clients to retain the new returned `snapshotId`; obsolete IDs never redirect.

Native apply uses `snapshotID`; native delete uses `id_global`. Both paths were
verified against Lightroom rather than inferred from identical-looking IDs.

## Application recovery

An earlier attempt stopped during a read-only version handshake before any copy
mutation was sent. A process sample showed Lightroom waiting in its native graphics
shutdown path. Automatic review rejected terminating that process. The user then
restarted Lightroom and authorized future recovery of an unresponsive Lightroom.
All live mutation checks above were completed after that restart; no force-termination
was needed during the resumed validation. The plugin's Start MCP Bridge Server menu
was used after restart to activate its polling loop.

## Limits

Live checks covered standard non-AI presets and a single-copy creation, plus a
two-photo preset batch. They do not exhaustively validate every preset, amount
slider, AI update/rendering path, batch virtual-copy creation or Lightroom version.
Those remaining variations have structural/unit coverage where applicable, not a
claim of exhaustive native behavior. See `versions-and-presets.md` for the SDK
completion versus full-content-verification distinction and partial-failure rules.
