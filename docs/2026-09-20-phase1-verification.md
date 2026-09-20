# Phase 1 verification — 2026-09-20

## Final deployment

- Main plugin / Python server: **2.0.0**, protocol **2**.
- Develop module: **2.0.0**. Unchanged masking module: **1.1.4**.
- Lightroom Classic: **15.2** (reported by the running SDK).
- Loaded plugin: `~/Library/Application Support/Adobe/Lightroom/Modules/lightroom-mcp.lrdevplugin`.
- Python configuration points to this repository's `mcp-server/server.py` and venv.
- A fresh real MCP stdio client initialized successfully, listed **17 tools**, and
  received `compatible: true` with matching paths and versions from `lr_ping`.
- The pre-update Modules folder was backed up to
  `/tmp/lightroom-mcp-before-phase1-20260920-112056`. This is a temporary local
  recovery copy; the repository diff is the durable change record.

Reloading the plugin manifest alone left the old loop running. Lightroom was
restarted, then Plug-in Extras > Start MCP Bridge Server was used. After the final
file synchronization, Reload Plug-in and Start MCP Bridge Server loaded 2.0.0.
Existing external MCP clients may still need to reconnect/restart their Python
processes; the independent stdio test does not prove another client's cache updated.

## Photo verification

The user confirmed the open photos are backup copies suitable for testing.
Tests used two selected ARW files, `_DSC1044.ARW` and `_DSC1049.ARW`.

| Check | Actual result |
| --- | --- |
| Read from Library | Returned catalog settings, photo UUID, ProcessVersion 11.0, mappings and raw data without needing Develop UI |
| Single write | Exposure 0.73, Highlights -9, RedHue 4 persisted and read back correctly |
| Batch write | Both selected photos returned Exposure 0.47, Highlights -13, RedHue 3 with applied=2 and success=true |
| Single-photo isolation | Restoring the first photo while both were selected left the other at batch Exposure 0.47 |
| Restore | Exposure restored to 0.33 / 0.66 respectively; Highlights and RedHue restored to 0 on both |
| Unknown parameter | Returned unsupported_parameter; no write |
| Wrong expected photo UUID | Returned photo_changed; no write |
| Absent AI API | Enhance returned unsupported_api for missing setEnhance |
| Existing mask enumeration | Succeeded; returned zero masks for the selected test photo |
| Preview regression | JPEG preview succeeded; final MCP call returned ImageContent |
| Final-version stdio write | On 2.0.0, Exposure 0.71 succeeded and was restored to 0.66 |
| Baseline comparison | All normalized numeric settings on the final selected photo matched the recorded baseline before the final write/restore |

The intermediate numeric tests used the same mapping/write implementation that
shipped in 2.0.0. The final stdio test repeated a write/restore against 2.0.0.
Lightroom history entries created during testing remain; parameter restoration
is not a claim that catalog history or internal digests are byte-identical.

Runtime detection found `setEnhance` and `setLensBlurFocalRangeFromSubject` absent
on this Lightroom 15.2 installation, while mask APIs and `setLensBlurBokeh` were
present. No AI enhancement or new AI image was generated during these tests.

## Automated validation

`mcp-server/venv/bin/python -m pytest mcp-server/tests -q`

**110 passed.** Includes production Lua 5.1 tests for modern/legacy mapping,
rendered-file white balance, boolean conversion, batch preflight, partial writes,
readback no-ops, write lock timeout, photo identity, missing APIs and actual server
dispatch; Python tests for input validation, version gating, request correlation,
timeout semantics, MCP stdio; plus existing masking regression coverage.

`git diff --check` passed. Source and deployed plugin files were compared.

Not exhaustively validated live: every numeric parameter, legacy process versions,
JPEG white balance, Lens Blur AI rendering, auto-tone/reset rendering, long batches,
Windows file locking, or multiple legacy clients competing for the IPC files.
No preset, snapshot, library-management, full-export or removal tools were added.
