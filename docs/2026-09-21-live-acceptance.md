# Lightroom 2.10–2.12 native acceptance — 2026-09-21

**Historical 2.12.0 result: partial acceptance; not ready for unrestricted batch-style use.**

The two confirmed defects have code fixes in 2.12.2 and their final core native
regression passed after the user restarted Lightroom; see the
[fix and verification report](2026-09-21-native-fixes.md) for final-build validation
status. The original observations below are retained unchanged.

Tested commit `c1c70de`, main/Python 2.12.0, Lightroom Classic 15.2, macOS.
The real MCP stdio client initialized and enumerated **111 tools**; ping confirmed
matching Python/plugin 2.12.0. The pre-existing connector in the Codex task still
cached 2.9.0, so tests used a fresh production Python process and real file IPC;
an additional fresh stdio ClientSession verified the protocol end to end.
No mock was used for these results. No production code was changed during testing.

Scope: recent shooting metadata, color-grading naming, relative adjustments,
smart previews, saved styles and explicit batch targets, plus an attempted final
interactive-mask check. This is not exhaustive native acceptance of all 111 tools.

## Environment and isolation

User authorized independent backed-up test materials, catalog operations, plugin
updates and restarts. Installed plugin was initially 2.9.0. Lightroom was closed;
the catalog files and old plugin were copied to `/tmp/lr-accept-20260921`, then all
15 Lua files from the committed 2.12.0 source were copied and hash-verified at the
existing Lightroom Modules location.

The active catalog contained six original Sony ILCE-7M3 ARWs under
`/Users/gsm/Pictures/Lightroom_MCP_Test_Photo` plus prior test copies. Three new
clearly named virtual copies were created, with unique baseline snapshots where
necessary. Native snapshots were observed across virtual copies in the same
family; duplicate-name protection prevented an accidental overwrite.

A 1400×933 JPEG was exported with copyright-only metadata, then imported via the
native Add dialog with Develop and Metadata presets set to None. Only the one new
JPEG was imported. It supplied the stripped-EXIF, rendered-format and offline cases.

## Results

| Check | Result | Evidence/qualification |
| --- | --- | --- |
| 2.12.0 deployment / MCP stdio | PASS | Matching runtime versions; 111 registered tools |
| Shooting metadata, six RAWs | PASS | Native numeric shutter/aperture/ISO/focal data; flash=false retained; no fieldErrors |
| Independent metadata check | PASS (sample) | _DSC1037 XMP reports 1/160 s, f/2.8, ILCE-7M3, matching ISO timestamp; native shutter 0.006250000411… is a floating-point representation |
| JPEG missing EXIF | PASS | Camera/exposure fields reported in missingFields, not invented zero values; size, dimensions and bit depth returned |
| Absolute values by explicit IDs | PASS | Correct test copies changed without changing active selection |
| Relative exposure batch | PASS | -0.5 and +1.0 became 0.0 and +1.5 with +0.5 EV; original difference retained |
| Mixed RAW/JPEG WB delta | PASS (guard) | Rejected with mixed_parameter_units |
| Invalid later target | PASS (preflight) | photo_not_found before first target changed |
| Existing SplitToning color-grading controls | PASS (stored values) | Warm highlights/cool shadows and balance written/read back; no new aliases needed |
| Point-curve control | PASS (stored values) | Nonlinear RGB composite curve retained |
| Smart preview RAW/JPEG creation | PASS | Native created result, nonempty DNG path/bytes and hasSmartPreview=true |
| Existing-preview creation | PASS | unchanged, no duplicate work |
| Batch cancellation | PASS | cancelled after one photo, five notStarted; completed preview retained |
| Preview persistence | PASS | JPEG preview still enumerated after a full Lightroom restart |
| Offline-delete protection | PASS after restart | offline_preview_protected without allowOffline |
| Explicit offline deletion | PASS | Native deleted and absent readback with allowOffline=true |
| Missing preview + offline source | PASS (guard) | photo_unavailable before creating a job |
| Preview cleanup | PASS | All six original photos and test JPEG ended without smart previews, matching originals' initial state |
| Style save / field readback | PASS | Native plugin preset created with 21 selected fields (14 grading, four curves, three grain) |
| Duplicate style name | PASS | style_exists, existing preset retained |
| Style restart persistence | PASS | Same preset UUID enumerated after restart; compatibility manifest still enforced |
| Incompatible process version | PASS (guard) | 15.4 source style refused on 11.0 target before mutation |
| Style preserves unselected fields | **FAIL** | Custom temperature/tint changed even though omitted from saved style |
| Batch treatment on unselected target | **FAIL** | Active photo changed; requested unselected photo stayed unchanged |
| Batch named Daylight WB on unselected target | **FAIL** | Active photo changed to Daylight; requested target stayed Custom |
| Batch As Shot WB | PASS (stored mode) | Both explicit targets reported As Shot via catalog-backed write path |
| Batch right/left rotation | PASS | Both targets AB→BC→AB; active selection stayed fixed |
| Final baseline restoration | PASS | Three test copies and six originals had zero full raw-settings differences at restoration check |
| Final manual gradient | BLOCKED | context_timeout before mask creation; Develop preview gray, later UI/IPC unresponsive |
| Manual repair brush | NOT RUN | Deferred to final interactive stage, then blocked by same Lightroom condition |

