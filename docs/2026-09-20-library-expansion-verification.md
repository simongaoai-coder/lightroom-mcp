# Library expansion verification — 2026-09-20

Lightroom Classic **15.2**, main/Python/Library **2.9.0**, **104 tools**.
**391 automated tests passed**. Existing Lua files were reloaded after stopping
old service; no full application restart was required.

## Native checks

- Exact camera model ILCE-7M3 and lens E 28-75mm F2.8-2.8 searches each matched
  all 14 pre-test photos. ISO 1–10000000 and hasAdjustments=true also returned 14.
- hasGPS=false returned 14; cropped=false returned 13; landscape and color each
  returned 14. These are observations on this test catalog, not universal counts.
- OR of an existing filename and a nonexistent filename returned 9. Combining that
  filename with exclusion of a nonexistent camera also returned 9. Excluding that
  filename returned the complementary 5 photos.
- A smart collection with nested OR and exclusion was created; its SDK search
  description matched the compiled descriptor. It was removed after testing.
- Existing unused phase-4 test keyword 16394 was moved to root and back under
  16392. Synonyms were changed with ignoreCase=true, read back, then restored.
  Exact-keyword photo lookup and descendant union each found the one assigned
  temporary copy. The assignment was removed afterward.
- Collection set and standard collection reparenting succeeded. Moving a parent
  into its child was rejected as hierarchy_cycle. All temporary collection nodes
  were deleted after testing.
- Current native target collection was Quick Collection. Toggling the test copy
  produced ordinary collection membership [] → [7] → [], and target-source
  navigation observed quick_collection. No target-designation setter is claimed.
- The new virtual copy was renamed and read back. Original-photo removal and an
  incorrect expected-master UUID were rejected before removal. The correct request
  removed exactly the test copy; the original still resolved in the catalog.
- Metadata preset enumeration was initially empty. A temporary preset was created
  through Lightroom's UI with only Caption checked. The SDK enumerated its UUID,
  and apply_metadata_preset changed Caption to the test value while observed rating
  and copyName remained unchanged.

## Cleanup / restored state

Original: `6A644F6A-E754-4788-A73E-6D7B1C03CAC6`.
Temporary virtual copy: `C12C8C27-3A36-4595-BFCF-A299075E1C49` — removed after tests.
Temporary collection IDs 16819, 16821, 16823, 16825 — all deleted.
Existing phase-4 keyword definitions 16392/16394 were restored exactly, including
parent, synonyms and export attributes. No new keyword definitions were needed.

All 14 pre-existing photos' supported metadata fields and keyword associations were
compared to their saved baselines: **zero differences**. The original photo's raw
develop settings were unchanged. Original Library grid selection, active sources
and view filter were restored and compared.

The temporary metadata preset `MCP Metadata Verification 2.9`, UUID
`3E64ADE9-58E5-4234-833C-535AFF06EDF3`, is currently retained. Lightroom explicitly
warned its deletion cannot be undone; the user was asked for the required action-
time confirmation. The deletion was cancelled and the editor closed to avoid
blocking the application while awaiting the answer. Do not report it as deleted.

Local records are in `/tmp/lr-library-expansion/`. Preset readback only covers known
metadata fields; the preset's complete field selection is not enumerable through
this SDK. Tests of manual concurrent changes, every camera/format, and personal
keyword types are not claimed. No original image file was moved or deleted.
