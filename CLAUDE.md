# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Architecture

```
Claude Desktop → MCP Server (Python/stdio) → File IPC (/tmp) → Lua Plugin → LrDevelopController
```

Two components that must work in tandem:

- **`mcp-server/server.py`**: Python MCP server communicating with Claude Desktop over stdio. Writes JSON commands to `/tmp/lr_mcp_req.json` and polls for `/tmp/lr_mcp_res.json`.
- **`lrplugin/lightroom-mcp.lrdevplugin/`**: Lightroom Classic plugin (Lua) that polls `/tmp/lr_mcp_req.json` every 50ms inside an async task. Processes commands via `LrDevelopController` APIs and writes results to `/tmp/lr_mcp_res.json`.

Both components are always upgraded together. There is no backwards compatibility between versions.

## Wire Protocol

File-based IPC using two temp files:

- **Request**: Python writes JSON to `/tmp/lr_mcp_req.json` (atomic rename from `.tmp`). Lua polls, reads, deletes it.
- **Response**: Lua writes JSON to `/tmp/lr_mcp_res.json`. Python polls and reads it.

Both files contain a single JSON object per transaction. Python defaults to a 10s timeout, with longer per-command timeouts (30s for mask management, 120s for creation).

> **Why not TCP?** `LrSocket` is a client-only event-driven API (connect/callbacks). It cannot bind as a server. File IPC is the correct approach for Lightroom Classic plugins.

## MCP Server Setup

```bash
cd mcp-server
python3 -m venv venv
source venv/bin/activate
pip install -r requirements.txt
python3 server.py   # test run; normally launched by Claude Desktop
```

For development and testing without Lightroom:

```bash
python -m pip install --isolated -r requirements-dev.txt
python -m pytest tests/ -v             # fixtures start isolated mock subprocesses
```

`mock_lr.py` is a dev/test tool only. It is never deployed or referenced by Claude Desktop.

## MCP Tools Reference

| Tool                      | Purpose                                                            |
| ------------------------- | ------------------------------------------------------------------ |
| `lr_ping`                 | Check the connection to the Lightroom plugin                       |
| `lr_get_settings`         | Read all develop slider values + filename + rating                 |
| `lr_apply_settings`       | Apply develop parameters to the selected photo                     |
| `lr_export_preview`       | Export a JPEG thumbnail; the AI client sees it inline for visual feedback |
| `lr_batch_apply_settings` | Apply develop parameters to all currently selected photos          |
| `lr_auto_tone`            | Run Lightroom's Auto Tone on the selected photo                    |
| `lr_reset`                | Reset all develop settings to defaults                             |
| `lr_crop`                 | Crop and/or straighten the selected photo                          |
| `lr_add_mask`             | Add a mask (subject, sky, gradient, brush, etc.)                   |
| `lr_update_mask`          | Apply local sliders to a specified or currently selected mask |
| `lr_list_masks` | List masks and component tools |
| `lr_get_selected_mask` | Read selected IDs and local sliders |
| `lr_select_mask` | Select a mask and optional component tool |
| `lr_delete_mask` | Delete an explicit mask |
| `lr_delete_mask_tool` | Delete a tool from its explicit parent mask |
| `lr_lens_blur`            | Apply AI Lens Blur (depth-of-field) with bokeh shape control       |
| `lr_enhance`              | Run AI Denoise, Super Resolution, or Raw Details enhance           |

### lr_export_preview

```json
{ "size": 1500 } // optional, default 1500, max 2048 (long edge pixels)
```

Returns MCP `ImageContent` (JPEG). Typical workflow:

1. Call `lr_export_preview` to see the photo
2. Analyze tone, color, sky, etc. visually
3. Call `lr_apply_settings` with suggested changes
4. Call `lr_export_preview` again to verify

### lr_apply_settings / lr_batch_apply_settings

```json
{ "settings": { "Exposure": 0.5, "Highlights": -30 } }
```

Parameter names are case-insensitive. `lr_batch_apply_settings` uses `catalog:getTargetPhotos()` (all photos currently selected in Lightroom).

