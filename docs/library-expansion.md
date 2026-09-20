# Search, library structures, virtual copies and metadata presets (2.9.0)

Main/Python/Library are **2.9.0**. Nine new tools bring the total to **104**;
existing search, smart collections and keyword tools are extended as well.

## Search expressions

`lr_search_photos`, smart `lr_create_collection` and `lr_update_collection` share
one typed compiler to native findPhotos/searchDesc. Existing flat filters remain
AND conditions. New logical keys are arrays of filter objects:

- `all`: AND (native intersect).
- `any`: OR (native union).
- `none`: none of the child expressions may match (native exclude / NOR).

Keys on the same object are ANDed. Thus an ordinary field can constrain an OR group:

```json
{
  "filters": {
    "any": [{"cameraModel": "ILCE-7M3"}, {"minISO": 1600}],
    "none": [{"hasAdjustments": false}],
    "fileFormat": "RAW"
  }
}
```

This means RAW AND (camera matches OR ISO >= 1600) AND NOT unedited. Each child may
itself contain all/any/none. Nesting is limited to 8 levels, groups to 50 children,
and total nodes to 100. Empty nested groups, reversed numeric/date ranges and
unknown fields fail before any native search or smart-collection write.

Additional leaf filters:

| Input | Native criteria / semantics |
| --- | --- |
| cameraModel, cameraSerialNumber, lens | camera, cameraSN, lens; exact string match |
| minISO, maxISO | isoSpeedRating; inclusive numeric bounds |
| hasAdjustments, hasGPS, cropped | Boolean edited/GPS/cropped state |
| treatment | color or grayscale |
| orientation | portrait, landscape or square |
| folder, collection, title, caption, copyName | Native contains-text match |
| country, city, creator | Exact string match |
| captureInLastDays | Relative capture date, 1–365000 days |
| fileFormat | RAW, DNG, JPG, TIFF, PSD, PNG, PSB, AVIF, JXL, VIDEO |

Folder/collection text criteria are name searches; they are not exact IDs. Existing
collectionId and folder-list tools remain available for unambiguous scope. Search
returns UUID-sorted pages without changing selection; native text matching and
index updates follow Lightroom's semantics. New format/criteria availability can
vary across SDK versions; native errors are surfaced rather than silently dropping
conditions. No unrestricted raw descriptor or SQL input is exposed.

## Keyword and collection structure

`lr_move_keyword(keywordId, parentId)` and
`lr_move_collection(collectionId, parentId)` use **parentId=0** for the root.
Collection parents must be collection sets. Both reject cycles and destination
sibling-name collisions, then verify the resulting parent ID. Keyword setParent is
an async native call without an outer write gate; collection/set setParent requires
catalog write access. These do not modify photo files or delete keywords.

`lr_list_keyword_photos` uses the exact keyword ID and native getPhotos. Optional
includeDescendants unions child keyword results and deduplicates UUIDs before
pagination. It does not approximate membership by keyword-name text searching.

`lr_list_keywords` now includes the native attributes object and keywordType when
provided by the SDK (for example person). `lr_update_keyword` also accepts
ignoreCase as a native update modifier; actual name/synonym/export readback remains
the success criterion. It is not a stored keyword attribute. The public SDK setter
only documents name, synonyms, includeOnExport and ignoreCase; unsupported writes
such as arbitrary keywordType/export flags are not invented.

## Current target collection

`lr_show_target_collection` opens the documented kTargetCollection source.
`lr_toggle_target_collection` calls the single active photo's native
addOrRemoveFromTargetCollection method. It requires expectedPhotoId and a single
selected photo; it reports before/after ordinary collection IDs. Selection can
change after removal from an active target source.

This is a relative toggle, not an idempotent add/remove request. Do not automatically
retry after uncertainty. Quick Collection/native target identity is not guaranteed
to be represented by ordinary collection IDs. Opening a source does not designate
it as the target collection. A public setter for choosing an arbitrary native target
collection was not found in the inspected API; choose that designation in Lightroom.

## Virtual copies

`lr_rename_virtual_copy` takes photoId and copyName, with optional expectedCopyName.
It requires isVirtualCopy=true, checks that again inside catalog write access, and
verifies the resulting name. Empty copyName is allowed. Original photos are rejected.

`lr_remove_virtual_copy` requires photoId and expectedMasterPhotoId, with optional
expectedCopyName. It preflights the virtual-copy flag and master UUID, switches to
Library grid/All Photographs, selects exactly that copy, revalidates selection and
identity, and calls LrSelection.removeFromCatalog. That native method requires SDK
14.3+. The tool does not hold a catalog write gate around the selection-based call.
It verifies the copy no longer resolves and the master still resolves.

This changes UI source/selection and removes the copy's catalog state. It does not
remove the original image file, accept original-photo deletion, batch over arbitrary
selection, or bypass filters that prevent correct selection. An uncertain response
is not permission to repeat removal blindly. Preserve needed copy settings before
calling; no automatic recreation/rollback is promised.

## Metadata presets

`lr_list_metadata_presets` enumerates LrApplication.metadataPresets with exact IDs,
query and pagination. `lr_apply_metadata_preset` accepts presetId plus current /
selected / explicit photo targets using the existing batch contract. It resolves
all targets and the preset before writing, applies photo:applyMetadataPreset under
catalog write access, and stops on the first failure with partial-result counters.

Optional readbackFields uses the existing metadata whitelist; by default all known
writable fields are observed. Results contain before/after metadata and keyword
observations plus changedFields. The SDK does not expose this preset's field-selection
contents, so `native_call_and_known_metadata_observation` is not proof of every
possible preset effect. A valid preset can be a no-op; earlier successful photos
are not rolled back after a later failure. Save metadata that must be recoverable.
These tools do not create/import presets or force XMP writes.

## Verification and references

See [native verification](2026-09-20-library-expansion-verification.md). Production
Lua and mock IPC tests have separate roles; mocks do not establish native search
semantics or successful catalog deletion.

Adobe API references (community-hosted renderings):
[LrCatalog](https://lrc.mcor.dev/modules/LrCatalog.html),
[LrKeyword](https://lrc.mcor.dev/modules/LrKeyword.html),
[LrCollection](https://lrc.mcor.dev/modules/LrCollection.html),
[LrPhoto](https://lrc.mcor.dev/modules/LrPhoto.html),
[LrSelection](https://lrc.mcor.dev/modules/LrSelection.html).
