# Library and delivery (2.3)

Phase 4 adds 17 tools, bringing the total to 55. Main/Python/Library/Delivery are
2.3.2. Existing Develop, Versions, Masking and Fine modules keep their independent
versions. Ping reports the two new module versions and catalog/export capabilities.
Protocol remains 2; update the Python process and Lua plugin together.

## Photo identities and catalog guards

`lr_get_selection` reports the active photo UUID and a paginated selection.
`lr_search_photos` returns UUID-sorted pages without changing the UI. All library
results include `catalogPath`. Use `expectedCatalogPath` to guard numeric collection
and keyword IDs, which are local to one catalog. Optional `expectedPhotoId` guards
the currently active photo, including when an explicit photo batch is supplied.

For metadata, keyword associations, collection membership and export, choose:

- `photoIds`: 1-200 unique photo UUIDs, resolved and validated before any write; or
- `scope: "current"` (default) / `scope: "selected"`.

Do not provide both. Selected scope requires an active photo; no selection never
silently becomes the entire catalog. The target objects are captured before a
batch starts. Failed per-photo mutations stop the batch and report `applied`,
`failed`, `notAttempted`, and individual results; there is no automatic rollback.
A failed photo can be partially changed.

`lr_select_photos` takes explicit `photoIds` and optional `activePhotoId` (default:
first UUID). `reveal: true` by default opens Library and All Photographs before
selecting. Redundant source switches are avoided, and source/module transitions
are allowed to settle before selection is applied. Existing view filters are not silently cleared and can cause
`selection_failed`; the resulting selection is checked against the requested IDs.
`reveal: false` attempts selection within the existing source/view.

## Search filters

`lr_search_photos` accepts `filters`, optional `collectionId`, and pagination
(`offset: 0`, `limit: 50`, maximum 200). Restricting to a collection uses its actual
members, including dynamically evaluated smart collections. Collection sets are
not photo sources.

Filters are combined with AND using native `LrCatalog.findPhotos` descriptors:

| Filter | Meaning |
| --- | --- |
| `query` | Native all-searchable-text contains matching |
| `filename` | Native filename contains matching |
| `keyword` | Native keyword text matching |
| `minRating`, `maxRating` | Inclusive 0-5 star bounds |
| `pickStatus` | -1 rejected, 0 unflagged, 1 picked |
| `colorLabel` | red/yellow/green/blue/purple/none |
| `fileFormat` | RAW/DNG/JPG/TIFF/PSD |
| `captureAfter`, `captureBefore` | Exclusive YYYY-MM-DD capture-date bounds |

Pagination bounds the response, not the native matching set. Catalog changes
between requests can change page contents. Search and hierarchy enumeration are
not a benchmarked streaming API for very large catalogs.

## Metadata

`lr_get_metadata` returns photo summaries, requested `metadata`, `missingFields`
and direct keyword IDs/names. It uses formatted getters for IPTC text and raw
getters for numeric/structural fields; localized numeric strings are not parsed.
The SDK's unlabelled `gray`/`grey` state is normalized to `none`. Empty metadata
maps remain JSON objects even when every requested field is absent. Default fields are rating, pick status, label color,
title, caption, creator and copyright. Optional `fields` allows supported camera,
file-format, date, virtual-copy and location metadata too. As of 2.10.0,
`fieldGroup: "capture"` reads the complete supported shooting field set and
`fieldGroup: "all"` reads all supported fields. Groups and explicit fields are
mutually exclusive. Getter exceptions appear in per-photo `fieldErrors`, distinct
from absent values in `missingFields`; successful fields still return. See
[Shooting metadata](capture-metadata.md) for the full field list and units.

`lr_set_metadata` takes `values` and/or `clearFields`. Writable fields:

- `rating` (integer 0-5), `pickStatus` (-1/0/1), `colorNameForLabel` (six named colors
  including none), or custom `label` text. Do not combine label and colorNameForLabel.
- `title`, `caption`, `creator`, `copyright`, `rightsUsageTerms`, `headline`.
- `location`, `city`, `stateProvince`, `country`, `isoCountryCode`.
- `gps` as `{latitude, longitude}`, and numeric `gpsAltitude`.

Empty text clears a text field. `clearFields` also permits explicit GPS removal,
without relying on JSON null (the existing Lua wire decoder discards null object
values). Setting and clearing the same field is rejected. Readback normalizes
empty text/nil and default rating/flag/color states, and reports failures rather
than silently skipping unsupported fields.

These are catalog metadata operations, not develop snapshots. Snapshots do not
back up this metadata. Save the returned metadata and missing-field list before
a reversible experiment. The plugin does not force an XMP save; Lightroom's own
metadata-writing preferences can still affect files.

## Keywords

- `lr_list_keywords`: flat, paginated hierarchy with keyword IDs, parent IDs,
  paths, synonyms and includeOnExport; optional literal query.
- `lr_create_keyword`: name, optional parentId/synonyms/includeOnExport. A same-name
  sibling is returned without modifying its existing attributes.
- `lr_update_keyword`: update an explicit keyword's name, synonyms or export flag;
  read back the result.
- `lr_update_photo_keywords`: `operation: "add"` or `"remove"`, explicit keywordIds,
  and photo targets. Checks direct associations after writing.