### Mask management (1.1.4)

See [docs/mask-management.md](docs/mask-management.md) for the complete contract and manual acceptance checklist.

- `Masking.lua` owns all seven mask commands; `Server.lua` delegates them.
- `lr_list_masks` returns normalized SDK masks/tools, selected IDs and a photo UUID.
- `lr_get_selected_mask` reads selection and available local sliders.
- `lr_select_mask` accepts `maskId` and optional child `toolId`.
- `lr_update_mask` accepts optional `maskId`; omitted means the selected mask. No selection is an error; invalid IDs never fall back.
- `lr_delete_mask` requires `maskId`; `lr_delete_mask_tool` requires both IDs. Removal is verified.
- `lr_add_mask` returns `created`, `pending` or `awaiting_user_input`, plus a new ID when identified. Only subject/sky/background are treated as automatic. Deferred adjustments are not queued; resend them after drawing/sampling/selection. Nonempty `params` is rejected (previously ignored).
- All mask tools accept optional `expectedPhotoId` to reject stale cross-photo requests.
- SDK summaries use `ID`, `Name`, `Hidden`, `Tools`; child entries use `ID`, `Name`, `Type`, `Subtype`, `Hidden`, `Inverted`. Unknown layouts must fail rather than infer IDs.
- `lr_ping` reports both main `version` and `maskingVersion`; verify both after deployments.
- During AI operations, nil/false summaries are transient, never evidence of deletion. Before changing modules, capture catalog mask IDs and wait for the UI summary to match.
- Use `LrTasks.pcall` around yield-capable masking operations, never ordinary `pcall` or catalog write gates. Check photo identity and active mask after waits and verify slider readback.
- Local slider ranges are checked dynamically. `MoireFilter` aliases `local_Moire`; unsupported sliders must return errors.
- Python schemas/validation live in `mask_tools.py`; stateful simulation lives in `mock_masks.py`.
- `tests/test_masking_lua.py` executes production Lua 5.1 through development-only Lupa. `tests/test_mask_tools.py` checks Python validation, file IPC and MCP stdio. Neither proves Lightroom UI/AI/rendering behavior.

## Develop Parameter Ranges

**Tone**

| Parameter  | Range       | Notes |
| ---------- | ----------- | ----- |
| Exposure   | -5 to 5     |       |
| Contrast   | -100 to 100 |       |
| Highlights | -100 to 100 |       |
| Shadows    | -100 to 100 |       |
| Whites     | -100 to 100 |       |
| Blacks     | -100 to 100 |       |
| Clarity    | -100 to 100 |       |
| Dehaze     | -100 to 100 |       |

**Color**

| Parameter   | Range        |
| ----------- | ------------ |
| Vibrance    | -100 to 100  |
| Saturation  | -100 to 100  |
| Temperature | 2000–50000 K |
| Tint        | -150 to 150  |

**HSL** (suffix: Red/Orange/Yellow/Green/Aqua/Blue/Purple/Magenta)

| Parameter              | Range       |
| ---------------------- | ----------- |
| HueAdjustment\*        | -100 to 100 |
| SaturationAdjustment\* | -100 to 100 |
| LuminanceAdjustment\*  | -100 to 100 |

**Detail**

| Parameter           | Range   |
| ------------------- | ------- |
| Sharpness           | 0–150   |
| SharpenRadius       | 0.5–3.0 |
| SharpenDetail       | 0–100   |
| SharpenEdgeMasking  | 0–100   |
| LuminanceSmoothing  | 0–100   |
| ColorNoiseReduction | 0–100   |

**Effects**

| Parameter                | Range       |
| ------------------------ | ----------- |
| GrainAmount              | 0–100       |
| GrainSize                | 0–100       |
| PostCropVignetteAmount   | -100 to 100 |
| PostCropVignetteMidpoint | 0–100       |

**Transform**

