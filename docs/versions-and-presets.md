# Photo versions and develop presets (2.1)

Phase 2 adds nine tools, for 26 total. `Versions.lua` owns this workflow; the existing
Develop and Masking modules retain their separate versions. Ping reports
`versionsVersion` and runtime `capabilities.versions` in addition to the responding
server's actual tool names/count. Protocol remains 2; update Python and Lua together.

## Tools and targets

| Tool | Arguments | Behavior |
| --- | --- | --- |
| `lr_list_snapshots` | `expectedPhotoId?` | List current photo's snapshots |
| `lr_create_snapshot` | `name`, `updateExisting?`, `expectedPhotoId?` | Save the current develop state; same-name collision fails by default |
| `lr_apply_snapshot` | `snapshotId`, `expectedPhotoId?` | Restore one exact snapshot on the current photo |
| `lr_delete_snapshot` | `snapshotId`, `expectedPhotoId?` | Delete one exact snapshot, verifying absence afterward |
| `lr_list_virtual_copies` | `expectedPhotoId?` | List master and sibling copies with UUIDs/copy names |
| `lr_create_virtual_copies` | `copyName?`, `scope?`, `expectedPhotoId?` | Create a copy of the current photo or each selected photo |
| `lr_select_virtual_copy` | `photoId`, `expectedPhotoId?` | Select a master/copy within the current family |
| `lr_list_presets` | `query?`, `offset?`, `limit?` | Search SDK-visible preset names/folders; sorted pagination |
| `lr_apply_preset` | `presetId`, `scope?`, `amount?`, `updateAISettings?`, `expectedPhotoId?` | Apply an exact preset to the current photo or selected photos |

`scope` is `current` by default. `selected` explicitly targets the selection captured
at request start. No catalog-wide target is implied. Video targets are rejected.
`expectedPhotoId` guards the active photo UUID; it does not assert the full selection.
Unknown IDs never fall back to the selected snapshot, a similarly named preset,
or an unrelated photo. Names and IDs must be nonempty and contain no control characters.
Chinese and other UTF-8 names are preserved through the file protocol.

## Save, experiment, restore

1. Read `lr_get_settings` and retain its `photoId`.
2. Call `lr_create_snapshot` with a descriptive name and that `expectedPhotoId`.
3. Retain the returned `snapshotId`.
4. Edit, or list presets and apply the chosen `presetId`.
5. Call `lr_apply_snapshot` with the saved ID to restore the earlier develop state.

The SDK supplies two snapshot identifiers. The public `snapshotId` corresponds to
`snapshotID` and is used by all MCP snapshot operations. Internally the delete
operation resolves the corresponding `id_global`, exposed as `globalId` for
inspection. Users do not need to switch identifier types themselves.

Creation uses a catalog write gate. Apply/delete activate Develop and use the
snapshot SDK operations without surrounding them with a catalog write gate.
Same-name creation fails as `snapshot_exists`; `updateExisting: true` explicitly
replaces the saved state. Lightroom can change `snapshotID` during replacement
even while `id_global` stays the same; retain the newly returned `snapshotId`.
An older apply ID is rejected rather than redirected. Snapshot listing shapes that cannot be recognized fail
rather than guessing an ID.

A snapshot saves develop state, not a duplicate image file, catalog backup, rating
or keyword history. Applying a snapshot can replace the current edits; save them
first when they must be retained. Creating/deleting snapshots is verified by
re-enumeration. The SDK does not expose the stored settings of a snapshot without
applying it: `verification: sdk_completed_and_observed` on restore reports the
native call and observed `changedKeys`, not an independent proof of every value.
An unchanged photo can legitimately yield an empty changed-key list.

## Virtual copies and comparisons

Create a named copy, then edit the selected result. The response includes `sources`,
`created` (UUID, copy name, master UUID), `count`, `selectedPhotoId`, and
`selectionMatchesCreated`. Lightroom's native operation normally selects new
copies. No new RAW/JPEG file is produced.

For current-photo scope, the plugin first narrows selection to the current photo,
so a multi-selection cannot accidentally create extra copies. For selected scope,
it checks the selection before calling the native SDK function. Returned copies
must have new UUIDs, belong to the expected master families, and match per-family
counts. Copy order is not assumed to identify which source copy was cloned.

`lr_list_virtual_copies` lists the current family; `lr_select_virtual_copy` selects
one member (including the master), enabling before/after style comparison with
`lr_export_preview`. It does not implement arbitrary catalog photo selection.
Copy deletion, file deletion, and creating presets are outside this phase.

If creation fails or times out after submission, inspect the family before retrying:
a failure does not prove no copy was created. Some failures can leave a narrowed
selection or partial copies. There is no automatic deletion/rollback.

## Preset reuse and verification

Preset enumeration uses `developPresetFolders()` and folder `getDevelopPresets()`,
plus presets owned by this plugin when the SDK exposes them. This lists SDK-visible
presets, not a promise that every UI profile/category is exposed. It does not import
presets or create new preset files. Same-name presets remain distinct by UUID.
Pagination defaults to 50 entries (maximum 200); sort order is folder/name/UUID.

`amount` is an optional integer 0-200 forwarded to Lightroom's native preset API.
Its effect depends on the preset's support for amount. By default AI updates are
not requested. `updateAISettings: true` requires the actual per-photo SDK
`updateAISettings` method before any write, and invokes it explicitly after applying
the preset. This avoids silently passing an unsupported extra argument on older
Lightroom versions. Function presence does not guarantee every AI preset supports
all image types, nor that GPU rendering is complete when the command returns.

Preset responses report per-photo `success`, `status`, `verification`, and
`changedKeys`, plus overall `applied`, `failed`, and `notAttempted`. They compare
observed SDK settings before/after; they do not claim a perfect comparison against
all preset internals. Existing identical settings can yield no changes. A failed
batch stops at the first failure, leaving earlier successful edits in place; the
failed photo may also be partly changed. Save snapshots before a batch when needed.

## Validation and references

Automated coverage executes production Lua 5.1 with SDK doubles (including distinct
snapshot apply/delete IDs, duplicate names, stale photos, no-op creation/deletion,
copy selection boundaries, missing APIs and partial preset batches). Python checks
schemas, non-ASCII transport, isolated IPC and actual MCP stdio. These tests do not
replace live GPU/UI checks.

References: Adobe API reference mirrors for
[LrPhoto](https://lrc.mcor.dev/modules/LrPhoto.html),
[LrCatalog](https://lrc.mcor.dev/modules/LrCatalog.html),
[LrApplication](https://lrc.mcor.dev/modules/LrApplication.html), and
[LrDevelopPresetFolder](https://lrc.mcor.dev/modules/LrDevelopPresetFolder.html).
Snapshot ID distinctions and Develop context are also discussed in Adobe's
[snapshot SDK documentation issue](https://community.adobe.com/bug-reports-674/p-sdk-document-lrphoto-snapshot-methods-663151).
