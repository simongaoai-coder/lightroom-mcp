# Export sizing, JPEG size limits and naming (2.14.0)

Main/Python/Delivery are 2.14.0. The existing lr_export_photos tool is extended;
the total stays at 112 tools. Plugin and MCP process must be updated together.

## Resize modes

Specify **at most one** of these modes. Omit all to export without a pixel-size
constraint. All dimensions refer to the rendered, edited/cropped image.

| Arguments | Meaning |
| --- | --- |
| longEdge: 2400 | Limit the longer edge to 2400 pixels; existing option preserved |
| shortEdge: 1080 | Limit the shorter edge to 1080 pixels |
| width: 1600, height: 1200 | Fit within this width/height bounding box, preserving aspect ratio |
| megapixels: 4.5 | Resize using Lightroom's native megapixel option |

Pixel arguments are integers 1-65000; megapixels is a finite number 0.01-1000.
Width and height must appear together. Modes cannot be combined. These are tool
bounds, not a guarantee every dimension/file is renderable by every SDK version.

`doNotEnlarge` stays true by default. A smaller source can therefore remain smaller
than the requested dimensions/megapixels. Bounding-box sizing does not crop, stretch
or promise an exact width AND height. `resolution` remains DPI (default 240) and
is separate from pixel dimensions. Native SDK keys are LR_size_resizeType,
LR_size_maxWidth/maxHeight and LR_size_megapixels; long/short-edge bounds use
maxHeight as documented, regardless of source orientation.

## JPEG maximum file size

```json
{"destination":"/absolute/output/folder","longEdge":2400,"maxFileSizeKB":500}
```

`maxFileSizeKB` is JPEG-only, integer 1-1048576. In this tool **1 KB = 1024 bytes**.
It is mutually exclusive with explicit `quality`. Lightroom's native size-limited
renderer chooses JPEG quality through LR_jpeg_useLimitSize/LR_jpeg_limitSize.
Without a size limit, fixed quality remains 90 by default, or the requested 1-100.
TIFF continues to support 8/16 bits and does not support this JPEG size limit.

The bridge checks the actual completed file length. Each size-limited result
includes bytes, maxBytes and sizeLimitMet. An oversized rendition is a per-photo
failure with code=file_size_limit_exceeded; its path and bytes are retained and
its file is left available for inspection. A native rendering failure (for example,
an unachievable limit) is reported as render_failed. Other photos continue under
the existing batch policy. No automatic downsizing, repeated compression or file
cleanup hides such failures.

## Naming

Optional `naming` is an object:

| Field | Options/default |
| --- | --- |
| mode | original, original_sequence (default), custom_sequence |
| customText | Required only for custom_sequence; literal prefix, not a path/template |
| sequenceStart | 1 by default; integer 1-999999999 |
| sequenceDigits | Minimum padding width 1-5, default 4 |
| extensionCase | lowercase (default) or uppercase |

- Default names remain `<original stem>-0001.jpg`, `...-0002.jpg`, etc.
- `original` retains the source stem with the export format's extension. Sequence
  options and customText are rejected in this mode.
- `original_sequence` adds the configured sequence to the original stem.
- `custom_sequence` uses `<customText>-<sequence>` for every target.
- Sequence values follow captured target order, increment once per target and do
  not reset across the one-photo native export sessions. Failed targets may leave
  gaps. Overflow beyond 999999999 is rejected before creating the batch directory.
- customText is at most 200 UTF-8 bytes. Path separators, control characters,
  reserved filename punctuation, braces/template tokens, and trailing dot/space
  are rejected. Unicode names such as Chinese prefixes are supported.
- Only documented native image_name/custom_token/sequenceNumber tokens are emitted.
  No arbitrary native token expression or export preset file is executed.

```json
{
  "destination":"/absolute/output/folder",
  "photoIds":["uuid-a","uuid-b"],
  "width":1600,
  "height":1200,
  "maxFileSizeKB":500,
  "naming":{
    "mode":"custom_sequence",
    "customText":"旅行精选",
    "sequenceStart":10,
    "sequenceDigits":3,
    "extensionCase":"uppercase"
  }
}
```

This requests 旅行精选-010.JPG and 旅行精选-011.JPG within the job's unique folder.
Actual names can differ if Lightroom resolves a collision. Existing collision
handling remains **rename**, never overwrite. Poll lr_get_export_status for actual
paths; no source file is renamed and no exported file is automatically reimported.

## Job results and validation

Job status now reports normalized resize/naming options, plus maxFileSizeKB when
limited or quality when using fixed JPEG quality. The original job lifetime,
progress, per-photo failure and cancellation-between-photos behavior is preserved.
The output parent is still canonicalized and checked against the unique batch
folder, and output files must be readable/nonempty.

Python schema/semantic checks reject invalid combinations before IPC. Production
Lua repeats validation before creating a folder or scheduling work. Tests cover
all resize mappings, sequence continuity, Unicode/unsafe names, collision handling,
unchanged defaults, and actual byte-limit boundaries (including retained oversized
files), plus isolated IPC contracts. The SDK double does not render real images.

**Native 2.14 validation is pending**: verify actual landscape/portrait dimensions,
doNotEnlarge, megapixel rounding, custom names/extension case and achievable versus
impossible JPEG limits on Lightroom. No live catalog was modified for this change.
The plugin verifies output path/bytes, not decoded image dimensions or ICC contents.

Source: bundled Adobe *Lightroom Classic SDK Programmers Guide*, pp. 61-63 and
66-67 (naming and size/quality properties). The documented size limit is a native
quality-control target; the additional byte-length check enforces this tool's
reported successful-output cap.
