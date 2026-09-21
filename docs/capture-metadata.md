# Shooting metadata (2.10.0)

`lr_get_metadata` now reads the shooting metadata exposed by the documented
Lightroom Classic SDK. This is catalog metadata, not a complete EXIF/MakerNote
parser for the original file. No new MCP tool is added (104 tools total).

```json
{"fieldGroup":"capture"}
```

Use `scope: "selected"` or `photoIds: ["uuid", "uuid"]` for a batch of at most 200
photos. Existing expectedPhotoId / expectedCatalogPath guards still apply.
This read does not select photos, switch modules, or write metadata/image files.

Choose either explicit `fields` or `fieldGroup`, never both:

- `basic`: existing default fields (rating, pickStatus, colorNameForLabel, title,
  caption, creator, copyright). Omitting both options keeps this default.
- `capture`: all fields in the table below.
- `all`: all supported read fields, including existing descriptive metadata.
  This means the tool's whitelist, not every field in the SDK or file.

| Fields in capture | Returned representation |
| --- | --- |
| cameraMake, cameraModel, cameraSerialNumber, lens | SDK display strings; serial numbers retain leading zeroes |
| shutterSpeed | Number, seconds (1/125 = 0.008) |
| aperture | Number, f-number (2.8 means f/2.8) |
| isoSpeedRating | Number, ISO |
| focalLength, focalLength35mm | Numbers, millimeters |
| exposureBias | Number, EV |
| flash | Boolean: false means did not fire; absent means unknown |
| exposure, brightnessValue, exposureProgram, meteringMode, subjectDistance | SDK display strings; may be localized, never parsed into numbers |
| artist, software | SDK display strings |
| dateTimeOriginal, dateTimeDigitized, dateTime | SDK numbers: seconds since 2001-01-01 00:00:00 UTC, not Unix timestamps |
| dateTimeOriginalISO8601, dateTimeDigitizedISO8601, dateTimeISO8601 | SDK ISO 8601 strings, unchanged; no timezone is inferred or appended |
| gps | Object with latitude and longitude in degrees |
| gpsAltitude, gpsImgDirection | Numbers, meters and degrees respectively |
| fileFormat | SDK format string |
| fileSize | Bytes; SDK may report smart-preview size when the original is offline |
| dimensions, croppedDimensions | Objects with width/height in pixels |
| width, height, aspectRatio, isCropped | Original pixel dimensions, SDK width/height ratio, crop Boolean |
| bitDepth | Number; introduced in SDK 12.1, may be unavailable on older versions |

Example of a smaller, typed request:

```json
{"fields":["shutterSpeed","aperture","isoSpeedRating","focalLength","flash","dateTimeOriginalISO8601"]}
```

Each photo retains its summary and keyword list, plus:

- `metadata`: returned values, preserving zero, false and empty strings.
- `missingFields`: requested fields for which the SDK returned nil (not applicable
  or not recorded). Values are not guessed from the camera model or filename.
- `fieldErrors`: present only when getters throw; each entry contains `field`,
  `code: "metadata_read_failed"`, and `error`. Other fields/photos still return.
  A failed getter is not reported as a missing value. Top-level success indicates
  that the request completed; inspect fieldErrors for partial reads.

Unknown field names remain invalid arguments. All newly added fields are read-only;
existing metadata writers and their whitelist are unchanged. Catalog changes or
selection changes covered by the existing guards still fail the request.

Source: Adobe's [LrPhoto API Reference](https://lrc.mcor.dev/modules/LrPhoto.html)
(community-hosted copy), getRawMetadata and getFormattedMetadata. Prefer the ISO
8601 fields for dates, as recommended by the SDK. Display strings are suitable for
presentation but not locale-independent numeric calculations.

## Validation

Production Lua is exercised through the Lua 5.1 SDK double, covering getter
routing, numeric/Boolean preservation, missing values versus SDK exceptions,
field groups, Python/Lua field parity, batch reads and rejection of writes.
Python tests exercise schema validation and isolated file IPC. These tests do not
establish native behavior on every camera, file format or Lightroom version.
No live catalog was modified or used for acceptance testing for this feature.

To validate after deployment: reload the matching 2.10.0 plugin and restart the
MCP client, check lr_ping versions, then read capture metadata from a RAW, a JPEG
with stripped EXIF, and selected mixed photos. Compare to Lightroom's Metadata
panel; verify absent fields and false-valued flash are distinguished. This is a
manual acceptance checklist, not a claim of completed native verification.
