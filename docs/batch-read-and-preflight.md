# Batch develop reads and numeric preflight (2.13.0)

Main/Python/Develop/Versions are 2.13.0, with 112 tools. Update the plugin and restart
the MCP process together. This extends lr_get_settings and adds one read-only tool,
lr_preflight_settings. Neither changes selection, modules, settings, files or history.

## Read several photos without selecting them

```json
{"photoIds":["uuid-a","uuid-b"],"parameters":["Exposure","Contrast","Temperature","Tint"]}
```

Pass to lr_get_settings. Use explicit photoIds (1-200 unique IDs) OR scope=current/
selected. Without target options, the existing current-photo data.settings response
is preserved. With photoIds or scope, data.photos contains per-photo results:

- photoId, filename, rating and processVersion.
- settings and parameterKeys: public parameter names and actual catalog mappings.
- unavailableParameters: registered controls absent/unsupported on that photo.
- success and, on a getter failure, code/error. Other photo results remain available;
  top-level success=false/code=partial_failure indicates a partial read.
- data.total, data.read and data.failed summarize the batch.

parameters is optional (all registered numeric controls by default), case
insensitive and rejects unknown names or duplicates after canonicalization.
includeRaw defaults false; true adds the full SDK table per photo, which can be
large. Empty settings/mapping tables remain JSON objects. Boolean controls use 0/1
as before. Temperature/Tint mappings distinguish RAW values and rendered-file
IncrementalTemperature/IncrementalTint; no unit conversion is implied.

expectedPhotoId guards the active UI photo, not each batch member;
expectedCatalogPath guards the catalog. Explicit photo IDs work with no active
photo if no active-photo guard is supplied. Invalid/missing IDs reject target
resolution for the whole request; getter failures after resolution are per-photo.
A catalog or guarded active-photo change aborts the whole read to avoid mixing
contexts. A batch is not an atomic snapshot of concurrent manual edits.

## Preview an edit without executing it

Absolute values:

```json
{"photoIds":["uuid-a","uuid-b"],"settings":{"Exposure":0.3,"Temperature":6000}}
```

Relative increments:

```json
{"photoIds":["uuid-a","uuid-b"],"mode":"relative","deltas":{"Exposure":0.5}}
```

Pass to lr_preflight_settings. mode defaults to absolute. settings and deltas are
mutually exclusive; relative requires explicit mode=relative and deltas. Targets
and guards match the read tool. This version covers numeric edits only, not preset
application, masking, export or native Quick Develop UI operations.

Top-level success means the inspection completed. **Always inspect data.canApply**:

- data.photos: photoId, processVersion, before, target, parameterKeys,
  catalogChanges, ready, unavailableParameters, and code/error/details when blocked.
- catalogChanges shows the exact planned SDK payload, including WhiteBalance=Custom
  or HasCrop=true where required. Zero relative deltas do not force Custom WB.
- readyCount and blockedCount count individual photo plans.
- batchIssues reports cross-photo restrictions such as mixed RAW/rendered WB units.
  Individually ready photos do not imply canApply=true when a batch issue exists.
- checkedRanges lists validated numeric bounds; uncheckedRanges lists otherwise
  supported controls without exhaustive per-photo SDK range validation.

The same per-photo absolute and relative planners are used by execution. Known
modern tone/presence/WB bounds, crop geometry, boolean 0/1, unavailable keys,
process-version restrictions and required write API presence are checked without
calling setters or acquiring write access. Absolute writes now also enforce the
same known tone/WB bounds before mutation. Legacy/other controls without known
bounds remain explicit in uncheckedRanges; the preview does not consult the active
photo's UI getRange for a different target.

A negative canApply value does not change any photo and does not execute the ready
subset. Error details include the failed target/range where available. Malformed
requests, unknown parameter names and unresolved IDs are request-level errors.

**This is an observation, not a reservation or authorization to execute.** Call
lr_apply_settings or lr_batch_adjust_relative separately. Execution re-reads and
rechecks state; a later manual edit can change the computed relative targets or
make a previously ready request invalid. There is no apply token, frozen execution
plan, rollback or guarantee that the SDK will accept/render every planned value.

## Validation

Production Lua tests cover per-photo read failures, legacy response compatibility,
filtered/raw reads, missing active photo, missing IDs, case-normalized duplicates,
empty JSON objects, known/unchecked bounds, crop/boolean constraints, per-photo
blockers, cross-photo WB units and preflight/execution parity. Spies prohibit write
access, setter calls and selection changes during preflight. Separate tests cover
schema/isolated IPC, state changes after inspection and preservation of undo tokens.

No live Lightroom catalog was used for this feature's automated checks. Native
acceptance is pending; prior 2.12.2 rendering results are not evidence for new
2.13.0 behavior. A future native check should capture settings/selection, read and
preflight two different exposures, verify nothing changed, then compare a separately
executed delta against the preview and restore the original snapshots.
