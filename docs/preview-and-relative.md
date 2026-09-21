# Smart previews and relative adjustments (2.11.0)

Python and the main plugin must both be 2.11.0. Reload the plugin and restart the
MCP client, then inspect lr_ping. Six additional tools bring the total to 110.

## Smart previews

| Tool | Purpose |
| --- | --- |
| lr_get_smart_previews | Read native smart-preview presence, path, bytes and original availability |
| lr_build_smart_previews | Start a native creation job |
| lr_delete_smart_previews | Start a native deletion job |
| lr_get_smart_preview_job | Query jobId, with optional offset/limit result pagination |
| lr_cancel_smart_preview_job | Request cancellation between photos |

Read/build/delete target the current photo by default. Use `scope: "selected"` or
`photoIds: ["uuid", "uuid"]` for at most 200 photos; never combine scope and photoIds.
Optional expectedPhotoId and expectedCatalogPath guard request context.

```json
{"scope":"selected"}
```

Pass this to lr_get_smart_previews or lr_build_smart_previews. Creation/deletion
returns a jobId. Poll lr_get_smart_preview_job with:

```json
{"jobId":"returned-32-character-job-id"}
```

A successful start only means accepted. Inspect the job's status
(queued/running/cancelling/completed/cancelled/failed), completed/failed/notStarted,
and per-photo results. Completed includes unchanged photos. Results contain
before/after observations and nativeResult when a native mutation was attempted.
A failed native attempt may already have changed state: outcomeUnknown and
observed after state are provided where available. Never blindly retry failures.

- Only SDK buildSmartPreview/deleteSmartPreview are used. Original files are never
  deleted or moved. Preview presence is verified via smartPreviewInfo, not by
  pretending a JPEG thumbnail is a smart preview.
- All targets are preflighted before scheduling. Videos are rejected. A missing
  preview cannot be built from an offline original. Existing previews are no-ops.
- Empty metadata table means no preview; nil/malformed metadata fails explicitly.
  Original availability is the SDK's estimate, not a filesystem guarantee.
- Deleting an existing preview with an offline original requires
  `allowOffline: true`; the default fails with offline_preview_protected. This
  condition is rechecked when each photo is processed.
- Jobs retain fixed target objects. Changing selection after start does not
  redirect work. Switching catalogs or removing a target stops the job.
- First failure stops the remaining batch. Completed work is retained.
- Cancel cannot interrupt an in-flight native operation; it prevents subsequent
  photos. Status/cancel responses may wait while Lightroom is busy.
- One preview job at a time. Latest 20 jobs retained in module memory. Reloading
  the plugin/restarting Lightroom loses job queries; do not reload during active
  jobs. Unknown job IDs never prove no work happened. No automatic resumption.

## Relative batch adjustments

`lr_batch_adjust_relative` adds each delta to each photo's own current value.
For example, initial exposures -0.5 and +1.0 become 0.0 and +1.5:

```json
{"scope":"selected","deltas":{"Exposure":0.5,"Contrast":-5}}
```

Default scope is current; explicit photoIds and context guards work as above.
Supported parameters: Exposure, Contrast, Highlights, Shadows, Whites, Blacks,
Clarity, Texture, Dehaze, Vibrance, Saturation, Temperature and Tint.

This uses documented LrPhoto getDevelopSettings/applyDevelopSettings with the
existing catalog mappings. It deliberately does not reinterpret Quick Develop
small/large/numeric button steps as exact slider deltas.

| Parameter | Delta units and accepted resulting range |
| --- | --- |
| Exposure | EV; target -5 to +5 |
| Tone/presence/color sliders above | Slider units; target -100 to +100 |
| RAW Temperature | Kelvin; target 2000 to 50000 |
| RAW Tint | Catalog units; target -150 to +150 |
| Rendered Temperature/Tint | Incremental catalog units; target -100 to +100 |

These are the tool's bounds, not a claim that every SDK/photo accepts every target.
Process settings must expose modern Exposure2012 (Process Version 3+); unavailable
parameters and videos are rejected. A batch cannot mix absolute and incremental
white-balance keys. Split mixed RAW/rendered WB batches before applying deltas.
No rounding, clamping or hue wrapping is performed. Zero deltas are no-ops when
all requested deltas are zero; nonzero WB edits request Custom white balance.

All targets and ranges are preflighted before any writes. The original baseline,
process version and relevant WB mode are rechecked inside the catalog write gate.
Concurrent changes fail with settings_changed instead of overwriting that baseline.

Results report each photo's before, target, after, parameterKeys and success.
The first failed photo stops the batch. applied counts verified photos (including
unchanged ones); failed and notAttempted distinguish later work. A failed attempted
write may have partially changed the photo. No rollback or automatic retry occurs:
calling again would add the delta again. On transport timeout, inspect the photos
before issuing another request. Readback verifies numeric values, not pixels.

## Validation and SDK references

Production Lua tests cover preview create/delete/no-op, offline protection,
unknown state, native errors/no-ops, cancellation, catalog/target changes, bounded
job retention, relative per-photo differences, positive/negative/zero deltas,
range and mixed-unit preflight, stale settings, partial failure, lock timeout,
color grading and actual server JSON dispatch. Isolated IPC tests cover tool
registration, validation, job IDs and transport round trips.

Native Lightroom acceptance is pending. Before relying on a live batch, test a
small disposable set: online RAW creation/deletion, offline preview protection,
cancel between photos, and distinct initial exposures plus 0.5 EV. Verify UI and
readback; restore develop snapshots and retain any preview needed for offline use.
SDK doubles and transport mocks do not establish native rendering/cache behavior.

Source: Adobe [LrPhoto API Reference](https://lrc.mcor.dev/modules/LrPhoto.html)
(community-hosted copy): buildSmartPreview, deleteSmartPreview, smartPreviewInfo,
checkPhotoAvailability, getDevelopSettings and applyDevelopSettings. Develop
settings tables are experimental and can vary by version.
