# Phase 4 verification — 2026-09-20

## Final deployment

Main/Python/Library/Delivery: **2.3.2**, protocol **2**, **55 tools**.
Seventeen new tools cover library operations and native file delivery. Existing
Develop/Versions/Masking/Fine modules retain their independent versions.

Installed Lua files in `~/Library/Application Support/Adobe/Lightroom/Modules/lightroom-mcp.lrdevplugin`
match the working tree. A fresh real MCP stdio client initialized, listed 55 tools,
and confirmed `compatible: true` with the final version. Existing MCP clients may
need to reconnect to load new schemas.

The previous 2.2.3 deployment was backed up at
`/tmp/lightroom-mcp-before-phase4-20260920-141659`. Updates after the initial restart
used Stop MCP Bridge Server → copy files → Reload Plug-in → Start MCP Bridge Server.
No update occurred while an export was running.

## Automated verification

**250 tests passed** with:

`mcp-server/venv/bin/python -m pytest mcp-server/tests -q`

Production Lua 5.1 tests cover search descriptors, valid/invalid dates, pagination,
explicit selection and asynchronous source refresh, catalog/photo guards, metadata
read/write/clear, formatted-only IPTC fields, empty-object JSON serialization,
keyword hierarchy/associations, normal/smart collections and sets, write timeouts,
partial failures, async exports, cancellation, offline preflight, settings mapping,
render failures, empty files and equivalent output-directory paths.

Python tests cover schema validation, isolated file IPC, job-ID/result transport
and registration. Existing phase-1/2/3 regressions remain included.
`git diff --check` passed. Renderer doubles are not treated as native image-encoding
proof; the real files below were independently inspected.

## Native library acceptance

Lightroom Classic **15.2**. The user had confirmed the open images were backup
copies suitable for testing. Mutations targeted the two existing test virtual
copies of `_DSC1049.ARW`; the master and the full family were included in baseline
reads to check isolation/restoration.

| Check | Actual result |
| --- | --- |
| Selection/read | Returned active UUID, selected photo list and actual catalog path |
| Search | Native filename/rating/flag/color filters returned the expected two modified copies; UUID-sorted pagination worked |
| Explicit selection | Two UUIDs and the original master could be selected and verified; returning from Develop to Library also passed |
| Metadata batch | Rating 3, picked flag, red label, Unicode title and caption persisted on both copies |
| Text getters | Title/caption/label/etc. read correctly through formatted SDK getters |
| GPS | Latitude/longitude and altitude 12.3 were written and read back, then explicitly cleared |
| Keyword hierarchy | Created parent/child keywords with IDs and synonyms; updated child name, synonyms and export flag |
| Associations | Added the child keyword to both copies, read back IDs, then removed the associations |
| Collection hierarchy | Created a test set, standard collection and smart collection |
| Membership | Added two copies to the standard collection, searched its actual members and later removed them |
| Smart collection | Native filename/rating filters matched the master; name and filter updates read back correctly |
| Deletion guard | Nonempty standard collection deletion rejected by default |
| Collection cleanup | Deleted the empty standard collection, explicitly deleted the test smart collection, then deleted the empty parent set |
| Metadata restoration | Requested metadata maps, missing-field sets and keyword associations matched all three recorded family baselines |
| Original selection | Master UUID restored as the sole active/selected photo |
| Final stdio guards | Wrong catalog rejected; absent-only metadata serialized as `{}`; existing masks and preview APIs still worked |

## Real export files

The actual SDK renderer generated files under `/tmp/lr-phase4-delivery` in unique
batch subfolders. The plugin reported observed progress and actual per-photo paths.
Pillow/ImageCms inspection confirmed:

| Export | Result |
| --- | --- |
| Two-photo JPEG batch | Completed 2/2; each **1200 × 800**, JPEG, embedded **sRGB IEC61966-2.1**, Unicode test title present |
| 16-bit TIFF | Completed 1/1; **800 × 533**, TIFF bits-per-sample **16/16/16**, embedded **ProPhoto RGB**, Unicode test title present |
| Full-size default JPEG through real stdio | Completed 1/1; sizing omitted; **6000 × 4000** JPEG |
| Cooperative cancellation | Requested during a two-photo 4096-pixel TIFF batch; the in-flight photo completed, the second did not start; final status cancelled, completed=1, notStarted=1 |

The cancellation test verified the completed file remained on disk. No export was
automatically reimported, and no source image file was moved or deleted.

An initial JPEG attempt correctly rendered two files but was reported as failed by
an overly strict string comparison between `/private/tmp` and Lightroom's returned
`/tmp` alias. SDK canonicalization corrected that verification issue; subsequent
jobs reported completion correctly. The initial files remain as test artifacts.

## Cleanup and retained artifacts

- All tested photo metadata and direct keyword assignments were restored.
- All three phase-4 test collection definitions were removed.
- No new virtual copy was created in this phase; earlier restored test copies remain.
- Two **unused** test keyword definitions remain: `MCP 第四阶段测试` and its child
  `交付已验证`. Both have includeOnExport=false and no remaining test-photo associations.
  Keyword-definition deletion is not exposed by these tools.
- Export test files remain under `/tmp/lr-phase4-delivery`, including the partial
  cancelled batch. They were not added to Git. Temporary validation reports are
  stored alongside the other `/tmp/lr-phase4-*.json` records.

Catalog history/export-tracking state is not claimed to be byte-identical to its
pre-test state. The plugin does not force XMP saves; Lightroom's preferences govern
any automatic metadata-file synchronization.

## Findings incorporated

1. IPTC text uses `getFormattedMetadata`, even though its writer is `setRawMetadata`.
   Treating label/title/caption as raw getter keys produced native Unknown key errors.
   The SDK doubles were tightened to reject those raw reads.
2. Lightroom reports an unlabelled photo as `gray` on this installation. Public
   results and readback normalize that to `none`; custom label text remains separate.
3. Empty metadata maps need an explicit JSON-object marker, rather than the legacy
   encoder's default empty-array representation.
4. A source transition can asynchronously reset selection. The handler avoids
   redundant source switches and yields for the source/module transition before
   applying and verifying the requested UUIDs.
5. Renderer paths can use filesystem aliases. Paths are resolved/canonicalized
   before the output-folder check; failures retain the returned path for diagnosis.

## Application recovery and limits

The first validation attempt was blocked by an unresponsive Lightroom startup/
shutdown sequence. A read-only sample found the native graphics shutdown wait;
authorized TERM recovery was attempted. Computer Use could not access the system
permission-window application. The user manually clicked Allow; after starting the
bridge, the native tests above completed. No system permission restriction was
bypassed by the tools.

Live coverage is representative, not exhaustive: one ARW family on macOS/Lightroom
15.2, the metadata fields above, standard and smart collections, JPEG/TIFF exports,
resizing, two color spaces and cancellation. Watermark appearance, every IPTC field,
all search-date/localization cases, offline media, large catalogs and Windows were
not individually exercised live. Export jobs remain session-local; reload/restart
can lose status even though files remain. See `library-and-delivery.md` for the
public contract and recovery rules.