| Parameter             | Range       |
| --------------------- | ----------- |
| PerspectiveVertical   | -100 to 100 |
| PerspectiveHorizontal | -100 to 100 |
| PerspectiveRotate     | -10 to 10   |

**Color Grading**

| Parameter              | Range       |
| ---------------------- | ----------- |
| ColorGradeBlending     | 0–100       |
| ColorGradeGlobalHue    | 0–360       |
| ColorGradeGlobalLum    | -100 to 100 |
| ColorGradeGlobalSat    | 0–100       |
| ColorGradeMidtoneHue   | 0–360       |
| ColorGradeMidtoneLum   | -100 to 100 |
| ColorGradeMidtoneSat   | 0–100       |
| ColorGradeHighlightLum | -100 to 100 |
| ColorGradeShadowLum    | -100 to 100 |

**B&W Mix** (suffix: Red/Orange/Yellow/Green/Aqua/Blue/Purple/Magenta)

| Parameter   | Range       |
| ----------- | ----------- |
| GrayMixer\* | -100 to 100 |

**Split Toning**

| Parameter                      | Range       |
| ------------------------------ | ----------- |
| SplitToningBalance             | -100 to 100 |
| SplitToningHighlightHue        | 0–360       |
| SplitToningHighlightSaturation | 0–100       |
| SplitToningShadowHue           | 0–360       |
| SplitToningShadowSaturation    | 0–100       |

**Defringe**

| Parameter              | Range |
| ---------------------- | ----- |
| DefringeGreenAmount    | 0–100 |
| DefringeGreenHueHi/Lo  | 0–100 |
| DefringePurpleAmount   | 0–100 |
| DefringePurpleHueHi/Lo | 0–100 |

### lr_lens_blur

```json
{
  "active": true,
  "amount": 50,
  "bokeh": "Circle",
  "catEye": 0,
  "highlightsBoost": 20,
  "focalRangeFromSubject": true
}
```

Valid `bokeh` values: `Circle`, `SoapBubble`, `Blade`, `Ring`, `Anamorphic`.

### lr_enhance

```json
{ "denoise": true, "denoiseAmount": 50 }
{ "superRes": true }
{ "rawDetails": true }
```

Triggers AI processing that creates a new enhanced DNG file; runs in the background after the call returns.

Key files in `lrplugin/lightroom-mcp.lrdevplugin/`:

- `Info.lua`: plugin manifest; registers menu items and `InitPlugin.lua`
- `InitPlugin.lua`: auto-starts the bridge on Lightroom launch via `LrInitPlugin`
- `Server.lua`: file IPC polling loop, base64, JSON, and non-mask develop logic
- `Masking.lua`: mask enumeration, selection, creation, deletion and verified local adjustments
- `StartServer.lua` / `StopServer.lua`: manual fallback start/stop menu items

## Reference

- [Lightroom Classic SDK Guide](docs/Lightroom%20Classic%20SDK%20Guide.pdf): official Adobe SDK documentation. Key sections: `LrDevelopController` API reference, `LrTasks` async model, plugin manifest keys, Lua sandbox restrictions.

## Versioning (MANDATORY)

**Every change to `Server.lua` or `Masking.lua` MUST bump the version in both places or the running build will be impossible to identify in logs.**

1. `lrplugin/lightroom-mcp.lrdevplugin/Info.lua`: `VERSION = { major, minor, revision }`
2. `lrplugin/lightroom-mcp.lrdevplugin/Server.lua`: `local VERSION = "x.y.z"`

Both must always match. The version is logged on every server start:
```
Claude LR Bridge v1.1.0 started (file IPC mode)
```

**Default: bump `revision` for every change**, even small ones. Only use `minor` for new user-visible features and `major` for breaking wire protocol changes. When in doubt, bump revision.

## Logs

### Plugin log (primary debug source)

```
~/Library/Logs/Adobe/Lightroom/LrClassicLogs/LrMCPBridge.log
```

Written by `LrLogger("LrMCPBridge")` with `log:enable("logfile")`. Appended across sessions. Contains:
- Server start/stop with version
- All `log:info` / `log:error` calls from `Server.lua`
- `requestJpegThumbnail` diagnostics, response write confirmations, etc.

