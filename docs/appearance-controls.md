# Treatment, white-balance modes and profiles (2.5.1)

Five tools extend the bridge to **77 tools**. Main/Python and Fine are **2.5.1**;
other modules retain their independent versions. These commands target the current
photo and accept `expectedPhotoId` / `expectedCatalogPath`. Videos are rejected.

| Tool | Inputs / purpose |
| --- | --- |
| `lr_get_appearance` | Read treatment, white-balance mode and native profile settings |
| `lr_set_treatment` | `treatment`: `color` or `grayscale` |
| `lr_set_white_balance` | `mode`: `As Shot`, `Auto`, `Daylight`, `Cloudy`, `Shade`, `Tungsten`, `Fluorescent`, `Flash` |
| `lr_list_profiles` | Profile configurations observed on photos and in SDK-visible presets |
| `lr_set_profile` | Explicit `profileId` and exact `expectedProfile` from the list |

## Black and white / white balance

Treatment uses `photo:quickDevelopSetTreatment`, followed by readback of
`ConvertToGrayscale`. Lightroom may also change the associated profile.
White-balance lighting presets and Auto use `photo:quickDevelopSetWhiteBalance`.
As Shot uses `photo:applyDevelopSettings` under catalog write access. Lighting
presets are restricted to RAW/DNG; rendered photos may use As Shot or Auto.
For Custom, use the existing `lr_apply_settings` temperature/tint controls.

These are SDK-native operations; Quick Develop calls are not wrapped in a catalog
write gate. Catalog writes are gated. Every wait/write rechecks the target photo
and catalog. Rejection, timeout and silent no-op are errors; don't retry a mutation
blindly. No batch-selection mutation is performed by these five tools.

`whiteBalance` is the observed mode. `storedTemperature` and `storedTint` expose
catalog values, which may be stale or absent under As Shot / Auto. In those modes,
`temperature` / `tint` are omitted and `whiteBalanceValuesSource` is
`catalog_stored_not_resolved`. Other modes report the stored numeric values, with
RAW/DNG `kelvin` versus rendered-file `relative` units. This endpoint does not
switch modules merely to resolve display sliders.

## Profile scope and identity

There is no documented complete installed-profile enumeration API used here.
`lr_list_profiles` enumerates **observed configurations**, not all profiles from
the Lightroom profile browser. It returns `completeInstalledList: false` and
`coverage: observed_photos_and_sdk_presets`.

- Photo sources default to the current photo. `sourcePhotoIds` may specify 1–50
  distinct photo UUIDs in the current catalog.
- `includePresets` defaults to true. Preset candidates come from the public SDK
  develop-preset folders; hidden plugin-owned presets are not included.
- `query` searches the profile and source names literally, case-insensitively.
  `offset` defaults to 0 and `limit` to 50 (maximum 200).
- Multiple presets may reference the same profile. Their configurations can differ;
  use the returned IDs and payloads, not names as unique identifiers.
- Presets that cannot be read are returned in `presetErrors`; they are not silently
  represented as valid candidates.

`profileId` identifies `photo:<UUID>` or `preset:<UUID>`. `expectedProfile` guards
against a changed source. The server re-reads the source; it never writes arbitrary
client-provided profile data. Only `CameraProfile`, `CameraProfileDigest`, `Look`
and associated `ConvertToGrayscale` are copied. If a preset omits treatment but
its `Look.Parameters` explicitly declares it, that value is included. An absent
Look clears the previous creative profile. The entire preset is never applied:
top-level exposure, tone curves, masks and white balance are not copied.

RAW photo sources require matching known camera make/model and RAW/rendered class.
Camera-specific preset profiles are rejected unless their camera-profile name
already matches the target; use a matching-camera photo as the source instead.
RAW-only profiles are rejected on rendered targets. These are conservative checks,
not proof that every installed profile works with every photo or Lightroom version.

Profile application requires catalog write access and observed profile/treatment
readback. `verification: catalog_readback` means settings persisted, not exhaustive
pixel verification. Lightroom can normalize profile data and processing version
later while rendering; inspect `lr_get_settings(includeRaw=true)` when that matters.
Returned `changedKeys` describes the settings observed during the call, not a promise
that no later native normalization will occur.

## Example workflow

1. Save a snapshot and get the current appearance.
2. List profile candidates with a query such as `Adobe Landscape`.
3. Apply the chosen `profileId` and its exact `expectedProfile`, with photo/catalog
   guards. Read the appearance and preview the photo.
4. Use `lr_set_treatment` for explicit color/B&W selection, and
   `lr_set_white_balance` for named modes.

Snapshot invocation alone is not proof of restoration. Compare readback with the
saved baseline. During this validation one restore left white balance/process
version differences, which were corrected and independently verified.

## Sources and validation

- [Adobe SDK LrPhoto reference (community-hosted rendering)](https://lrc.mcor.dev/modules/LrPhoto.html)
- [Adobe SDK LrApplication reference (community-hosted rendering)](https://lrc.mcor.dev/modules/LrApplication.html)
- [Adobe SDK preset settings caveat](https://lrc.mcor.dev/modules/LrDevelopPreset.html#preset:getSetting)
- [Native verification record](2026-09-20-appearance-verification.md)

SDK develop-settings tables are experimental and can change between versions.
Automated tests cover the actual production Lua plus schema/IPC behavior. Mocks
alone do not prove profile compatibility or rendering.