Removing an association does not delete the keyword definition. Keyword deletion,
reparenting and face recognition are outside these tools. Same-name keywords in
different branches remain distinct by local ID.

## Collections

- `lr_list_collections`: hierarchy rows for standard/smart collections and sets.
  `includeCounts: true` evaluates member counts; it is false by default.
- `lr_create_collection`: name, kind (`collection`, `set`, `smart`), optional
  parentId. Parent must be a set. Smart collections require nonempty `filters`
  using the same compiler as photo search. Duplicate sibling names fail.
- `lr_update_collection`: rename a collection/set or replace a smart collection's
  filters. This is not a membership edit or reparent operation.
- `lr_update_collection_photos`: add/remove photo targets in a standard collection
  and verify their membership. Sets and smart collections reject manual members.
- `lr_delete_collection`: remove the collection definition only, not its photos or
  image files. `requireEmpty` defaults true. Explicit false permits deleting a
  nonempty photo collection; nonempty sets are always rejected to avoid cascading
  child deletion.

No import, image-file move or photo deletion is provided by this phase.

## Native file delivery

`lr_export_photos` starts an asynchronous `LrExportSession` task. This is separate
from `lr_export_preview`, which remains a cached JPEG preview tool.

The required `destination` is an existing absolute directory on the Lightroom
host. Each job creates `LR-MCP-export-<jobId>` beneath it. By default, file names include the
source name and a sequence number; native collision handling is rename. Existing
batch folders are never reused. Exported photos are not automatically reimported.
Python resolves the destination's filesystem aliases before dispatch. Lightroom
can return an equivalent alias path (for example `/tmp` versus `/private/tmp`);
the SDK resolves both paths before verifying the output folder.

Supported output settings:

| Option | Values/default |
| --- | --- |
| `format` | JPEG (default), TIFF |
| `quality` | JPEG only, 1-100; default 90 without a size limit |
| `maxFileSizeKB` | JPEG-only size cap, exclusive with quality; 1 KB = 1024 bytes |
| `bitDepth` | TIFF only, 8 or 16; default 16 |
| `colorSpace` | sRGB (default), AdobeRGB, ProPhotoRGB |
| `longEdge` / `shortEdge` | Exclusive optional pixel limits, 1-65000 |
| `width`, `height` | Pixel bounding box; both required, exclusive with other sizing modes |
| `megapixels` | 0.01-1000, exclusive with other sizing modes |
| `naming` | Original/custom prefix, sequence start/padding, extension case |
| `doNotEnlarge` | true by default |
| `resolution` | DPI, default 240 |
| `sharpenFor` | none (default), screen, matte, glossy |
| `sharpenAmount` | 1/2/3; default 2 when sharpening is enabled |
| `metadata` | all (default), allExceptCameraInfo, copyrightOnly, copyrightAndContactOnly |
| `removeLocation` | false by default |
| `watermarkId` | Optional ID of an existing Lightroom watermark preset |

The plugin does not create or enumerate watermark presets. Invalid/unsupported
native rendering settings are reported through job errors; watermark appearance
is not independently inspected by the plugin. DNG/PSD/PNG/video export and remote
publishing are outside this release. Offline originals and video targets are
rejected before the batch folder is created.

The start response includes a job ID even if the transport outcome is uncertain.
Poll `lr_get_export_status(jobId)` until status is completed, failed or cancelled.
Queued/running success means the job was accepted, not that files are finished.
Status returns successful-file count, failed-file count, not-started count and
paginated per-photo results. Completed results contain the actual renderer path
and nonzero byte size, verified in the new batch directory.

Only one export job runs at once. Each photo uses its own native session; failures
are recorded and other photos continue. `lr_cancel_export(jobId)` requests
cancellation between photos. The active render can finish, and completed files
remain. No export file is automatically deleted on error/cancellation.

The target photo set is captured at submission, but develop/metadata values are
read by Lightroom when each photo is rendered. Avoid editing those photos while
an export runs. Do not reload/stop the plugin during an export. Job state lives in
the current plugin session; after a reload/restart, job_not_found does not prove
that no files were written. Inspect the returned batch directory before retrying.

## Verification and SDK references

Production Lua tests cover the library and asynchronous export workflow with SDK
doubles; Python tests cover schemas, isolated IPC and published tool registration.
Native acceptance is tracked in `2026-09-20-phase4-verification.md`. Automated
renderer doubles cannot prove file encoding, dimensions, color profiles or metadata.

References: the bundled Adobe SDK Guide, pp. 61-68 (export properties) and 77-83
(search descriptors); API reference mirrors for
[LrCatalog](https://lrc.mcor.dev/modules/LrCatalog.html),
[LrPhoto](https://lrc.mcor.dev/modules/LrPhoto.html),
[LrKeyword](https://lrc.mcor.dev/modules/LrKeyword.html),
[LrCollection](https://lrc.mcor.dev/modules/LrCollection.html),
[LrExportSession](https://lrc.mcor.dev/modules/LrExportSession.html), and
[LrExportRendition](https://lrc.mcor.dev/modules/LrExportRendition.html).


For the 2.14.0 argument combinations, limits, naming examples and failure semantics,
see [Export sizing and naming](export-sizing-and-naming.md). All sizing omitted
means unconstrained dimensions. Oversized JPEG output is retained but reported
failed, not counted as a completed delivery.