To tail live: `tail -f ~/Library/Logs/Adobe/Lightroom/LrClassicLogs/LrMCPBridge.log`

### Lightroom console log (Lua runtime errors)

```
~/Library/Application Support/Adobe/Lightroom/lrc_console.log
```

Contains Lua stack traces from unhandled errors inside Lightroom's plugin sandbox (e.g. bad API calls, nil indexing). Check this when the plugin fails to start or a command crashes silently.

### Server start confirmation

After any plugin restart, verify the correct version loaded:
```
tail -3 ~/Library/Logs/Adobe/Lightroom/LrClassicLogs/LrMCPBridge.log
```
Expected: `LR MCP Bridge vX.Y.Z started (file IPC mode)` with no "Server already running" after it (which would indicate a double-start race).

## Adding New Commands

1. Add a handler branch in `Server.lua`:`handleRequest()` (mask commands go in `Masking.lua`)
2. Add the tool definition in `server.py`:`list_tools()`
3. Add the dispatch case in `server.py`:`call_tool()`
4. Add the mock response in `mock_lr.py`:`_State.handle()`
5. Add a test in `tests/test_server.py`

## Key Constraints

- Parameter names in `lr_apply_settings` are case-insensitive; `Server.lua` normalises via `PARAM_INDEX`.
- Masking UI mutations must **not** be inside `catalog:withWriteAccessDo()`. Follow existing per-operation SDK handling for other mutations; there is no universal write-gate rule.
- `photo:requestJpegThumbnail` is callback-based; `Server.lua` polls with `LrTasks.sleep(0.05)` until the callback fires (max 5s).
- The mock's `_make_jpeg` shifts hue with Temperature, so warm/cool changes are visually verifiable even without Lightroom.
- `pip install` requires the `--isolated` flag on this machine due to a system pip.conf issue: `venv/bin/python3 -m pip install --isolated <package>`

## Phase 1 foundations (2.0.0)

See [phase1-foundation.md](docs/phase1-foundation.md) for the current protocol and
settings contract; it supersedes older descriptions above of global setValue,
10-second transport behavior and unconditional AI availability.

- `Develop.lua` owns numeric parameter registration, photo-specific catalog mapping,
  single/batch preflight and readback. Main and Develop versions are 2.0.0;
  Masking remains independently versioned at 1.1.4.
- Request IDs, protocol version 2, and expected plugin version are required for
  non-ping dispatch. Python uses a read-only handshake before sending commands.
- `lr_ping` reports actual paths and runtime capabilities. `lr_get_settings` can
  return raw SDK settings for inspection, not arbitrary raw settings writes.
- Production Lua tests are in `test_develop_lua.py`; transport checks are in
  `test_phase1.py`. Preserve the existing mask tests.

## Phase 2: versions and presets (2.1)

- `Versions.lua` owns nine new tools for snapshot CRUD, virtual-copy creation/family
  selection and preset enumeration/application. Python schemas are in `version_tools.py`.
- Snapshot `snapshotID` is the public `snapshotId` and native apply argument;
  native deletion uses its `id_global`. Never interchange them or guess IDs.
- Snapshot creation/preset application require catalog write access. Snapshot
  apply/delete use Develop context without a write gate; virtual-copy creation
  also runs without a write gate and implicitly changes selection.
- A preset/snapshot application can legitimately be a no-op. Report native SDK
  completion and observed changed keys, never claim every stored setting or AI
  render was independently verified. Batch failures do not roll back earlier photos.
- `updateAISettings` requests require the actual photo method before applying presets.
- Preserve UTF-8 request names (`ensure_ascii=False`) with the bundled JSON decoder.
- See [versions-and-presets.md](docs/versions-and-presets.md) and the production Lua
  tests in `test_versions_lua.py`; `MockVersions` is a transport simulator only.

## Phase 3: fine editing (2.2)

