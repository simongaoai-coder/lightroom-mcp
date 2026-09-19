# Mask management (plugin 1.1.4)

The bridge exposes 17 MCP tools in total, including seven mask tools. Mask management requires Lightroom Classic with SDK 11+ APIs. Python requires 3.10+ and MCP 1.x; MCP 2.x changes the server API used by this repository.

## Workflow

1. Call `lr_list_masks` on the selected photo.
2. Use returned IDs, not names or list positions, to identify the target. Names can be duplicated or localized.
3. Call `lr_update_mask` with `maskId` and `adjustments`. The Lua handler selects, verifies, updates and reads back in one request.
4. Call `lr_export_preview` to inspect the visual result.

All mask tools accept optional `expectedPhotoId`, obtained from a previous response's `data.photoId`. Supply it to reject a request when the user has switched photos between calls. Every handler also checks the selected photo during its own operation. These checks do not provide a transaction or lock the Lightroom UI.

## Tools

| Tool | Arguments | Result in `data` |
| --- | --- | --- |
| `lr_list_masks` | Optional `expectedPhotoId` | `photoId`, `masks`, selected IDs when present |
| `lr_get_selected_mask` | Optional `expectedPhotoId` | Selected IDs and available local `adjustments`; no selection is a valid result |
| `lr_select_mask` | Required `maskId`; optional `toolId`, `expectedPhotoId` | Verified selected IDs |
| `lr_update_mask` | Required nonempty `adjustments`; optional `maskId`, `expectedPhotoId` | Target `maskId`, actual `adjustments`, selected IDs |
| `lr_delete_mask` | Required `maskId`; optional `expectedPhotoId` | `deletedMaskId`, refreshed `masks`, selected IDs |
| `lr_delete_mask_tool` | Required `maskId`, `toolId`; optional `expectedPhotoId` | `deletedToolId`, parent `maskId`, refreshed `masks`; `parentMaskDeleted: true` if the parent disappeared |
| `lr_add_mask` | Required `maskType`; optional `adjustments`, `expectedPhotoId`; `params` must be empty | `status`, `maskType`, new `maskId` when identified, selected IDs, actual or deferred adjustments |

Optional IDs are omitted when there is no selected/new item. Empty mask/tool collections are JSON arrays. The list order is sorted by ID for stable output and is not the Lightroom panel order.

A successful list response looks like this (IDs and names are illustrative):

```json
{
  "success": true,
  "data": {
    "photoId": "photo-uuid",
    "selectedMaskId": "mask-a",
    "selectedToolId": "tool-a",
    "masks": [
      {
        "id": "mask-a",
        "name": "Sky correction",
        "hidden": false,
        "tools": [
          {"id": "tool-a", "type": "aiSelection", "subtype": "sky"},
          {"id": "tool-b", "type": "brush", "inverted": true}
        ]
      }
    ]
  },
  "message": "list_masks: verified"
}
```

The adapter consumes SDK summaries with `ID`, `Name`, `Hidden`, `Tools` and child `ID`, `Name`, `Type`, `Subtype`, `Hidden`, `Inverted` fields. Names/type metadata are passed through only when available. An unrecognized shape fails with `unsupported_mask_data`; it never invents an ID.

### Selecting and updating

```json
{"maskId": "mask-a", "toolId": "tool-b", "expectedPhotoId": "photo-uuid"}
```

Use the above with `lr_select_mask`. The tool must belong to the given parent mask. Local exposure/color sliders belong to the mask group, not independently to each component tool.

```json
{
  "maskId": "mask-a",
  "expectedPhotoId": "photo-uuid",
  "adjustments": {"Exposure": -0.5, "Highlights": -40}
}
```

Use the above with `lr_update_mask`. Values are absolute, not deltas. Parameter names are case-insensitive; `MoireFilter` remains accepted as an alias for `Moire` / `local_Moire`. Available parameters and ranges are checked against the active photo/process version through `getRange`. Unsupported parameters, non-finite numbers, booleans and duplicate aliases fail. All parameter ranges are checked before any slider is written.

Omitting `maskId` preserves the previous selected-mask workflow. No selection is an error. An explicitly invalid ID never falls back to the current selection. A successful explicit selection/update leaves the target selected.

### Creating masks

`subject`, `sky`, `background` are treated as automatic. A newly selected ID absent from the pre-operation list, with at least one component tool, is required before applying adjustments. Structural creation does not guarantee AI computation or rendering has finished; inspect the result in Lightroom/preview.

`brush`, `gradient`, `radialGradient`, `objects`, `people`, `landscape`, `luminance`, `color`, `depth` are treated conservatively as interactive. Draw, sample or choose the relevant options in Lightroom, then list masks again and explicitly update the new mask.

| `status` | Meaning |
| --- | --- |
| `created` | A new selected mask with component tools was identified; requested sliders were read back |
| `awaiting_user_input` | Creation tool was activated; complete the interaction in Lightroom |
| `pending` | Automatic creation was requested but a new populated selected mask was not identified within the bounded wait |

For the latter two states, supplied adjustments are **not written or queued**; `adjustmentsDeferred: true` tells the caller to resend them with `lr_update_mask` after identifying the completed mask. `selectedMaskId` may still refer to the old selection, so use only `maskId` as a newly created ID. Do not retry `lr_add_mask` blindly while AI creation is pending.

