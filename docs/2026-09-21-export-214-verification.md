# Export 2.14.0 native verification — 2026-09-21

**Historical 2.14.0 result: partial acceptance. Fractional megapixel sizing does not honor the request
on the tested Lightroom 15.2 runtime. Other tested export options passed.**

The fractional-MP issue was subsequently fixed and verified in
[2.14.1 native verification](2026-09-21-megapixel-fix.md). Original observations
below are preserved.

Tested committed build `a9505b1`, main/Python/Delivery **2.14.0**, Lightroom Classic
**15.2**, macOS. Native plugin files were backed up, deployed and hash-checked after
Lightroom exited. A fresh MCP stdio session enumerated **112 tools** and confirmed
matching Python/plugin versions. This test used production code and real native
exports, not a mock renderer. No production code was changed during verification.

## Materials and checks

Six previously authorized independent RAW test originals were read before/after.
Exports used _DSC1042.ARW, a newly created and temporarily rotated virtual copy of
that original, and the existing 1400×933 stripped-EXIF test JPEG. Portrait exports
therefore exercise an orientation-adjusted photo, not a separately shot portrait
RAW. No original was rotated or edited. Each job used its own new output directory.

Actual output files were decoded with Pillow, including EXIF orientation handling,
and inspected for pixel dimensions, bytes, format, filenames and TIFF bit depth.
JPEG output filenames and hashes are retained in the evidence summary. Successful
native calls alone were not used as proof of requested dimensions.

## Results

| Request | Actual result | Assessment |
| --- | --- | --- |
| Default JPEG | 6000×4000, _DSC1042-0001.jpg, 5,056,709 bytes | PASS, original sizing/default naming |
| Long edge 1200 | Landscape 1200×800; portrait 800×1200 | PASS |
| Short edge 600 | Landscape 900×600; portrait 600×900 | PASS |
| Bounding box 1000×700 | Landscape 1000×667; portrait 467×700 | PASS, aspect ratio preserved |
| 1 MP | 1224×816 = 998,784 pixels | PASS within native rounding |
| 2 MP | 1731×1154 = 1,997,574 pixels | PASS within native rounding |
| 4 MP | 2449×1633 = 3,999,217 pixels | PASS within native rounding |
| Portrait 2 MP | 1154×1731 | PASS |
| 0.5 MP, both orientations | render_failed: There was an error parsing the file. | **FAIL** |
| 0.9 MP | Same native render failure | **FAIL** |
| 1.5 MP | 1224×816, same pixel count as 1 MP | **FAIL: request not honored** |
| 2.5 MP | 1731×1154, same pixel count as 2 MP | **FAIL: request not honored** |
| JPEG long edge 2000, default doNotEnlarge | 1400×933, unchanged source dimensions | PASS |
| Same JPEG, doNotEnlarge=false | 2000×1333 | PASS |
| 100 KB limit, long edge 1600 | 95,035 and 95,845 bytes; both <=102,400 | PASS |
| 1 KB limit, long edge 1600 | Native wrote 89,023 bytes; bridge reported file_size_limit_exceeded and retained path/file | PASS for failure handling; not a successful delivery |
| Custom prefix/sequence/case | 验收精选-09.JPG, 验收精选-10.JPG | PASS, numbering continues across one-photo sessions |
| Original names with same-stem targets | _DSC1042.jpg and _DSC1042-2.jpg | PASS, native rename collision policy |
| TIFF box 700×700 / sequence start 21 / 3 digits / uppercase | 700×467 and 467×700; _DSC1042-021.TIF and -022.TIF; 8/8/8 bits per sample | PASS |

Five invalid requests were rejected before creating an output directory: conflicting
long/short edges, width without height, size limit plus fixed quality, TIFF plus
JPEG size limit, and a custom prefix containing a path traversal. These exercised
the production MCP validation path, not native rendering rejection.

18 native export jobs were run, plus five invalid-input cases. The 0.5 MP batch
contained two photos; failures are recorded per photo. Existing cancellation
behavior was covered in earlier native acceptance and was not retested here.

## Confirmed megapixel defect

The MCP accepts a finite megapixels number from 0.01 to 1000 and passes the value
through the documented LR_size_megapixels setting. Actual native results behave
like integer truncation for the tested fractional values: 1.5 produces the same
size as 1, and 2.5 the same size as 2. Values below 1 failed to render.

Integer MP sizing works. The exact internal cause is not established; this report
does not claim all Lightroom/SDK versions behave identically. The current bridge
checks path and byte size, but does not decode dimensions before reporting a job
completed, so the 1.5/2.5 jobs returned completed despite not honoring the requested
pixel count. These cases must not be advertised as passed sizing validation.

Until fixed, use integer megapixels >=1 or explicit longEdge/shortEdge/width+height.
A follow-up should either restrict and document supported MP inputs or implement
fractional MP through a validated sizing path, then verify decoded output dimensions.
No such code change was made in this verification task.

## Other observations and end state

- The new 2.13 batch settings read and relative preflight paths were also exercised
  on two photos. Full settings and active selection remained unchanged. This is a
  limited read-only smoke test, not exhaustive 2.13 native acceptance.
- All six RAW originals' full raw develop-setting tables remained exactly equal
  to their pre-test baselines. The existing JPEG's settings were unchanged too.
- The original selected set, active photo and module were restored.
- The new virtual copy `MCP 2.14 纵向导出验收` remains for reproducibility. Its rotation
  was reversed. Exact raw-table comparison found only an absent-to-empty-array
  normalization at Look.Parameters.PointColors after Lightroom rendered the new
  copy; all other raw settings matched. This is explicitly recorded rather than
  called an exact full-table restoration.
- New export files remain under `/tmp/lr-export-214-live/exports`. Oversized output
  was intentionally retained. No original file was moved, renamed or deleted.
- Plugin and pre-test catalog backups are under `/tmp/lr-export-214-live`; temporary
  storage is not a permanent backup. The installed plugin is now 2.14.0.
- This session again required the manual Start MCP Bridge Server menu after restart;
  automatic-start reliability remains a separate item.

## Evidence

[Summary with actual paths, dimensions, bytes, hashes and native job results](verification/2026-09-21-export-214/summary.json)

[Exact production request/response receipts](verification/2026-09-21-export-214/receipts.jsonl)

The original output images remain locally in the export directory above; their
bytes were inspected directly. The repository evidence contains measurements and
receipts rather than duplicating every full-size test image.
