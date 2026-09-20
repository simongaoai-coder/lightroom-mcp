# Appearance controls verification — 2026-09-20

Lightroom Classic **15.2**, main/Python/Fine **2.5.1**, **77 tools**.
**308 automated tests passed**. The existing Lua module was reloaded; no full
Lightroom restart was needed for this feature.

## Live checks

- Native color → grayscale → color switching, with treatment readback.
- All eight named WB modes: As Shot, Auto, Daylight, Cloudy, Shade, Tungsten,
  Fluorescent and Flash. All retained their requested modes on the RAW test copy.
- Auto/As Shot responses no longer present stale stored catalog values as effective
  temperature/tint. Custom remains available through existing numeric settings.
- 252 profile configurations enumerated from the current photo and SDK-visible
  presets on this installation. This is not 252 distinct installed profiles.
- Adobe Landscape, Adobe Portrait and Adobe Standard applied. Immediate raw
  comparisons showed only Look changed; top-level exposure, WB and curves were
  not taken from the source presets.
- B&W 01 extracted from the B&W Punch preset applied with grayscale treatment.
  A native JPEG thumbnail was visually confirmed monochrome.
- The original photo's Adobe Color configuration was reused on the test copy.
  Treatment returned to color and a native thumbnail visibly showed color again.
- Source configuration guards, camera/file-class restrictions, rendered-photo WB
  restrictions, missing APIs, catalog/selection changes, lock failure, silent
  no-ops, profile-only isolation and preset errors are covered by production Lua
  tests. Rendered JPG/TIFF and different-camera compatibility were not live-tested.

## Recovery and limits

Original: `6A644F6A-E754-4788-A73E-6D7B1C03CAC6`.
New retained test virtual copy: `0345CEBC-483F-432E-A931-A487AE28DC46`, named
`MCP 外观功能验证`.

The snapshot restore did not by itself fully restore the test copy: WB remained
As Shot, numeric values differed, and process version was 15.4 instead of 11.0.
WB values were explicitly restored using the existing numeric API; the native
Settings → Process Version → Version 5 menu restored the process version.
A final complete raw-settings comparison found **zero differences** from the
copy's baseline. The original likewise had zero differences. The temporary
appearance snapshot was removed. The original selection/Library view was restored.

This demonstrates why snapshot-call completion and immediate profile readback
must not be represented as independent proof of final render/state restoration.
The current tools expose observed results and fail readback mismatches; no raw
unrestricted settings writer was introduced.

Local baselines, detailed calls and color/B&W previews are in `/tmp/lr-appearance/`.
Remove parameter/movement investigation is separate and remains unresolved in the
product; no new Remove behavior is claimed by this release.