If creation succeeds but applying sliders fails, the error includes `data.maskId`, `data.photoId` and `data.creationStatus: "created"`. Reuse that mask ID instead of creating a duplicate.

Nonempty `params` now returns an explicit error. The previous implementation accepted geometry fields but never passed them to `createNewMask`; the public creation API accepts type/subtype only.

### Deleting

Deletion requires explicit IDs; there is no default delete-current behavior. The handler verifies parent/tool membership, selects the target, deletes it, then re-enumerates to verify removal. Deleting the last tool may also remove its parent; inspect the refreshed list. A repeated delete returns `mask_not_found` or `tool_not_found`.

## Errors and execution constraints

Failures return `success: false`, a machine-readable `code`, and `error`. Codes include `invalid_arguments`, `no_photo`, `photo_changed`, `no_mask_selected`, `mask_not_found`, `tool_not_found`, `unsupported_api`, `unsupported_mask_data`, `unsupported_parameter`, `context_timeout`, `selection_failed`, `selection_changed`, `deletion_failed`, `adjustment_failed`, `readback_failed`, and `sdk_error`.

Operations switch to Develop and open Masking as needed. They run inside the plugin's existing asynchronous polling task, protected with `LrTasks.pcall`, which permits cooperative yields. Masking UI operations are not wrapped in catalog write gates.

Selection/readback/deletion waits are bounded. Slider readback tolerates a difference of 0.0001; SDK rounding or an unapplied value can therefore produce `readback_failed`, with actual values in the error data. A multi-slider update is not transactional: some writes may already have occurred before an SDK error or user selection change. Read the mask again before retrying. File IPC still supports one sequential client; no multi-client request queue was added.

Live test results: [2026-09-19 verification](2026-09-19-live-verification.md).

## Development and validation

```sh
cd mcp-server
python3 -m venv venv
venv/bin/python -m pip install --isolated -r requirements-dev.txt
venv/bin/python -m pytest tests/ -q
```

The fixture starts the mock automatically on unique temporary paths. Do not manually start `mock_lr.py` for tests. Lupa is a development-only dependency: it executes the production `Masking.lua` module under Lua 5.1 with a controlled SDK double. It is not required by the deployed MCP server or Lightroom plugin.

Tests cover schemas and rejected arguments, MCP stdio, file IPC, independent mask state, selection and deletion verification, no masks/no selection, wrong parent, stale IDs, changed photos, SDK errors, unknown summary layouts, range validation, slider readback, deferred creation and Lua syntax. The standalone mock starts with two example masks; it does not emulate actual Lightroom rendering or every SDK constraint.

### Deployment: verify the loaded plugin path

The MCP launcher's install directory and Lightroom's loaded Lua plugin directory may be different copies. On this workstation they are:

- Python service: `/Users/simon/.local/share/lightroom-mcp/mcp-server/`
- Lightroom's registered plugin: `/Users/simon/Library/Application Support/Adobe/Lightroom/Modules/lightroom-mcp.lrdevplugin/`

Always inspect the **Path** shown in Lightroom's Plug-in Manager before upgrading. Update that Lua directory as well as the Python service, preserving local `LrForceInitPlugin` settings and backing up both copies. Merely updating `lightroom-mcp/lrplugin/` does not update a separately copied Modules plugin.

When an upgrade introduces a new Lua file, Lightroom may cache the old file list. In live verification, Reload Plug-in and disable/enable both reported `Could not load toolkit script: Masking`. Fully quit and reopen Lightroom after saving/confirming the current work can be closed. Then verify the startup version in `LrMCPBridge.log` and call `lr_list_masks`; the MCP tool listing alone proves only that the Python service loaded.

### Manual Lightroom acceptance (not covered by simulated tests)

Use a disposable test photo or virtual copy with two masks A/B and multiple tools under A:

1. Reload the whole plugin, restart the MCP client, and verify 17 tools are listed. Confirm both versions are 1.1.4 using `lr_ping`.
2. Start in Library; list masks and compare IDs/names/component types with Lightroom's Masking panel. Repeat with no masks and no selected photo.
3. With B selected, update A by ID. Verify only A changed, including after switching away and back; inspect History and the preview.
4. Select a component under A. Try a component belonging to B with A's ID; verify rejection and no edits.
5. On the disposable photo, delete a component, then the final component, then a whole mask; compare refreshed lists. Repeat with stale IDs.
6. Create an automatic sky/subject mask; inspect computation completion, returned ID and slider persistence. Create a gradient/brush; verify deferred adjustments leave existing masks untouched, draw it, then update its returned/listed ID.
7. Exercise people/objects/range selection UI and verify pending/user-input states. No type should claim that user interaction is complete merely because creation was requested.
8. Switch photos or masks during a delayed operation; verify an error rather than an update to another target. Check representative Lightroom versions and RAW/JPEG process settings.

API reference: [Adobe Lightroom Classic SDK reference mirror — LrDevelopController](https://lrc.mcor.dev/modules/LrDevelopController.html). SDK reference signatures/summary details and the controlled fixture are not a substitute for the manual acceptance above.
