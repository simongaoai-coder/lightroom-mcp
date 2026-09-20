# Phase 3 verification — 2026-09-20

## Final deployment

Main plugin/Python/Fine: **2.2.3**. Masking: **2.2.2**. Develop: **2.0.0**.
Versions: **2.1.1**. Protocol remains **2**. Twelve new tools bring the total to **38**.
The installed Lua files in Lightroom's Modules directory match this repository.
Previous deployment backup: `/tmp/lightroom-mcp-before-phase3-20260920-132148`.

A fresh real MCP stdio client initialized, listed 38 tools, and returned matching
2.2.3 paths/versions with `compatible: true`. Three consecutive ping calls also
confirmed the final version before the last mutation tests. Existing clients need
to reconnect to load the new schemas. Lightroom Classic on this machine is 15.2.

## Automated verification

**201 tests passed** with:

`mcp-server/venv/bin/python -m pytest mcp-server/tests -q`

The suite includes production Lua 5.1 tests for global/local curves, coordinate
validation and native scales, point-color CRUD and stale-index guards, preserving
unknown swatch fields, absent/uninitialized lists, last-local-swatch deletion,
Auto WB value readiness, mask combination/state operations, idempotency, missing
APIs, photo/mask boundaries and transient AI selection. Python validates schemas
and isolated transport simulations. Existing phase-1, phase-2 and mask tests remain.
`git diff --check` passed.

## Native acceptance

All photo writes used a new virtual copy named **MCP 第三阶段验证** of the user's
backup `_DSC1049.ARW`. Its original develop state was saved as a native snapshot
before editing. The master was not edited.

| Check | Actual Lightroom result |
| --- | --- |
| Auto White Balance | Auto mode with observed Temperature 5500 and Tint 19 |
| Global RGB point curve | Four-point curve persisted and matched readback |
| Global red channel | Three-point red curve persisted independently |
| Global point colors | Added a source swatch, changed saturation/luminance, rejected a stale expectedSwatch, then deleted it |
| Subject mask | Created a new mask with real mask/component IDs |
| Local RGB/red curves | Both persisted using the current native 0-255 scale |
| Extended local sliders | Hue 10, Amount 80, Grain 5 and RefineSaturation 20 read back correctly |
| Mask visibility | Hid and showed the mask; repeating hidden=true returned changed=false |
| Child visibility/inversion | Explicit child state set and read back in both directions |
| Whole-mask inversion | SDK accepted inversion and inversion back |
| Duplicate/invert | Identified a new mask ID |
| Add/subtract/intersect | Each created a new component on the explicit target mask and returned its ID |
| Local point colors | Added and updated a swatch on the target mask; global swatches remained empty |
| Last local swatch deletion | Verified both SDK success and the now-empty matching catalog field despite a nil controller getter |
| Restore | Snapshot restored the complete raw SDK settings table exactly to the pre-test baseline |
| Cleanup | Restored copy contained zero masks; test snapshot was deleted; master reselected |
| Isolation | Restored copy's entire raw SDK settings table also equaled the unchanged master's table |
| Final stdio regression | Wrong photo and nonexistent mask rejected; global curve/point-color reads succeeded; preview returned ImageContent |

The restored test virtual copy remains for inspection. No duplicate RAW/JPEG file
was created. Test mask/component/color data was removed by the snapshot restore,
and the test snapshot was deleted afterward. Lightroom history entries remain;
matching develop settings does not imply a byte-identical catalog database.

## Findings incorporated

1. AI component creation briefly returns a nil selected-mask ID. This is tolerated
   while identifying new components on the requested parent; a different nonempty
   selected ID still fails.
2. `local_point_color` is a valid masking subtool. Waiting only for the literal
   `masking` tool name caused a false context timeout and was corrected.
3. Empty local point-color lists can be nil. Initial reads report uncertainty;
   native add can initialize the list, but it must be read back to identify a swatch.
4. Deleting the final local swatch makes the getter nil again. The implementation
   first establishes that `LocalPointColors` exists on the exact catalog mask with
   the expected count, then verifies its disappearance/empty state after deletion.
   Without that evidence, a nil getter does not prove deletion.
5. Auto WB raw settings can temporarily omit Temperature/Tint. Completion now
   requires finite controller values as well as Auto mode.
6. SDK swatches include an extra `Variance` field. Updates preserve it and all
   other unspecified native fields. Small floating-point differences are tolerated.

## Deployment/application observations

Reloading without stopping the prior loop left old/new plugin environments
responding alternately. Version guards rejected mismatched requests. A full exit
with process termination confirmed cleared them. The final update used **Stop MCP
Bridge Server → copy files → Reload Plug-in → Start MCP Bridge Server**, which
avoided another full application restart and produced a stable final version.

One startup attempt returned a native licensing error for a curve write while the
application was transitioning between processes. The write was rejected. After the
application reopened and Develop was ready, the same documented API worked. No
license/account settings or checks were modified or bypassed.

During this task the user additionally authorized clicking Allow on the specific
macOS prompt asking Lightroom to access data from other apps after restart. No
claim is made here that such a prompt was clicked during the final stop/reload flow.

## Scope limits

Native checks used one ARW/process-version environment, RGB/red curve channels and
automatic subject/background mask components. Green/blue channels, alternate native
curve scales, manual drawing/sampling types and all possible process/SDK versions
were not each exercised live. There is no claim of pixel-accurate segmentation,
manual brush geometry control or AI render completion. State toggles/composition
and point-color edge cases have additional SDK-double coverage as described above.
