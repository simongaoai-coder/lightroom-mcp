# Fine editing (2.2)

Phase 3 adds twelve tools (38 total) and four local numeric sliders. Main plugin and
Fine are 2.2.3; Masking is 2.2.2, Develop is 2.0.0 and Versions is 2.1.1.
Protocol remains 2. All new tools accept optional `expectedPhotoId`.

## Tools

| Tool | Purpose |
| --- | --- |
| `lr_combine_mask` | Add/subtract/intersect a new component on an explicit mask |
| `lr_set_mask_visibility` | Set a mask or child tool's hidden state idempotently |
| `lr_invert_mask` | Invert a whole mask once |
| `lr_duplicate_inverted_mask` | Duplicate and invert a mask; identify the new mask |
| `lr_set_mask_tool_inverted` | Set a child's inversion state idempotently |
| `lr_auto_white_balance` | Native automatic white balance with observed mode/values |
| `lr_get_curve` / `lr_set_curve` | Read/write global or mask RGB/channel point curves |
| `lr_list_point_colors` | Read global or mask point-color swatches |
| `lr_add_point_color` | Add a source-color swatch, or report existing selection |
| `lr_update_point_color` | Update a guarded swatch index, preserving other fields |
| `lr_delete_point_color` | Delete one guarded swatch and verify the remaining list |

`lr_update_mask`, `lr_add_mask` and `lr_get_selected_mask` additionally support
`Hue`, `Amount`, `Grain`, and `RefineSaturation`. Numeric writes retain dynamic SDK
range checks, explicit mask targeting and readback. Availability depends on the
photo, process version and runtime APIs; unsupported sliders fail before writing.

## Mask composition and state

`lr_combine_mask` requires `maskId`, `operation` (`add`, `subtract`, `intersect`)
and `maskType` (the existing creation types). It invokes the corresponding native
SDK component-creation operation. This is not an arbitrary merge of two existing
mask IDs, and it does not accept geometry or brush paths.

Subject/sky/background components are polled for newly appearing child IDs on the
specified mask. The response is `component_created` or `pending`, with
`newToolIds`. Interactive types return `awaiting_user_input`; finish drawing or
sampling in Lightroom. The temporary absence of a selected mask ID during AI
processing is tolerated; a different nonempty ID still stops the operation.
Component existence is not a pixel-coverage or segmentation-quality guarantee.

Visibility takes explicit `hidden: true/false` and optional `toolId`. Child inversion
takes both IDs and `inverted: true/false`. Both compare the SDK's state before
calling its toggle function, so repeating an already-satisfied request does not
flip it back. Unknown state is rejected. A child must belong to the specified mask.

Whole-mask inversion is an inherently non-idempotent action. It reports SDK
completion, not independent pixel-level verification. Duplicate-and-invert returns
a new `maskId` when exactly one can be identified; otherwise it reports pending or
an explicit ambiguity. Do not blindly repeat an uncertain action. Batch mask
operations, arbitrary brush geometry and pixel-mask export are outside this phase.

## Point curves

`channel` is `rgb` (default), `red`, `green` or `blue`. Omit `maskId` for a global
curve; provide it to target a specific mask. Local tools never implicitly target a
manually selected mask when the ID is omitted.

`points` is an array of 2-32 `[x,y]` pairs in 0-255 coordinates. The x values must
strictly increase, starting at 0 and ending at 255; y must also be between 0 and
255. Curves can lift black or lower white and need not have monotonically increasing
y values. For example: `[[0,0],[64,54],[128,138],[255,255]]`.

Global curves use catalog develop settings; local curves use the selected mask's
controller curve parameters. Existing native 0-1 or 0-255 arrays are recognized,
normalized for the MCP interface and converted back on write. Unknown SDK layouts
fail rather than being overwritten. Responses return the actual readback points
and native scale; a mismatched/no-op write is an error. RGB channel control does
not imply support for every legacy process version or every future curve format.

## Point colors

Omit `maskId` for global point colors, or supply an explicit mask ID for local
point colors. The relevant point-color tool is opened in Develop. Source swatches
use the native SDK's units:

- `SrcHue`: 0-6; `SrcSat` and `SrcLum`: 0-1 (all three required for creation).
- `HueShift`, `SatScale`, `LumScale`: -1 to 1.
- `RangeAmount`: 0-1.
- `HueRange`, `SatRange`, `LumRange`: optional objects containing `LowerNone`,
  `LowerFull`, `UpperFull`, `UpperNone`, each 0-1.

List output includes `swatches` and a 1-based `selectedIndex` when present.
`readState: unavailable_or_uninitialized` means the native getter returned nil;
the accompanying empty array is not proof there are no stored swatches. Updates
and deletions require an available list. A documented add can initialize it, but
its result is read back before success is reported.

To update/delete, pass `index` and the exact `expectedSwatch` object from the last
list/readback. If the swatch or index has changed, the request fails as
`swatch_changed`; there is no fallback to another swatch. Update takes `changes`
and preserves unspecified native fields (including fields not exposed for editing).
After a successful update, use the newly returned object for subsequent operations.

Creation may select an existing source color rather than create another swatch.
`existing_selected` does not claim requested adjustments were applied. If the
previous list was unavailable, `added_or_selected` identifies the resulting swatch
without asserting it is new and reports `requestedValuesMatch`. Inspect the
response or call update explicitly. Deletion removes one index only; there is no
implicit delete-all behavior. Result comparison tolerates small numeric SDK
rounding while checking the whole swatch/list structure. After deleting the last local swatch, a nil getter
is accepted as empty only when the matching mask's `LocalPointColors` catalog field
was present with the correct count before deletion and is absent/empty afterward.
This returns `verification: sdk_and_catalog_empty`. A nil getter alone never proves
deletion. The native selected index can linger after deletion; use the returned
swatch list and expectedSwatch guard to choose any subsequent target.

## Automatic white balance and verification

`lr_auto_white_balance` calls the native automatic operation. It waits for Auto
mode and finite controller Temperature/Tint values; raw catalog settings alone can
omit these values during calculation. It returns the observed mode and values,
not a claim that auto white balance is aesthetically correct for the image.

All writes retain photo identity checks. Local controls also check the active mask.
SDK exceptions, unavailable APIs, malformed data and readback mismatches are
explicit failures. A failure after mutation does not promise rollback. Save a
snapshot (phase 2) or use a virtual copy before experimenting. The suite exercises
production Lua under SDK doubles; real acceptance is recorded separately.

When deploying, stop the existing MCP Bridge Server before reloading the plugin,
then start it again and check versions. If old mixed-version tasks remain, fully
exit Lightroom and confirm the old process has ended before reopening. The version handshake
blocks requests serviced by a mismatched old task. Reconnect the MCP client to load
the new schemas. No license or account requirement is bypassed by these tools.

Reference: Adobe's [LrDevelopController API reference mirror](https://lrc.mcor.dev/modules/LrDevelopController.html)
for masking, point-color swatches and Auto White Balance; the bundled SDK Guide and
[LrPhoto reference](https://lrc.mcor.dev/modules/LrPhoto.html) for catalog develop settings.
