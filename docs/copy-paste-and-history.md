# Copy/Paste and Undo/Redo (2.7.0)

Five tools bring the total to **93**. Main/Python/Versions are **2.7.0**;
other module versions are unchanged. No new Lua filename requires a full restart.

| Tool | Purpose |
| --- | --- |
| `lr_copy_settings` | Copy current source in native_ui or explicit mode; return copyId |
| `lr_paste_settings` | Paste copyId onto the guarded current photo |
| `lr_get_history_state` | Read canUndo/canRedo and issue a one-use historyToken |
| `lr_undo` | Invoke one application-global native undo |
| `lr_redo` | Invoke one application-global native redo |

All accept optional expectedPhotoId and expectedCatalogPath; paste requires
expectedPhotoId. Photo copy/paste rejects video and does not batch over selection.

## Copy modes

`mode: native_ui` is the default. It calls `photo:copySettings()` with Lightroom's
last UI-selected copy categories. The SDK does not enumerate those categories or
expose a verifiable clipboard payload. The response says
`scope: ui_categories_unenumerated`; no guessed list of copied fields is returned.
This changes Lightroom's native settings-copy buffer.

The receipt records source UUID, catalog path and the source's full observed develop
state. Before a native paste, the source must still exist and match that state.
It is then re-copied immediately before `target:pasteSettings(false)`, reducing the
chance that an unrelated clipboard change between requests becomes the source.
This also overwrites the native copy buffer. UI copy-category changes and the brief
copy/paste interval cannot be independently verified: the response explicitly says
`clipboardScopeVerified: false`. There is no automatic AI-update request.
`native_call_and_observation` and changedKeys do not prove every selected field
was pasted or that downstream AI/rendering completed. A no-op can be legitimate.

`mode: explicit` requires 1–150 distinct `parameters`, using existing global numeric
names (case-insensitive). Available numeric values are frozen at copy time. Later
source edits do not change the receipt. Paste uses the existing per-photo Develop
mapping, preflight and readback, returning `numeric_readback`. It does not use the
native clipboard. This mode intentionally does not expose arbitrary raw settings,
mask geometry, profiles or structured curves as a generic settings writer.
Existing numeric-setting semantics apply, including Custom WB when temperature/
tint are pasted and possible native processing-version normalization.

Only server-held values are pasted; callers cannot inject a settings table into a
receipt. Copies are local to the plugin session, bounded to the latest 20 receipts,
and lost after reload/restart. A fresh MCP Python process can use an existing
receipt while the same plugin session remains active. Unknown/evicted copies fail.

## Undo/Redo semantics

These invoke `LrUndo.undo/redo`: **application-global history**, not a transaction
rollback keyed by an MCP request, and not guaranteed to affect only the current
photo. The API provides no actual history-entry identifier/name or target-photo
identity. An enabled canUndo/canRedo does not establish what will be changed.
Manual actions and other photos may be involved.

Call get_history_state immediately before each action. Its token:

- Expires after 60 seconds and is replaced by a newer history-state read.
- Captures catalog, active photo, selection UUIDs, current-photo develop settings,
  orientation/rating/pick flag and native undo/redo availability.
- Is invalidated by intervening non-read-only MCP commands, conservatively even
  when those commands subsequently fail.
- Is consumed before the native attempt, including a failed or uncertain attempt.
  Never automatically retry undo/redo, and never reuse an old token.

This is a context guard, not a global-history lock. Manual actions on another photo,
action grouping, or changes outside the captured fields can escape detection.
`historyEntryIdentityAvailable: false` is returned so clients do not infer an exact
rollback guarantee. Native history calls run without a catalog write gate.

Afterward, the tool reports current-photo observations, changed develop keys when
comparing the same photo, and updated canUndo/canRedo. `native_call_completed` does
not claim independent validation of all application-global effects. No current-photo
change does not prove the history action had no effect elsewhere. A new token must
be read for redo after undo, or for any subsequent operation.

## Recommended usage

For repeatable parameter transfer, copy explicit parameters, select the destination,
then paste with its expectedPhotoId. For the standard Lightroom copy workflow, use
native_ui and choose categories in Lightroom's Copy Settings dialog beforehand.
Read back settings/preview afterward. Use saved snapshots and baseline comparisons
when a specific photo state must be recoverable; do not use global undo as an
unattended error-recovery mechanism.

See [live validation](2026-09-20-copy-history-verification.md). SDK references:
[LrPhoto](https://lrc.mcor.dev/modules/LrPhoto.html) and
[LrUndo](https://lrc.mcor.dev/modules/LrUndo.html) (community-hosted Adobe API reference).
