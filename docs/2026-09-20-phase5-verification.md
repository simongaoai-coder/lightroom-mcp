# Phase 5 verification — 2026-09-20

Main/Python/Healing: **2.4.2**, Versions: **2.4.0**, protocol **2**, **72 tools**.
Lightroom Classic **15.2**. All new API-presence checks returned true; presence
alone did not establish working parameter updates or movement.

## Native results

| Operation | Observed outcome |
| --- | --- |
| MCP stdio initialize/list/ping | 72 tools; matching installed main/Healing versions |
| Open Remove / preferences | Defaults changed and read back; restored afterward |
| Empty and nonempty spot enumeration | Counts matched; one-based index 1 on this sample |
| Select existing brush region | Correct clone region selected, full params read |
| Switch clone to heal | Native type readback confirmed heal |
| Refresh | SDK call returned; no claim of a distinct source or changed pixels |
| Delete region | Count/list changed from one to zero |
| Restore drawn snapshot | Region returned, count one |
| Reset healing | Count/list changed from one to zero |
| Reject variation navigation on non-generative region | not_generative_spot |
| AI settings job | One explicit copy reached sdk_completed, completed=1, failed=0 |
| Empty-mask cleanup | Native call returned; no removed IDs on the mask-free copy |

The user drew one non-generative clone brush region on the dedicated virtual copy.
The returned table contained native brush paths and source data. No new programmatic
stroke was created. Multi-region deletion/index shifts are unit-tested, but were
not live-tested because this sample contained one region.

## Unresolved behavior found live

The cause is not yet established: these observations may reflect SDK behavior,
our invocation/adapter, or the tested region type. Parameter editing and movement
remain incomplete; readback guards prevent false success but do not fix them.

- `setSelectedSpotParams` with the read/patch parameter table returned without
  retaining `Opacity` or `Feather`. `lr_update_spot` reports `readback_failed`.
  The public patch surface is restricted to these two observed numeric controls
  (raw 0–1 scale); identity, version, seed and geometry fields are read-only.
  Other SDK versions must pass the same readback check. No raw catalog repair
  data fallback is used.
- Both source and target relative movement calls returned but produced no change
  in the tested brush-region data, including its geometry. The final handler now
  waits for a region-data change and returns `movement_unverified` if unchanged.
  The new no-op guard is regression-tested; positive native movement is not claimed.
- Generative cloud processing and visual variation navigation were not exercised.
  Their dispatch and guards are covered by production Lua tests only.
- AI update completion means the native call returned, not verified rendered AI
  pixels or regeneration of stale content. Empty-mask cleanup was a no-op case,
  not a positive native deletion test.

## Automated coverage

280 tests pass. Production Lua tests cover selection/identity guards, transient
lists, parameter readback/no-ops, movement no-ops, deletion/reset, generative
restrictions, explicit cleanup arrays/write gates, job cancellation/failure and
catalog changes. The preset fixture asserts AI updates hold a write gate.
Mock IPC tests establish schema/transport behavior, not native rendering.

## Restored state

Original photo: `6A644F6A-E754-4788-A73E-6D7B1C03CAC6` (`_DSC1049.ARW`).
Retained virtual copy: `DB123BB2-99B6-436E-8096-4B08F641319D`, named
`MCP 第五阶段验证`.

The copy was restored from its pre-test snapshot. Complete `rawSettings` and
normalized `settings` matched the saved baseline with **zero differing keys**.
The original photo was reselected and both settings tables likewise had zero
changes. The original Remove preferences were restored exactly. Both temporary
snapshots were deleted after verification; the test copy remains for future use.
Lightroom is back in Library view on the original photo.

Local test records and baselines remain in `/tmp/lr-phase5/`.