## Confirmed defects

### 1. Saved style application changes unselected white balance

Preset `FB94AB20-9873-47A9-841F-D472B02DF8F6`, named
`MCP 20260921 实机旅行胶片`, was created from colorGrading/pointCurve/grain only.
Its saved settings contained neither WhiteBalance nor Temperature/Tint.

On a same-process-version target, lr_apply_preset returned success and all selected
fields matched. However, the target had Custom WB at 4750 K / tint 10 before apply.
After apply, Temperature and Tint first read as -999999, then normalized to
2000 K / -150 while remaining Custom. Exposure and crop checks were unchanged;
a GrainSeed was also generated, consistent with enabling grain.

Therefore selected-field readback alone does not establish that unselected
settings are preserved. The SDK/native preset behavior or the payload it expects
needs investigation. Do not assume that the cause is fixed or universally present
on every file/version. The affected test copy was restored and its full settings
matched the baseline exactly.

### 2. Quick Develop photo-object calls target the active UI photo

A separate same-process-version probe held copy A active, supplied only copy C's
UUID, and requested grayscale. Result: A became grayscale, C remained color.
The tool returned partial_failure/readback_failed, but the non-target A had already
changed. A second independent probe requested Daylight on C: A became Daylight,
C remained Custom. Both copies were reset between probes.

This also explains the earlier two-photo batches applying one target then failing
on the second. Returning a readback error is useful but does not prevent the wrong-
photo side effect. On this runtime, quickDevelopSetTreatment and
quickDevelopSetWhiteBalance cannot be assumed to honor arbitrary LrPhoto objects.
The catalog-backed numeric, As Shot WB and native rotation paths did not show the
same routing failure in the tested cases.

## Runtime limitations and additional observations

- After cold starts, Bridge did not answer until File → Plug-in Extras → Start MCP
  Bridge Server was invoked. Startup then logged two starts and one stopped loop;
  requests subsequently succeeded. Automatic-start behavior needs investigation.
- One early app disappearance and later periods of complete UI/IPC unresponsiveness
  occurred. Console logs contained memory-pressure warnings and Adobe crash-processor
  messages. One later unresponsive Lightroom process was terminated with SIGTERM
  after baseline restoration, then restarted. These logs do not establish the root
  cause or prove that MCP caused the instability.
- Renaming the generated JPEG while Lightroom was running did not immediately make
  checkPhotoAvailability return false. After closing/restarting Lightroom with the
  file absent, it returned false and the offline guards worked. This API is an
  estimate/cache, not immediate proof of filesystem existence. The offline test
  filename was restored before completion.
- The existing Lightroom 15.2 runtime still reports setEnhance and
  setLensBlurFocalRangeFromSubject absent. This session did not attempt unsupported
  AI Enhance or claim image-render completion from those APIs.
- Final interaction test: the Develop main image area remained gray. lr_add_mask
  returned context_timeout (summary had not caught up), without a created mask.
  No blind stroke or repair action was performed on the gray canvas.

## End state and retained test artifacts

- Original six photos: full SDK raw develop tables matched saved baselines.
- Three new test virtual copies: restored to baseline; retained for reproducing
  defects, together with their named snapshots.
- Native test style: retained for reproduction; **do not apply it to important
  photos until unselected-WB behavior is resolved**.
- Generated/imported JPEG: retained as MCP_ACCEPT_20260921_NO_EXIF.jpg in the
  dedicated test folder; file path restored. Its smart preview was deleted.
- Two created RAW smart previews: deleted; all original preview-presence states
  restored. No original RAW file was renamed or removed.
- Lightroom was left in the final interaction attempt; its UI became unresponsive
  again. The main image-rendering issue must be resolved before completing manual
  gradient/brush and visual-render acceptance.
- Existing Codex connector tool metadata may still be cached at 2.9.0 until that
  connection is restarted; the separately launched production MCP process passed
  2.12.0 stdio acceptance.

## Evidence

[Machine-readable summary](verification/2026-09-21-live/summary.json) includes IDs,
native results, restoration diffs and the stdio result.
[Exact request/response receipts](verification/2026-09-21-live/receipts/) preserve
production calls, parameters and responses. Local pre-test catalog/plugin backups
and harness scripts remain under `/tmp/lr-accept-20260921`; temporary storage is not
a permanent backup. This report and receipts are repository files, not committed yet.
