# Geometry and navigation verification — 2026-09-20

Lightroom Classic **15.2**, main/Python/Fine/Library **2.6.1**, **88 tools**.
**336 automated tests passed.** Existing module files were reloaded after stopping
the bridge; no full Lightroom restart was needed.

## Positive native results

- Right rotation AB → BC, then left rotation BC → AB; observed pixel dimensions
  swapped from 6000×4000 to 4000×6000 and back.
- Custom 4:5 proportions produced 5000×4000 (5:4), preserving the landscape
  orientation as allowed by the tool contract. Original ratio returned 3:2.
- As-shot crop call returned with observed geometry; no independent camera-crop
  target getter is available, so the result is not claimed ratio-verified.
- Crop reset via catalog crop fields cleared bounds to 0/1 and angle to 0,
  restoring the full 6000×4000 frame.
- Exposure reset: 1 → observed native default 0. Transform reset: vertical 10 → 0.
- Created an actual native subject mask on the test copy, enumerated it, reset
  masking, then confirmed both the catalog reset and empty native mask list.
- Red-eye reset was a no-op case on a photo without red-eye regions. Positive
  removal is covered by production Lua tests, not a native red-eye sample.
- Enumerated the catalog folder and its 11 current photos; paged folder listing
  with includeChildren succeeded.
- Folder-source and All Photographs source switching were read back correctly.
- First/next/previous/last navigation changed the native active UUID as expected;
  select-all returned 11 photos and inverse returned zero selection.
- Grid, loupe, Develop loupe and horizontal before/after view requests reached the
  expected module. Main view identity is not independently read back by the SDK.
- Attribute/rating filter patching, Filters Off preset application, and noLabel
  changes were retained. Original filter values were subsequently restored.

## Fixes found during native validation

The native controller resetCrop method returned without clearing this crop. The
implementation now writes only CropTop/Bottom/Left/Right, CropAngle and HasCrop
under catalog write access, and verifies the resulting bounds/angle.

Calling getRawMetadata from table.sort's comparator raised a Lua yield error.
Folder photo UUIDs are now resolved before sorting; the comparator uses plain
strings only. A regression test rejects metadata calls inside comparators.

The actual filter key is noLabel, despite lowercase nolabel in some SDK reference
text. The schema and native handler now use the observed key.

## Recovery

Original photo: `6A644F6A-E754-4788-A73E-6D7B1C03CAC6`.
Retained test virtual copy: `3E6469EC-5C95-4BB2-928A-2931C08D68DD`, named
`MCP 旋转裁剪导航验证`.

The saved snapshot restored the complete raw develop settings with zero differing
keys. Orientation independently returned to AB; the test mask was removed. The
temporary snapshot was deleted only after restoration comparison. Original raw
settings, filter values, active sources and selection were checked after returning
to the original photo and Library grid view. Baselines and calls are retained in
`/tmp/lr-navigation/`.

The Mac initially being locked delayed deployment; it was manually unlocked before
any native test mutations. No original image file was moved or rewritten by this
batch.
