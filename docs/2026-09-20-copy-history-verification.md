# Copy/Paste and history verification — 2026-09-20

Lightroom Classic **15.2**. Main/Python/Versions **2.7.0**, **93 tools**.
**354 tests passed**. Production Lua tests exercise the real Versions and Develop
modules; transport mocks establish schema/IPC behavior only.

## Live behavior

Two new virtual copies isolated both sides of the transfer:

- Source: `66FDE358-2C8D-4887-A522-84D173629828`, `MCP 复制来源验证`.
- Target: `7990DCD0-F9ED-4334-8FD3-145385928C98`, `MCP 粘贴撤销验证`.
- Original: `6A644F6A-E754-4788-A73E-6D7B1C03CAC6`.

Explicit copy froze Exposure=1.23. Source was then changed to 2.34. Pasting onto
the target still produced 1.23, with only Exposure2012 in changedKeys. Native undo
returned target exposure to its 0.66 baseline, and redo returned it to 1.23.

Native UI-mode copy of the source, followed by paste while the target was active,
produced 2.34. Undo returned that native paste to 1.23 and redo reapplied 2.34.
The native copy-category selection was not enumerated; only these observed value
changes are claimed, not exhaustive copying of all develop fields or masks.

Reusing a consumed undo token was rejected. Reading history state, then performing
an intervening MCP selection command, invalidated the token before another undo
could occur. Unit tests additionally cover source changes, target/catalog guards,
copy failure, numeric readback failure, unavailable history, token expiry, SDK errors,
receipt eviction and conservative mutation invalidation.

## Restore

Both virtual-copy snapshots were applied and their complete raw settings compared
with the saved baselines: zero differing keys on both. Snapshots were deleted only
after both comparisons. Snapshot names can already appear on other family copies;
a distinct target snapshot name was used after observing a same-name collision.

The original raw settings were unchanged, and its Library grid selection was
restored. Both named test copies remain for future use. Native Copy/Paste necessarily
changes Lightroom's settings-copy buffer; its previous contents are not readable
through this SDK. After validation the original photo was copied into that buffer,
so it does not retain the test source's Exposure=2.34 settings. This does not restore
an unknown pre-test clipboard payload or erase the native test history entries.

Records and baselines are in `/tmp/lr-history/`. No generative cloud processing,
file export, original-file rewrite or photo deletion was involved in this batch.