- `Fine.lua` owns Auto WB, point curves and point-color CRUD. `fine_tools.py`
  registers 12 new tools including five commands dispatched through `Masking.lua`.
- `Masking.prepareTarget` and `checkTarget` are shared with Fine; local controls
  require explicit mask IDs. `local_point_color` is a valid masking subtool.
- Combination operations add new components. Nil selected-mask IDs during AI work
  are transient; a different nonempty ID fails. Do not claim pixel-level coverage.
- Visibility/child inversion set desired states; whole inversion is a toggle.
- Global curves use catalog settings, local curves use controller parameters.
  The public curve coordinate scale is 0-255, converted to recognized native arrays.
- Point-color updates/deletions require `expectedSwatch`; preserve unknown native
  fields, compare readback and reject stale indices. Nil initial lists are marked
  unavailable/uninitialized, never silently treated as proven empty/deleted.
- Auto WB must return finite controller values as well as observed Auto mode.
- Use a full Lightroom exit/reopen if plugin reload leaves mixed-version polling
  tasks. The protocol gate must not be bypassed to work around mixed versions.
- See `docs/fine-editing.md` and tests `test_fine_lua.py`, `test_mask_fine_lua.py`,
  `test_fine_tools.py`. Mocks are transport simulators, not proof of native behavior.

## Phase 4: library and delivery (2.3)

- `Library.lua` owns catalog search/selection, metadata, keyword and collection
  operations. Targets resolve UUIDs before writing; numeric keyword/collection IDs
  are catalog-local and can be guarded by expectedCatalogPath.
- Native findPhotos descriptors are compiled from a restricted, typed filter set.
  Smart collections share the compiler. No photo import/deletion/file moves.
- Catalog mutations use write gates and readback. Metadata clearFields handles
  explicit clearing without relying on JSON null in the existing Lua decoder.
- `Delivery.lua` starts native export sessions in a separate LrTasks task. Never
  hold a catalog write gate while rendering. Each job has a unique output folder;
  native collisions rename. No auto-reimport and no automatic cleanup of outputs.
- Python creates export job IDs and returns the ID on uncertain starts. Clients
  must poll job status; queued/running is not delivery completion. Cancellation is
  cooperative between photos. Job state does not survive plugin reload/restart.
- Stop the service before deployment and do not reload during active exports.
- Schemas are in library_tools.py; production Lua tests use library_fixture.lua and
  delivery_fixture.lua. MockLibrary is only a transport simulator.
- See docs/library-and-delivery.md and the phase-4 verification record for native
  validation status; mocks do not establish output dimensions/encoding/ICC data.

## Phase 5: repair / Remove (2.4)

- Healing.lua owns 17 tools; schemas live in healing_tools.py. Main/Python and
  Healing are 2.4.2; Versions is 2.4.0. Tool total: 72.
- Controller spot operations run in Develop/Remove without a write gate. Use
  returned native indices plus expectedSpot, never guess the index base. Reset
  requires the full-list revision. Nil/count mismatch is not proof of an empty list.
- AI settings updates and catalog empty-mask cleanup DO require catalog write
  access. Preset-triggered AI updates use the same rule. Jobs freeze photo objects,
  yield between photos and report sdk_completed rather than rendered completion.
- No arbitrary repair-stroke creation or raw catalog repair-data writes. Only Opacity/Feather (0–1) may be patched; other spot data is read-only.
  Lightroom 15.2 ignored the native setter in live testing, so readback_failed is
  expected there. Never silently fall back to raw catalog repair writes.
- Generative refresh requires explicit opt-in; next/previous only target an
  existing generative spot. Do not retry an uncertain mutation blindly.
- See docs/healing-and-remove.md. Production Lua tests use healing_fixture.lua;
  MockHealing is only a transport simulator.

## Appearance controls (2.5.1)

- Fine.lua also owns get_appearance, set_treatment, set_white_balance, list_profiles
  and set_profile. Schemas are in appearance_tools.py; total tool count is 77.
