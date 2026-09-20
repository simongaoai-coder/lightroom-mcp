# Geometry, scoped resets and catalog navigation (2.6.1)

This batch adds 11 tools (88 total). Main/Python/Fine/Library are 2.6.1;
other modules retain independent versions. All commands accept optional
`expectedPhotoId` and `expectedCatalogPath` guards. Photo mutations target the
current photo only; they reject videos and never modify original image files.

## Geometry and reset

| Tool | Contract |
| --- | --- |
| `lr_get_geometry` | Orientation, original/cropped pixel dimensions and crop fields |
| `lr_rotate_photo` | `direction: left|right`, one 90-degree native rotation |
| `lr_set_crop_aspect` | `preset: original|asshot` OR positive `width` and `height` |
| `lr_reset_adjustments` | A registered global numeric `parameter` OR a reset `group` |

Rotation uses `LrPhoto.rotateLeft/Right` and requires the expected orientation
transition before success. Unknown orientations are rejected before calling the SDK.
Rotation is relative/non-idempotent: never blindly retry after uncertain completion.

Aspect cropping uses `quickDevelopCropAspect`. Width/height express proportions,
not output pixel dimensions; Lightroom controls placement and orientation.
Custom/original proportions are checked against cropped pixel dimensions with a
2-pixel rounding tolerance, allowing the reciprocal ratio for native portrait/
landscape orientation. `effectiveRatio` reports the actual width/height. The as-shot
camera ratio has no independent documented getter, so that preset reports
`native_call_and_observation` rather than a verified target ratio.
Existing `lr_crop` remains available for explicit crop boundaries/angle.

Reset groups are `crop`, `transforms`, `masking`, and `redeye`. Masking clears ALL
local masks on the current photo, not just the selected mask. Use existing explicit
mask-delete tools for one mask, and `lr_reset_healing` for repair/removal regions.
No reset-all fallback is present. Group results check relevant catalog fields.

A parameter reset calls `LrDevelopController.resetToDefault` on the registered
canonical global slider name. `local_*` and arbitrary keys are rejected. It returns
previous/observed numeric values; SDK defaults are not assumed zero. No independent
native default-value getter is available, so the result explicitly reports
`defaultValueIndependentlyVerified: false` and `native_reset_value_observed`.

Controller resets activate Develop and run without a catalog write gate.
Crop reset uses a catalog write gate to clear only crop boundaries and angle
through applyDevelopSettings (the same documented fields used by lr_crop).
The native resetCrop call did not clear the tested crop on Lightroom 15.2.
Save a snapshot before edits, and compare saved settings when restoring; a snapshot
call returning is not proof of complete restoration.

## Navigation

| Tool | Contract |
| --- | --- |
| `lr_get_navigation` | Module, active sources, paged selected photos, filter and filter presets |
| `lr_list_folders` | Catalog folder hierarchy; exact paths, optional query and pagination |
| `lr_list_folder_photos` | `folderPath`, optional `includeChildren` and pagination |
| `lr_set_sources` | Exactly one of `allPhotos: true`, `folderPaths`, `collectionIds` |
| `lr_show_view` | Request a Library or Develop view |
| `lr_navigate_photos` | `next`, `previous`, `first`, `last`, `all`, `inverse` |
| `lr_set_view_filter` | `changes` OR exact `presetId`; optional `expectedFilter` |

Pagination uses offset 0 / limit 50 by default, maximum limit 200. Folder and
folder-photo listing are read-only catalog queries, not disk scans. Folder photo
pages sort by UUID; they do not represent the current filmstrip order.

Source changes resolve all sources before changing the UI. Exact folder paths must
come from this catalog; collection IDs can identify collections or collection sets.
Source switching opens Library and verifies active sources. Selection can change,
and Lightroom's remembered per-source filter settings may also change. The tool
returns the resulting state instead of silently claiming the old selection/filter
is still active. No file moves/imports or collection membership writes are involved.

Views: `grid`, `loupe`, `compare`, `survey`, `people`, `develop_loupe`,
`develop_before`, `develop_before_after_horiz/vert`, `develop_reference_horiz/vert`.
The SDK offers module readback but no reliable current main-view getter here.
`requestedView` is a request, not observed state; `verification: module_only`
makes this limit explicit. No screen mode, Lights Out or application preference
changes are made by these tools.

Photo navigation follows the native filmstrip order and visibility. Selection
operations do not explicitly change sources/filters. After a native call, an
unchanged result is `unchanged_or_boundary`: it may be a boundary or no native
effect, so the tool does not automatically retry. `all`/`inverse` operate on the
filmstrip, not necessarily every catalog photo. Returned selection is paginated;
`total` is the full observed selected count.

Filter patching preserves unmentioned native fields. Supported fields are the
three active flags, color-label booleans, minRating/ratingOp, and text search
string/operator/target (see schema for exact choices). Filter presets come from
`LrApplication.viewFilterPresets`. Unknown presets/fields and stale expectedFilter
are rejected. SDK return false can mean already applied; readback determines
success. A filter can hide selected photos, so selection is allowed to change.

## Validation

Production Lua tests cover geometry isolation, all eight orientation roundtrips,
invalid-input preflight, crop readback/no-ops, scoped resets, folder/source
preflight, view/navigation results, and filter changes/stale state. Mock tests
cover schemas and file IPC. These do not establish actual Lightroom behavior.
See the [current verification record](2026-09-20-geometry-navigation-verification.md)
for deployment/native validation status.

Sources: Adobe SDK references for [LrPhoto](https://lrc.mcor.dev/modules/LrPhoto.html),
[LrDevelopController](https://lrc.mcor.dev/modules/LrDevelopController.html),
[LrCatalog](https://lrc.mcor.dev/modules/LrCatalog.html),
[LrFolder](https://lrc.mcor.dev/modules/LrFolder.html),
[LrSelection](https://lrc.mcor.dev/modules/LrSelection.html), and
[LrApplicationView](https://lrc.mcor.dev/modules/LrApplicationView.html).
These are community-hosted renderings of Adobe's API reference.
