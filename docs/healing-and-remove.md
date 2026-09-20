# Repair / Remove (2.4)

Phase 5 adds 17 tools (72 total). Main/Python and Healing are 2.4.2; Versions is 2.4.0;
other modules retain their independent versions. SDK method presence is exposed
in `lr_ping.capabilities.healing`. Remove controls generally require SDK 14.1+.

## Existing regions

| Tool | Purpose |
| --- | --- |
| `lr_open_remove` | Open Develop/Remove, optionally choose clone/heal/remove |
| `lr_list_spots` | Paged raw spot values, native indices, full-list revision |
| `lr_get_selected_spot` | Selection, native parameter table, type and AI flag |
| `lr_select_spot` | Select an explicitly guarded region |
| `lr_update_spot` | Patch existing numeric parameters and verify readback |
| `lr_set_spot_type` | Set `clone`, `heal`, or `heal_patchmatch` and AI flag |
| `lr_move_spot` | Relative target/source-area movement |
| `lr_refresh_spot` | Ask Lightroom for a new source/result |
| `lr_delete_spot` | Delete one region and verify remaining region list |
| `lr_cycle_spot_variation` | Next/previous existing generative variation |
| `lr_reset_healing` | Clear repair regions after matching full-list revision |
| `lr_get_remove_preferences` | Read Remove UI defaults |
| `lr_set_remove_preferences` | Patch defaults, then read them back |

These tools work on the current photo. Optional `expectedPhotoId` and
`expectedCatalogPath` guards are recommended on every call. Selection is checked
after waits. They activate Develop and Remove, so they may change the UI context.

Read `lr_list_spots`, then pass the exact returned `spotIndex` and `spot` as
`expectedSpot` for targeted calls. Indices can shift after deletion; refresh the
list after any edit. Unknown layouts fail explicitly. Missing/transient lists
must agree with `countAllSpots` before an empty/deleted result can be reported.
`offset` defaults to 0; `limit` defaults to 50 (maximum 200). The reset revision
covers the entire list, including entries beyond the current page.

`lr_update_spot.changes` accepts only observed `Opacity` and `Feather`, both
in the raw 0–1 scale. Other native data is read-only. The full parameter table is
preserved while patching those two fields. **On Lightroom 15.2 the SDK setter
returned without retaining either change in the live brush-region test.** The tool
reports `readback_failed`; parameter updates are not claimed to work on this build.
There is no automatic retry or raw catalog-settings fallback. Other SDK versions
must also pass native readback before success can be returned.

`lr_move_spot` takes `horizontal: left|right`, `vertical: up|down`, optional
positive `horizontalUnits` / `verticalUnits` (at most 1000), and `sourceArea`.
At least one direction is required. Omitted units use Lightroom's default step;
source-area movement is only available for heal/clone. It requires an observed change in the region data before reporting success.
On the tested Lightroom 15.2 brush region, both source and target movement produced
no observed change; this now returns movement_unverified. No measured pixel
displacement is claimed.

`useGenerativeAI: true` is valid only for `heal_patchmatch` and may start Adobe
cloud processing. `lr_refresh_spot` on a generative region requires
`allowGenerativeRefresh: true`. These return a submitted/requested state, not proof
that generation has finished. Variation navigation requires an existing
generative spot; it does not invent result IDs or count, delete variations, or
verify image pixels. On timeout or pending state, read back before retrying.

Remove preferences are **drawing defaults**, separate from existing spot params.
Supported fields: `newSpotType`, `brushSize` (1–100), `brushFeather` (0–100),
`useGenerativeAI`, `detectObjects`, `toolOverlay` (`always|auto|selected|never`),
`visualizeSpots`, and `visualizationThreshold` (0–100). Changing defaults does not
create a region.

There is no documented SDK operation here for creating arbitrary brush paths from
coordinates. Draw new regions in Lightroom, then manage them through these tools.
Saving a snapshot before changing/resetting repairs provides a recovery point.

## AI maintenance

| Tool | Purpose |
| --- | --- |
| `lr_update_ai_settings` | Start a bounded per-photo native AI update job |
| `lr_get_ai_update_status` | Poll job and per-photo outcomes |
| `lr_cancel_ai_update` | Cancel between photos |
| `lr_cleanup_empty_masks` | Native cleanup with observed removed mask IDs |

Targets are explicit `photoIds` (unique UUIDs, maximum 200), or `scope` of
`current` (default) / `selected`. Do not supply both forms. Catalog/photo guards
are accepted. Photo objects are resolved before writes; AI jobs keep those targets
if the UI selection changes. Videos and missing APIs are rejected before starting.

Python assigns an AI job ID and returns it even if the start response times out.
Poll that ID; do not blindly submit another job. Only one AI job runs at a time.
States: `queued`, `running`, `cancelling`, `sdk_completed`, `cancelled`, `failed`.
Cancellation cannot interrupt an in-flight native call; earlier changes remain.
A failure stops subsequent photos. Per-photo results and counters distinguish
completed, failed and not-started targets. Jobs exist only in the plugin session;
a reload/restart loses status, not necessarily prior edits.

AI updates use `photo:updateAISettings` under catalog write access. This does not
replace AI Denoise/Enhance. `sdk_completed` means calls returned; it does not prove
that downstream GPU/cloud processing or pixel rendering completed. Preset-triggered
AI updates now use the SDK-required write gate as well.

Empty-mask cleanup calls `catalog:deleteAllEmptyMasks` under a write gate, always
passing an explicit photo array. It reports IDs removed from catalog mask settings,
not a guessed SDK mask count. It stops on failure and reports partial results.
An empty removed-ID list means no catalog IDs were observed disappearing; it is
not a positive test of removal. No arbitrary raw mask data is written.

## References / validation

- [Adobe SDK LrDevelopController reference](https://lrc.mcor.dev/modules/LrDevelopController.html)
- [Adobe SDK LrPhoto reference](https://lrc.mcor.dev/modules/LrPhoto.html)
- [Adobe SDK LrCatalog reference](https://lrc.mcor.dev/modules/LrCatalog.html)

The links render Adobe's SDK API reference through a community-hosted mirror.
Production Lua is tested through Lupa; mock IPC tests validate transport and schema
behavior only. Neither substitutes for live Lightroom validation. See the phase-5
verification record for tested operations and remaining limitations.