- Main/Python/Fine are 2.5.1. Reuse the existing Lua module to avoid unnecessary
  full application restarts. Other modules keep independent version numbers.
- Quick Develop treatment/WB methods use native calls without a write gate;
  As Shot and profile settings use catalog write access. Verify readback and identity.
- Profile sources are observed photos and public SDK-visible presets, not a full
  installed-profile inventory. Only server-read profile fields are applied; require
  expectedProfile and conservative camera/RAW compatibility checks.
- As Shot/Auto catalog numeric WB fields may be stale/absent. Do not report them as
  effective sliders. Custom numeric WB stays in lr_apply_settings.
- Native rendering can normalize processing version later. Never claim snapshot
  restoration is complete without comparing saved baseline settings.
- See docs/appearance-controls.md and its native verification record. Tests:
  test_appearance_lua.py, appearance_fixture.lua, test_appearance_tools.py.

## Geometry and navigation (2.6.1)

- Fine.lua handles four geometry/reset tools; Library.lua handles seven navigation
  tools. Python schemas/routes are in navigation_tools.py. Main/Python/Fine/Library
  are 2.6.1; total tool count 88. Existing module files avoid a full restart just
  to discover new Lua filenames.
- Photo rotation and crop proportions use native LrPhoto methods; controller
  resets run in Develop without a catalog write gate; crop reset instead writes
  explicit crop bounds/angle under a catalog write gate after a native no-op was
  observed. Verify rotation/crop/group
  state. Parameter resets have no independent default getter: report that limit.
- Navigation calls can change selection, so final catalog guards must allow the
  intended photo switch. Source paths/collection IDs are preflighted before writes.
- getCurrentViewFilter/setViewFilter are the actual SDK method names. False from
  setViewFilter can mean already applied, not an error. Preserve unknown fields.
- showView can only be verified by module, not a nonexistent main-view getter.
  Do not modify Lights Out or screen settings to implement navigation.
- See docs/geometry-and-navigation.md. Native behavior must be checked separately
  from mocks; production Lua coverage uses navigation_fixture.lua.

- Do not call yield-capable photo metadata APIs inside table.sort comparators.
  Precompute UUIDs before sorting folder-photo pages. Native view-filter key is
  noLabel on Lightroom 15.2 (some API docs spell it nolabel).

## Copy/Paste and history (2.7.0)

- Versions.lua owns five history_tools.py commands. Main/Python/Versions are 2.7.0;
  93 tools total. Receipts are in-plugin-session objects, latest 20 retained.
- native_ui uses copySettings/pasteSettings(false) without a write gate. Category
  selection and clipboard contents cannot be independently enumerated. Verify
  source state and re-copy immediately before paste; never claim full-paste proof.
- explicit copy freezes only registered numeric values and reuses Develop's normal
  mapping, write gate and readback. No generic raw-settings write tool is added.
- LrUndo is application-global. One-use 60-second history tokens capture context,
  not actual history-entry identity. Server calls Versions.beforeCommand to
  invalidate observations on intervening MCP mutations. Manual edits elsewhere
  may remain undetected. Never auto-retry undo/redo after uncertainty.
- Keep tests/test_history_lua.py and the production Develop fixture distinct from
  mock_history.py's transport-only simulation. Read docs/copy-paste-and-history.md
  and its live validation record before changing these semantics.

## Process Version (2.8.0)

- Fine.lua owns get_process_version/set_process_version; schemas live in
  appearance_tools.py. Main/Python/Fine are 2.8.0; total 95 tools.
- Both require Develop context. Setter uses the documented controller API without
  a write gate, requires expectedPhotoId and one selected photo, and optionally
  guards expectedVersion. Never treat raw catalog codes as SDK version names.
- Verify both the requested SDK name and a raw-version transition; same-version
  calls are explicit no-ops. Report changed keys and no claim of pixel equivalence.
- All six versions were tested live in 15.2 and the baseline fully restored.
  See docs/process-version.md and tests/test_process_version.py. Future raw codes
  must not be guessed from the version number or a hardcoded production table.
