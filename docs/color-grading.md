# Color Grading controls

Color Grading highlights and shadows already work through registered numeric
parameters. The SDK retains these names from Split Toning:

| UI control | SDK/MCP parameter |
| --- | --- |
| Highlights hue | SplitToningHighlightHue |
| Highlights saturation | SplitToningHighlightSaturation |
| Shadows hue | SplitToningShadowHue |
| Shadows saturation | SplitToningShadowSaturation |
| Balance | SplitToningBalance |

Global/midtone wheels and highlight/shadow luminance use the existing ColorGrade
names. Balance shifts shadow/highlight influence; it is not a hard luminance
cutoff. ColorGradeBlending controls their overlap.

Example warm highlights and cool shadows (absolute values):

```json
{"settings":{"SplitToningHighlightHue":45,"SplitToningHighlightSaturation":20,"SplitToningShadowHue":220,"SplitToningShadowSaturation":15,"SplitToningBalance":0}}
```

Use this with `lr_apply_settings` for the active photo, or
`lr_batch_apply_settings` for the selection. First call `lr_get_settings` to check
photo-specific availability and parameterKeys. The 2.11 update corrects naming
and documentation; it does not add new sliders or undocumented aliases.

Source: Adobe's [LrDevelopController colorGradingPanel parameter list](https://lrc.mcor.dev/modules/LrDevelopController.html)
(community-hosted API reference copy).

## Validation

Production Lua tests verify all five parameters are mapped to their existing
catalog keys, written and read back; fabricated ColorGradeHighlightHue is rejected
and silent native no-ops fail readback. These use SDK doubles, not rendered pixels.

Native acceptance remains pending: on a disposable virtual copy, save a snapshot,
apply the example, compare the five UI controls and rendered preview, test a batch
with different initial values, then restore the snapshot and verify readback.
No user photos were edited for this implementation's automated tests.
