# Native acceptance fixes — 2.12.2

**Final core native regression: PASS after the user restarted Lightroom.**
The remaining ordinary Clone-stroke interaction is awaiting user drawing; the
manual gradient cycle is complete. This is not exhaustive validation of all 111 tools.

Fixes the two defects recorded in [2.12.0 native acceptance](2026-09-21-live-acceptance.md).
Main/Python/Batch/Styles are 2.12.2; the tool count remains 111. Fine remains 2.8.0
and Develop remains 2.12.0. The final plugin files were deployed and hash-checked.

## Saved styles preserve unselected white balance

Verified plugin styles now apply a cloned selection manifest with
LrPhoto.applyDevelopSettings under catalog write access. Native plugin presets
remain the persistent storage/enumeration format, but their native whole-preset
application path is not used for saved styles. Ordinary user presets retain their
native application and amount behavior.

Readback checks selected fields and protected unselected process version, WB,
exposure, crop, orientation, treatment and profile fields. Custom WB temperature/
tint must stay unchanged when omitted. Auto/As Shot numeric WB values may be
recomputed; their mode is checked. Unexpected protected changes are explicit
unselected_settings_changed failures. No automatic rollback is performed.
Missing plugin manifests fail with style_manifest_missing; they do not silently
fall back to the native preset path which caused the side effect.

Native evidence: the corrected style path was exercised on the same previously
failing preset and virtual copy during the 2.12.1 development build. All 21 selected
fields matched; omitted Custom WB stayed 4750 K / tint 10, with exposure/crop/profile
unchanged and the active non-target photo unchanged. Baseline restoration was exact.
The same style path has now passed on the final 2.12.2 build as well, after the
user restarted Lightroom. The 21 selected fields and protected values were checked
again; an unrelated active test photo retained its complete settings.

## Quick Develop batches isolate the UI target and restore selection

Black/white treatment and named WB (except the existing catalog-backed As Shot
path) retain the native Quick Develop calls so Lightroom computes their actual
rendering behavior. Before each native call, temporarily select exactly the target
photo and verify both active photo and complete selected set. Stop before the call
if the target cannot be selected. Sources/filters are not changed to force visibility.

The original active photo and multi-selection are restored on success and failure.
If manual selection changes are detected, stop without overwriting the user's new
selection. Report selectionRestored/selectionRestoreError separately from per-photo
write results. A failed restore cannot be reported as overall success.

This is an intentional correction to the 2.12.0 claim that these UI-bound calls
could execute without selection changes. Numeric edits, styles and rotation still
use photo objects without switching selection.

A catalog-only named WB mode write was rejected during development: Daylight read
back as a label while an actual native JPEG export remained pixel-identical to the
Custom baseline (RGB mean delta 0, stored temperature unchanged). Consequently the
final implementation uses guarded native Quick Develop, not label-only writes.

## Verification

- First updated the SDK double to reproduce both native behaviors: selective native
  preset application corrupts omitted WB, and Quick Develop changes the active UI
  photo regardless of the receiver object. Original code failed these regressions.
- **513 automated tests passed** on the final 2.12.2 source.
- Coverage includes Custom/As Shot/Auto WB preservation, explicit WB inclusion,
  protected-field side effects, missing manifests, native user preset amounts,
  offscreen targets, full original multi-selection restoration after partial
  failure, unselectable targets, no-active-photo restoration, and concurrent user
  selection changes.
- `git diff --check` passed.
- An earlier final-build attempt was blocked by **Cannot apply develop settings
  unless Lightroom is licensed** and UI unresponsiveness. After the user restarted
  Lightroom, the final-build checks below passed. No licensing bypass was attempted.
- All three verification copies were restored and compared to their full raw SDK
  baselines after the interrupted run; all differences were empty. Original active
  selection was restored. No additional raw originals were edited for this fix.

Evidence: [2.12.1 corrected style-path observation](verification/2026-09-21-fixes/fix-2.12.1.json),
[rejected mode-only WB render probe](verification/2026-09-21-fixes/render-fix-result.json),
[final native rerun and restoration](verification/2026-09-21-fixes/fix-2.12.2.json).

## Completed final native checks after user restart

- Real MCP stdio: Python/plugin **2.12.2**, **111 tools**, compatible=true.
- Existing saved style: 21 selected fields retained, omitted Custom WB stayed
  4750 K / tint 10, omitted exposure/crop/profile unchanged, unrelated active photo
  unchanged. No new style or user preset modification was needed.
- Explicit offscreen target: grayscale, color, Daylight, Auto and As Shot succeeded.
  Each call restored the original active photo; full non-target settings stayed
  equal to their pre-call state. Daylight resolved to 5500 K / tint 10.
- Two-target batches: grayscale and Daylight completed for both targets, while a
  third unrelated active photo retained its settings and active status.
- Original multi-selection: two-photo selection with a specific active photo was
  restored exactly after changing a third, initially unselected photo.
- Native JPEG export: Daylight versus Custom baseline produced mean absolute RGB
  pixel differences of **11.3835 / 0.8697 / 9.5058** (8-bit scale). This confirms an
  actual rendered change, unlike the rejected label-only write approach.
- Native B&W JPEG export: mean R/G and R/B differences were **0.4040 / 0.2044**,
  below one level on the 8-bit scale. This is a rendered result, not just an enum.
- All three test copies restored to their full raw-setting baselines with empty
  differences after the core regression. The render test restored its copy too.
- Manual gradient: awaiting_user_input was returned, the gradient was drawn via
  the UI, enumerated by ID, updated to Exposure -0.4, and deleted. The original
  subject mask remained. A first post-delete list returned context_timeout;
  a subsequent read-only check confirmed the original mask set. The full raw
  baseline was restored afterward. This transient synchronization issue remains
  recorded; it is not represented as a mutation retry.

Remaining interactive item: the ordinary Clone tool panel did not display
reliably through UI automation. User drawing on the named test copy was requested
at the end; no new clone region has yet been verified. No generative cloud repair
or claim of completion for all repair modes is included.

Final evidence:
[core regression and restoration](verification/2026-09-21-fixes/fix-2.12.2.json),
[render comparison](verification/2026-09-21-fixes/render-fix-2.12.2.json),
[multi-selection and gradient](verification/2026-09-21-fixes/final-interactive.json),
[stdio handshake](verification/2026-09-21-fixes/stdio-2.12.2.json).
Rendered examples: [baseline](verification/2026-09-21-fixes/baseline.jpg),
[Daylight](verification/2026-09-21-fixes/daylight.jpg),
[B&W](verification/2026-09-21-fixes/grayscale.jpg).
The previous authorization-blocked attempt is retained separately as
[historical evidence](verification/2026-09-21-fixes/fix-2.12.2-license-blocked.json).
