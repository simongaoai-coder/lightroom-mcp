# Saved styles and explicit batch targets (2.12.2)

One new tool, `lr_save_style`, brings the total to 111. Main/Python/Styles/Batch are 2.12.2 (Develop remains 2.12.0). Reload matching plugin code and restart the MCP client before use.

## Save and reuse a style

Save selected settings from the active photo, or supply sourcePhotoId to read a
specific photo without changing selection:

```json
{"name":"旅行胶片","groups":["colorGrading","pointCurve","grain"]}
```

Pass this to `lr_save_style`. It returns presetId, the selected settings, source
photo ID and process version. Then use existing `lr_list_presets` (query by name)
and `lr_apply_preset` (exact presetId) to reuse it:

```json
{"presetId":"returned-preset-id","photoIds":["photo-uuid-1","photo-uuid-2"]}
```

- Explicit parameters and/or groups are required; neither means save-everything.
- `parameters` accepts existing numeric parameter names, case insensitive, for
  example `["Contrast", "SplitToningHighlightHue"]`. Unsupported/unavailable
  controls fail before creating a preset.
- `colorGrading` contains 14 global/midtone/highlight/shadow hue/saturation/
  luminance, balance and blending controls, including the SDK SplitToning names.
- `pointCurve` captures RGB composite and red/green/blue point curves using their
  ToneCurvePV2012 keys. It does not capture the parametric curve; select those
  numeric parameters explicitly if needed. All four point curves must be present.
- `grain` contains GrainAmount, GrainSize and GrainFrequency.
- No exposure, white balance, crop, profile or mask is included implicitly by these
  groups. Numeric white-balance selection also saves WhiteBalance=Custom because
  the selected temperature/tint values are explicit.
- Values are absolute. A saved Exposure of +0.5 sets +0.5; it does not add half a
  stop. Use lr_batch_adjust_relative for additive adjustments.
- Duplicate plugin preset names (case insensitive) fail. This version does not
  overwrite, rename or delete saved styles. Choose a different name for a variant.

Lightroom's addDevelopPresetForPlugin persists the native preset on disk; plugin
preferences persist the selected-field manifest and compatibility checks. They
survive normal plugin/Lightroom restarts, but are local to this Lightroom/plugin
installation, not cloud synchronization or a portable export format. Presets are
hidden from the normal Develop preset panel and appear in MCP preset enumeration
with pluginOwned=true.

Creation must enumerate the saved preset and read back its selected settings.
Unexpected SDK-added source editing fields fail validation (matching ProcessVersion
is permitted). Failed verification may leave a native preset on disk; its manifest
is marked unverified and application is blocked. Inspect the returned ID instead
of blindly repeating creation. Clearing plugin preferences removes the manifest; applying that plugin-owned preset
now fails with style_manifest_missing. It never falls back to the unsafe native
preset path. Recreate the style from a known source or restore its manifest.

For verified saved styles, apply requires the source's exact raw ProcessVersion,
matching setting types/availability and compatible absolute/incremental WB units.
Native preset contents must still match the saved manifest. Amount is omitted or
100; other amounts are rejected because exact selected-field readback would no
longer describe the requested result. These checks are conservative. They do not
prove identical appearance across cameras or guarantee all rendering behavior.

As of 2.12.2, verified saved styles apply only a clone of their recorded settings
through LrPhoto.applyDevelopSettings, under catalog write access. The native preset
remains the persistent storage/enumeration artifact; its whole-preset application
path is not used for these styles, because Lightroom 15.2 changed omitted custom
WB values in native acceptance. Ordinary user presets retain their native path.
In addition to selected-field readback, unselected process/WB/exposure/crop/profile
invariants are checked. Custom WB numeric values are protected; Auto/As Shot
numeric values may be resolved/recomputed, so their mode is protected instead.
Unexpected protected changes fail with unselected_settings_changed and identify
the changed fields; there is no blind compensating rollback.

## Consistent target selection

These six existing tools now accept explicit batches:

| Tool | Default with neither target option |
| --- | --- |
| lr_apply_settings | Current photo |
| lr_batch_apply_settings | Selected photos (existing behavior preserved) |
| lr_apply_preset | Current photo |
| lr_set_treatment | Current photo |
| lr_set_white_balance | Current photo |
| lr_rotate_photo | Current photo |

Choose `photoIds` (1-200 unique UUIDs) OR `scope: "current" / "selected"`, not both.
`expectedPhotoId` guards the active UI photo; it does not mean every target must
have that ID. `expectedCatalogPath` guards the catalog. Explicit UUID batches can
operate without an active UI photo, unless expectedPhotoId requires one.

For example, set selected search results to black and white:

```json
{"photoIds":["photo-uuid-1","photo-uuid-2"],"treatment":"grayscale"}
```

Or set their absolute exposure:

```json
{"photoIds":["photo-uuid-1","photo-uuid-2"],"settings":{"Exposure":0.3}}
```

Targets are resolved before writes; missing IDs, videos, unsupported APIs and
known compatibility problems reject the batch during preflight. Numeric settings, saved-style writes and rotation use photo objects without
changing selection. Treatment and named WB (except the catalog-backed As Shot
path) use native Quick Develop, which is UI-bound on Lightroom 15.2. Each target
is temporarily selected alone; both active-photo identity and the entire selection
are verified before the native call. Original active photo and multi-selection
are restored after success or failure. Sources/filters are not forced to reveal
hidden targets: an unselectable target fails before its native write.

Quick Develop results include selectionTemporarilyChanged, selectionRestored and
an optional selectionRestoreError. If manual selection changes are detected, stop
and do not override the user's new selection. Failed restoration makes the call
unsuccessful even when all photo writes completed; applied/failed still count
photo outcomes separately. Avoid manually changing selection while these calls run.

Selection-driven operations
such as masks, history, AI controller tools and virtual-copy creation retain their
existing scope; they are not silently routed through UI switching.

Explicit batches return applied/failed/notAttempted and per-photo results. Preset
application now uses the batch result contract for all scopes. Existing no-target
appearance/rotation calls keep their original single-photo result shapes.

First failure stops subsequent photos; earlier changes remain. Native readback
checks the requested treatment/WB/orientation or saved-style fields. Ordinary
presets report SDK completion and observed changedKeys, not full content or AI
render verification. Rotation is non-idempotent: never retry an uncertain batch
blindly. Successful matching values may already have been present.

## Validation and references

Production Lua tests cover selected-field capture, native persistence/preferences
across module reloads, name collisions, unverified saves, incompatible process/WB,
native preset changes, missing IDs, offscreen targets without selection, whole-
batch preflight, partial failure, native no-ops and real Server JSON dispatch.
Python tests cover schemas and isolated file IPC. These are SDK doubles and
transport simulations. Those automated tests alone do not establish native behavior. Native preset
persistence was subsequently verified, and the two acceptance defects were fixed
and retested on 2.12.2. See [native fix verification](2026-09-21-native-fixes.md)
for the actual tested scope and remaining interactive item.

Native acceptance: save the three-group example from a disposable photo, restart
Lightroom, enumerate/apply it by ID to a different virtual copy, inspect retained
fields plus untouched exposure/crop/WB, and compare selected UI IDs before/after.
Test mixed RAW/JPEG WB rejection and different process versions separately.

SDK sources (Adobe reference, community-hosted copies):
[LrApplication](https://lrc.mcor.dev/modules/LrApplication.html),
[LrDevelopPreset](https://lrc.mcor.dev/modules/LrDevelopPreset.html),
[LrPhoto](https://lrc.mcor.dev/modules/LrPhoto.html).
