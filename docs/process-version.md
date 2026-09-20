# Process Version (2.8.0)

Two tools bring the bridge to **95 tools**. Main/Python/Fine are **2.8.0**;
other modules retain independent versions.

| Tool | Purpose |
| --- | --- |
| `lr_get_process_version` | Read the SDK name and raw catalog representation separately |
| `lr_set_process_version` | Set one selected photo to a documented SDK version and verify it |

Both tools activate Develop because the native get/set methods require it. They
accept expectedPhotoId and expectedCatalogPath guards, reject videos and check
catalog/photo identity around waits. The getter does not set a version.

The setter requires `expectedPhotoId` and exactly one selected photo, preventing
an ambiguous multi-selection/Auto Sync context. `version` must be one of
`Version 1` through `Version 6`. Optional `expectedVersion` rejects a stale starting
version. Raw values such as `11.0` or `15.4` are not accepted as public version names.

The implementation calls `LrDevelopController.setProcessVersion` without a catalog
write gate or a raw-settings fallback. It polls the native getter for the requested
name and checks that the raw catalog version changed. Same-version requests return
`status: unchanged` without calling the setter. Missing APIs, SDK rejection and
unconfirmed transitions produce errors. A failed/timeout request may already have
changed the photo: inspect before retrying.

Results include `version`, `rawVersion`, previous values for a transition,
`changedKeys` and `verification: sdk_and_catalog_readback`. No hardcoded raw-version
mapping is used in production. A future unknown SDK name can be read with
`recognized: false`, but cannot be written until its support is explicitly added.

## Conversion versus restoration

Changing the process version can change rendering, the available sliders, and
other develop values. Switching back is not a lossless undo of conversion.
Save a snapshot and a raw baseline before testing; compare actual settings after
restoration. `renderingVerified: false` makes clear that version readback is not
pixel equivalence or a promise that every edit survived a downgrade.

This feature does not add HDR editing, AI processing or batch migration. Existing
numeric adjustment tools continue to resolve parameter mappings for the actual
photo/process version.

## Native verification (Lightroom Classic 15.2)

The observed mapping on this installation was:

| SDK name | Raw catalog value |
| --- | --- |
| Version 1 | 5.0 |
| Version 2 | 5.7 |
| Version 3 | 6.7 |
| Version 4 | 10.0 |
| Version 5 | 11.0 |
| Version 6 | 15.4 |

All six versions were applied to one isolated RAW virtual copy and read back.
This table records the test; it is not a cross-version conversion rule in code.
Older-version transitions changed additional develop keys, as reported.
Same-version requests, stale expectedVersion and multiple-selection rejection
were also verified live.

Original photo: `6A644F6A-E754-4788-A73E-6D7B1C03CAC6`.
Retained test copy: `73C20A1A-16DB-415F-B3BE-306991B17034`, named
`MCP 处理版本验证`.

The snapshot restored the copy with zero differing raw-settings keys; both getters
confirmed Version 5 / 11.0. The temporary snapshot was deleted after comparison.
Original raw settings were unchanged and the original Library grid selection was
restored. Local records are in `/tmp/lr-process/`.

**370 tests passed**, including production Lua tests for all six choices, identity,
stale-version/multi-selection guards, missing APIs, silent and partial no-ops,
future unknown readback and schema/IPC behavior. No full Lightroom restart was
needed; the existing Fine module was reloaded after stopping the bridge.

SDK source: [LrDevelopController get/setProcessVersion](https://lrc.mcor.dev/modules/LrDevelopController.html)
(community-hosted rendering of Adobe's SDK API reference).
