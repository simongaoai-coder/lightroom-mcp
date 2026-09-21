# Fractional megapixel fix — 2.14.1

**Result: PASS on the tested Lightroom Classic 15.2 runtime.**

The 2.14.0 native MP route truncated fractional requests and failed below 1 MP.
2.14.1 resolves each request into an integer-pixel long edge from SDK numeric
croppedDimensions, then uses the native long-edge renderer. It does not change
crop/settings or post-process the resulting image with another imaging engine.

Formula: round(sqrt(requestedMP × 1,000,000 × longerCropEdge / shorterCropEdge)).
The ratio is orientation-independent. With doNotEnlarge enabled, cap the computed
edge at the cropped source long edge. Invalid/missing crop dimensions or a derived
edge outside 1-65000 fail explicitly. The whole batch is preflighted before a
folder is created; dimensions are reread before each photo's render. Per-photo
results expose effectiveResize separately from the requested job.resize.

Integer pixel rounding means a target can be slightly above or below the requested
pixel count. A source-size cap can produce fewer pixels. The effectiveResize record
is planning metadata, not a claim of independent decoding inside the plugin.

## Automated validation

**629 tests passed**, including fractional/sub-1 MP, landscape/portrait metadata,
square crops, no-enlargement/enlargement, changed cropping after submission,
invalid dimensions and derived-edge overflow. Existing non-MP export modes,
quality/size limits, naming and collision handling remain covered.

## Native validation

Installed and hash-verified main/Python/Delivery 2.14.1; 112 tools. Real exports
were decoded with Pillow and EXIF orientation applied before dimension checks.
No mock output was used for these measurements.

| Target | Landscape | Portrait | Landscape actual MP |
| --- | --- | --- | --- |
| 0.01 MP | 122×81 | 81×122 | 0.009882 |
| 0.5 MP | 866×577 | 577×866 | 0.499682 |
| 0.9 MP | 1162×775 | 775×1162 | 0.900550 |
| 1 MP | 1225×817 | 817×1225 | 1.000825 |
| 1.5 MP | 1500×1000 | 1000×1500 | 1.500000 |
| 2 MP | 1732×1155 | 1155×1732 | 2.000460 |
| 2.5 MP | 1936×1291 | 1291×1936 | 2.499376 |
| 4 MP | 2449×1633 | 1633×2449 | 3.999217 |

Additional native cases:

- Square-cropped virtual copy, 1.5 MP: 1225×1225.
- 2:1 cropped virtual copy, 1.5 MP: 1732×866.
- 1400×933 JPEG, 2.5 MP with default no-enlargement: stayed 1400×933 and
  effectiveResize.limitedBySource=true.
- Same JPEG with enlargement enabled: 1937×1291, near 2.5 MP.
- TIFF 1.5 MP: 1500×1000.
- 0.9 MP plus a 100 KB JPEG cap and custom naming: 小数修复-007.JPG,
  1162×775, 98,611 bytes (below 102,400 bytes).

All **14 export jobs / 22 decoded images** completed. Each uncapped MP result
was within a pixel-rounding tolerance, checked as abs(actualPixels − requestedPixels)
<= 2×(outputWidth + outputHeight)+4. This specifically rejects the old 1.5→1 MP
and 2.5→2 MP behavior; very small outputs naturally have larger relative rounding.

A single existing, named test virtual copy was rotated/cropped for the portrait
and crop cases, then restored from a newly saved baseline snapshot. All six original
RAWs, that virtual copy and the existing JPEG had zero full raw-setting differences
afterward. Initial selected set, active photo and module were restored. Output
files remain under `/tmp/lr-mp-fix-live/exports`; original files were not modified.

The first startup was unresponsive before any photo operation; after terminating
that confirmed unresponsive process and restarting/activating Lightroom in Library,
the full native run succeeded. This does not establish a fix for general app/Bridge
startup reliability. Prior catalog/plugin backups remain in `/tmp/lr-mp-fix-live`.

[Measured results and restoration](verification/2026-09-21-mp-fix/summary.json)

[Exact production request/response receipts](verification/2026-09-21-mp-fix/receipts.jsonl)
