# Phase 1: deployment and develop foundations (2.0.0)

This release retains 17 MCP tools. It adds deployment diagnostics and verifies
numeric edits; presets, snapshots, library management and export are later phases.
Protocol 2 adds required version matching and request correlation, so the release
uses a major version per the repository's versioning rules. Update Python and Lua
together. Masking.lua is unchanged at 1.1.4; Develop.lua and the main plugin are 2.0.0.

## Deployment and capabilities

`lr_ping` now returns:

- `server.version`, `server.path`, `server.toolCount`, `server.tools`: the responding
  Python process, not an assumption based on a README or a different installation.
- `version`, `pluginPath`, `protocolVersion`, `developVersion`, `maskingVersion`:
  the loaded Lua code and actual plugin folder.
- `lightroomVersion`, `capabilities.controllerAPIs`, `capabilities.photoAPIs`:
  runtime function presence. Photo APIs are omitted when no photo is selected.
- `compatible`: whether this process and the responding plugin match.

Function presence is not proof that every photo/type/option works. In particular,
Lightroom 15.2 on the test machine has no `setEnhance` or
`setLensBlurFocalRangeFromSubject`. Those requests return `unsupported_api`.
No SDK version is inferred from the application's version number.

The Python process checks plugin/protocol versions before every non-ping command.
Old clients are also rejected by the new plugin. Restart the MCP client after
updating its files. Reloading Lightroom's plugin manifest does not necessarily
restart its existing polling loop. A cold restart and/or Plug-in Extras > Start
MCP Bridge Server may be needed. Confirm the versions with ping afterward.

## Numeric settings

Single and batch edits use the same `LrPhoto.applyDevelopSettings` backend and
per-photo mappings. For example, Exposure maps to Exposure2012 for modern process
versions, rather than incorrectly writing the legacy Exposure key. Legacy tone
keys and rendered-file IncrementalTemperature/IncrementalTint have separate mappings.
Changing white balance sets WhiteBalance to Custom. Crop writes enable HasCrop.
Values are absolute, not relative offsets.

`lr_get_settings` works from Library without opening Develop. It returns:

- Existing `filename`, `rating`, `settings`, plus `photoId` and `processVersion`.
- `parameterKeys`: the catalog key used for each supported numeric parameter.
- `unavailableParameters`: registered controls without a supported numeric mapping
  in this photo's current settings. This does not claim the feature is absent from
  Lightroom; some controls are conditional, nested or UI-only.
- Optional `includeRaw: true`: the full SDK develop table for read-only inspection,
  including strings, booleans and complex values. It can be large. It is not a
  writable schema, and should not be blindly passed back as settings.

The global numeric registry now includes calibration, lens correction strengths,
noise-reduction contrast and additional vignette controls. Unknown names, duplicate
case-insensitive names, non-numbers and non-finite numbers fail explicitly.
Unmapped numeric controls are rejected rather than silently passed to the wrong API.
Lens blur remains a dedicated controller tool because its catalog data is nested.

`lr_get_settings`, `lr_apply_settings` and `lr_batch_apply_settings` accept optional
`expectedPhotoId`, checked against the active target. Batch operations snapshot the
selected photo objects and preflight all requested mappings before starting writes.

## Outcomes and limits

Numeric writes are read back per photo. Responses report `applied`, `failed`,
`notAttempted` and `data.results` with IDs, actual values and individual errors.
A silent SDK no-op or clamped/rounded value outside the verification tolerance is
not reported as success. Crop geometry and boolean-style controls are prevalidated;
this is not an exhaustive per-photo range validator for all Lightroom controls.

A batch stops at the first write/readback failure. There is no automatic rollback:
the failed photo may be partially changed, and earlier photos may be complete.
Read the returned results before retrying. A transport timeout is an unknown outcome
for mutations, not proof that nothing happened, and does not cancel a running SDK
operation. No timed-out command is automatically retried.

Requests have unique IDs; late responses cannot be mistaken for a later command.
A file lock serializes updated Python clients sharing an IPC path, and plugin
responses are written atomically. SDK exceptions are caught with LrTasks.pcall so
yielding operations do not kill the server loop. Incompatible pre-protocol clients
must still be restarted: their old transport does not participate in file locking.

Auto Tone/Reset require a ready Develop module; their old detached tasks were
removed. Crop uses the verified numeric backend. Lens blur no longer swallows
failures. AI commands report trigger/API availability, not guaranteed rendering
completion. This release does not add missing AI SDK methods.

## Validation

Automated tests exercise production Lua 5.1 with SDK doubles, Python validation,
IPC correlation/version gating, MCP stdio, and existing mask behavior. Real
Lightroom tests are recorded separately in `2026-09-20-phase1-verification.md`.
Doubles do not validate GPU rendering or every process/file type.

References: Adobe SDK Guide in this repository; API reference mirrors for
[LrPhoto](https://lrc.mcor.dev/modules/LrPhoto.html),
[LrDevelopController](https://lrc.mcor.dev/modules/LrDevelopController.html), and
[LrDevelopPreset](https://lrc.mcor.dev/modules/LrDevelopPreset.html). Adobe describes
the catalog develop settings table as experimental; mappings therefore require
per-photo presence checks and verified readback.


## 2.13.0 update

Settings reads now support explicit photo batches and parameter filtering. Numeric
preflight shares execution planners; known tone/WB bounds are validated before
absolute writes too. See [batch reads and preflight](batch-read-and-preflight.md).
