# Live Lightroom verification — 2026-09-19

Final deployed version: **1.1.4**. `lr_ping` confirmed both `version` and `maskingVersion` as 1.1.4. The actual Lightroom Modules plugin and the service installation copy were both updated. Python exposes 17 tools.

## Results

| Tool / behavior | Actual Lightroom result |
| --- | --- |
| `lr_list_masks` | Returned real IDs, Chinese names, mask types, component IDs and selected state. Final cold-start and Library → Develop checks returned the two expected masks. |
| `lr_get_selected_mask` | Reported no selection correctly; after selection, returned actual local slider values. |
| `lr_select_mask` | Selected an explicit parent and child ID; getters confirmed both. |
| `lr_update_mask` | With B selected, changing A to Exposure 0.37 / Highlights -17 affected only A. B's complete returned slider map was unchanged. Switching away and back preserved A's values. |
| `lr_add_mask` (sky) | Final 1.1.4 roundtrip created a fresh ID, applied Exposure -0.2, then accepted an update to -0.4 and returned matching readback. Earlier successful sky test also verified Highlights -12. |
| `lr_add_mask` (gradient) | Returned `awaiting_user_input` and `adjustmentsDeferred: true`; after drawing on the virtual copy, exposure remained 0 until a separate update set it to 0.5. |
| `lr_delete_mask_tool` | Removed the explicit child and returned an empty tools array. On this installation, the empty parent can temporarily remain. |
| `lr_delete_mask` | Removed explicit test masks, including a remaining empty parent; refreshed list returned only the two baseline masks. |
| Wrong ID / parent | Invalid update ID and mismatched parent/child deletion were rejected. |
| Wrong photo | `expectedPhotoId` mismatch was rejected before changes. |

All mutations used a newly created virtual copy. The original photo received read/selection calls only. Test-created masks were removed. The virtual copy's changed Exposure/Highlights were restored to the original values (0.3 / -8), and its returned local slider map matched the original. The virtual copy remains as “副本 1”; the original photo was reselected at completion.

## Fixes discovered by live testing

1. **Deployment path:** Lightroom loaded an independent copy under `~/Library/Application Support/Adobe/Lightroom/Modules/`, not the `lrplugin/` directory inside the MCP service installation. That active copy was backed up and upgraded.
2. **New-file cache:** Introducing `Masking.lua` required a full Lightroom restart; Reload Plug-in and disable/enable were insufficient in that session.
3. **Transient SDK summary:** AI creation/deletion can temporarily return no usable mask summary. Bounded polling now tolerates nil/false only during pending-state checks; absence of a usable summary is never proof of deletion.
4. **Develop readiness:** A newly opened Develop module can briefly expose an empty mask summary. Before switching modules, the handler records catalog mask IDs and waits for the UI summary to match. Both original→copy and copy→original transitions were checked after the final cold start.
5. **Version observability:** Ping and startup logs now identify the masking module version as well as the main server version, so cached modules can be detected.

One create request issued during application startup timed out. Its result was reconciled with the mask list before any further creation; identified test masks were removed before repeating the test. Call `lr_ping` after startup before sending mutations.

## Scope and limits

**81 automated tests passed**, covering Python validation, file IPC, MCP stdio and production Lua under Lua 5.1 SDK doubles. The final deployed plugin passed the live sky creation → select child → update → readback → delete child → delete parent → list cycle.

These are representative functional checks on this Lightroom installation, not exhaustive validation of every SDK version, every photo/process version, all local sliders, all AI mask types, or all interactive subtools. People, objects, landscape, color/luminance/depth ranges, radial gradients and brushes were not individually drawn/generated in this live session. No performance or AI segmentation-quality claim is made.
