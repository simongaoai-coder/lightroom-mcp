# Lightroom MCP Bridge

Control Lightroom Classic develop settings from any MCP-compatible AI tool. Describe edits in plain English and the AI figures out the parameters and applies them instantly. With the preview tool, the AI can **see** your photo and give visual feedback on tone, color, and composition.

---

## How it works

```
MCP Client → MCP Server (Python/stdio) → File IPC (/tmp) → Lua Plugin → Lightroom SDK
```

The Python MCP server communicates with your AI tool over stdio. It sends commands to the Lightroom plugin by writing JSON to `/tmp/lr_mcp_req.json` and polling for a response at `/tmp/lr_mcp_res.json`. The Lua plugin running inside Lightroom polls that file every 50ms, processes commands via `LrDevelopController`, and writes results back. No network connection or open ports required.

---

## Requirements

- **Lightroom Classic 11+** for mask management (other AI tools may require newer versions)
- **Python 3.10+**
- **Any MCP-compatible AI tool** (Claude Desktop, Cursor, Windsurf, etc.)

---

## Setup

### Step 1: Install the Lightroom plugin

1. Open Lightroom Classic
2. Go to **File → Plug-in Manager**
3. Click **Add** at the bottom left
4. Navigate to `lrplugin/` in this repo and select the `lightroom-mcp.lrdevplugin` folder
5. Click **Add Plug-in**
6. Confirm the plugin status shows **Enabled**

The plugin auto-starts the bridge whenever Lightroom opens; **you do not need to start it manually each time**. The `LrInitPlugin` hook fires on every Lightroom launch and begins the file-polling loop automatically.

> **Manual control:** If `lr_ping` fails after a fresh Lightroom start (e.g. after reloading the plugin mid-session from Plug-in Manager), you can kick it manually via **File → Plug-in Extras → Start MCP Bridge Server**. This is a fallback; under normal operation Lightroom starts it for you.

---

### Step 2: Install the MCP server

Open a terminal and run:

```bash
cd /path/to/lightroom-mcp/mcp-server
python3 -m venv venv
source venv/bin/activate          # Windows: venv\Scripts\activate
pip install -r requirements.txt
```

Verify it works:

```bash
python3 server.py
# Should print nothing and wait (that's correct). Ctrl-C to stop.
```

Note the **full absolute path** to both `venv/bin/python3` and `server.py`. You'll need these in the next step.

---

### Step 3: Configure your MCP client

Point your MCP-compatible AI tool at the server. The config format varies by tool, but the command is always the same: the venv Python running `server.py`.

**Example: Claude Desktop**

Open `~/Library/Application Support/Claude/claude_desktop_config.json` (macOS) or `%APPDATA%\Claude\claude_desktop_config.json` (Windows) and add:

```json
{
  "mcpServers": {
    "lightroom": {
      "command": "/Users/yourname/lightroom-mcp/mcp-server/venv/bin/python3",
      "args": ["/Users/yourname/lightroom-mcp/mcp-server/server.py"]
    }
  }
}
```

> **Important:** Use the full path to the **venv** Python (not the system `python3`). The venv Python has `mcp` installed; the system one doesn't.

Restart your AI tool after saving. The MCP tools load at startup.

---

### Step 4: Verify the connection

Ask your AI tool to ping Lightroom (e.g. "Ping Lightroom"). It will call `lr_ping`. If the plugin is running you'll see:

> ✓ Connected. LR MCP Bridge running.

If it fails, see [Troubleshooting](#troubleshooting).

---

## Usage

Once set up, describe what you want naturally. You don't need to know any parameter names; the AI translates your intent into slider values.

### Basic editing

```
"Show me the current photo"
→ calls lr_export_preview and displays the JPEG inline

"This looks underexposed, fix it"
→ lr_apply_settings with Exposure +1.2

"Add some warmth and lift the shadows"
→ Temperature +800, Shadows +25

"It's too green: reduce the green saturation and shift the hue"
→ SaturationAdjustmentGreen -40, HueAdjustmentGreen +15

"The sky looks blown out"
→ Highlights -60, Whites -20, possibly Dehaze +15

"Make this look like a film photo"
→ Contrast +20, Fade (Blacks +15), GrainAmount 30, GrainSize 40
```

### Visual feedback workflow

The most powerful workflow: ask the AI to look at the photo, then iterate.

```
"Show me the photo"                          → lr_export_preview
"What do you see? Any problems with the tone?"
"OK, fix the exposure and show me again"     → lr_apply_settings, lr_export_preview
"Better. The skin tones look a bit magenta"
"Adjust the red/magenta hue and show me"     → lr_apply_settings, lr_export_preview
```

### Batch editing

Select multiple photos in Lightroom, then:

```
"Denoise all selected photos"
→ lr_batch_apply_settings  LuminanceSmoothing 60, ColorNoiseReduction 50

"Apply the same exposure correction to all selected shots"
→ lr_batch_apply_settings  Exposure +0.8

"Give all these photos a consistent warm grade"
→ lr_batch_apply_settings  Temperature 6800, Shadows +15, Highlights -20
```

### Masking

Mask tools can now list, select, update and delete existing masks by ID. Use `lr_list_masks` first, then pass `maskId` to `lr_update_mask`; manual selection remains supported when the ID is omitted.

`subject`, `sky`, `background` are treated as automatic creation. Other types may require drawing, sampling or selection in Lightroom and return `awaiting_user_input`; requested adjustments are deferred and must be resent after completing the mask. See [Mask management](docs/mask-management.md) for all arguments, response fields, errors and validation steps.

```
"Darken the sky"
→ lr_add_mask  maskType=sky  adjustments={Exposure:-1, Highlights:-80}

"Add a subject mask and boost clarity"
→ lr_add_mask  maskType=subject  adjustments={Clarity:40, Texture:20}

"Add a gradient and I'll position it"
→ lr_add_mask  maskType=gradient
   (draw in Lightroom, then call lr_update_mask with Exposure:-1.5)

"I drew the gradient, now darken it more"
→ lr_update_mask  adjustments={Exposure:-1, Highlights:-60}
  (pass maskId from lr_list_masks, or select the mask in LR first)
```

### Other commands

```
"What are the current develop settings?"     → lr_get_settings (lists all values)
"Run auto tone"                              → lr_auto_tone
"Reset everything and start from scratch"    → lr_reset
```

---

## Deployment and verified settings (2.0.0)

Use `lr_ping` to inspect the running Python path/tool list, loaded plugin path,
Lightroom version and SDK API availability. Python and Lua must both be updated;
restart the MCP client and verify `compatible: true`. See [Phase 1 foundations](docs/phase1-foundation.md).

Single and batch numeric edits now share per-photo catalog mappings and readback
verification. `lr_get_settings` returns photo ID, process version, mapped parameters
and unavailable controls; `includeRaw: true` adds the complete read-only SDK table.
Unsupported parameters and partial failures are explicit. Batch failure does not
roll back earlier photos. Optional `expectedPhotoId` guards these settings calls.

## Save versions and reuse styles (2.1)

Nine new tools bring the total to **26**. Save/restore snapshots, create and switch
virtual copies, search develop presets and apply them by UUID. Current-photo scope
is the default; batch preset/copy operations require `scope: "selected"`.

A typical workflow is `lr_create_snapshot` → `lr_list_presets` → `lr_apply_preset`
→ `lr_apply_snapshot`. For parallel looks, create a named virtual copy and use
`lr_list_virtual_copies` / `lr_select_virtual_copy` to switch between it and the master.

Same-name snapshots are not overwritten unless `updateExisting: true` is explicit.
Preset and snapshot applications report native SDK completion and observed changes;
AI rendering completion is not inferred. See [Versions and presets](docs/versions-and-presets.md)
for arguments, verification limits, failure handling and examples.

## Fine editing (2.2)

Twelve new tools bring the total to **38**: mask composition/state controls,
Auto White Balance, global/local RGB point curves and guarded point-color editing.
Local numeric adjustments also add Hue, Amount, Grain and RefineSaturation.

Use explicit `maskId` for local curves and point colors; omit it for global edits.
Point-color updates/deletions require the current `expectedSwatch` object to guard
against shifted indices. Mask combinations add new components; manual types still
need drawing/sampling in Lightroom. See [Fine editing](docs/fine-editing.md) for
units, response states, validation and native SDK limitations.

## Library and delivery (2.3)

Seventeen new tools bring the total to **55**. Search/select photos by UUID,
read/write catalog metadata, manage keyword assignments and collection membership,
and run native JPEG/TIFF file exports with progress and cooperative cancellation.
Explicit photo batches are checked before writing; mutations are read back.

`lr_export_photos` creates an independent batch directory and returns a job ID.
Poll `lr_get_export_status` for actual output files and per-photo errors. Source
photos are not reimported or moved. See [Library and delivery](docs/library-and-delivery.md)
for field names, targeting, export options, cancellation and session-lifetime limits.

## Repair / Remove (2.4)

Seventeen tools bring the total to **72**. Read and guard existing spots, change
parameters/type, move source or target regions, refresh/delete/reset repairs, and
navigate existing generative variations. Remove APIs require Lightroom Classic
14.1+ and are checked at runtime. New brush paths still require drawing in Lightroom.

The spot-parameter setter was observed to have no effect in Lightroom 15.2 and
returns a readback error; parameter editing is not claimed to work on that build.
Source/target movement also had no observed effect on the tested brush region
and returns movement_unverified if readback remains unchanged.
Separate tools manage Remove panel defaults, bounded AI-settings update jobs, and
empty-mask cleanup. AI jobs report native call completion, not verified rendering.
See [Repair / Remove](docs/healing-and-remove.md) for the contract and limitations.

## Treatment, white balance and profiles (2.5.1)

Five new tools bring the total to **77**: read appearance, switch color/B&W,
set named white-balance modes, list observed profile configurations and apply one.
Profiles can be extracted from SDK-visible presets or reused from a compatible
photo without copying the full preset. The list is not a complete installed-profile
browser. Every mutation checks the target and verifies catalog readback.
See [Appearance controls](docs/appearance-controls.md) for modes, compatibility,
Auto/As Shot value semantics and native validation limits.

## Geometry and navigation (2.6)

Eleven tools bring the total to **88**: native left/right rotation, crop proportions,
scoped adjustment resets, geometry readback, catalog folders/sources, views,
filmstrip navigation and view-filter controls. Reset-all and original-file changes
are not part of these tools. See [Geometry and navigation](docs/geometry-and-navigation.md)
for readback limits, selection effects and validation status.

## Copy/Paste and history (2.7)

Five tools bring the total to **93**. Copy/paste can use Lightroom's UI-selected
categories or a frozen list of numeric parameters. Undo/redo operate on the native
application-global history and require a fresh one-use context token; they are not
rollback of a specific MCP request. See [Copy/Paste and history](docs/copy-paste-and-history.md)
for clipboard scope, token lifetime and verification limits.

## Process Version (2.8)

Two tools bring the total to **95**: read the SDK Process Version and its raw
catalog value, or switch a single selected photo to Version 1–6 with readback.
Conversions may affect rendering and other settings; changing the version back
is not guaranteed to restore the original look. See [Process Version](docs/process-version.md)
for guards and native validation.

## Expanded library workflows (2.9)

Search now supports bounded nested AND/OR/exclusion groups and camera, lens, ISO,
edit-state and other typed criteria, shared with smart collections. Nine new tools
bring the total to **104**: keyword/collection reparenting, exact keyword-photo
lookup, current target-collection navigation/toggling, guarded virtual-copy rename/
removal, and metadata-preset enumeration/application. See
[Library expansion](docs/library-expansion.md) for exact scope and SDK limits.

## Shooting metadata (2.10)

`lr_get_metadata` now supports `fieldGroup: "capture"` for complete SDK-exposed
shooting metadata: shutter, aperture, ISO, focal lengths, exposure/flash, camera
serial, metering/program, timestamps, GPS and image dimensions. Numeric values
retain SDK units; display-only fields retain localized text. `fieldGroup: "all"`
reads every supported field; explicit `fields` remains available. Existing default
fields are unchanged. Missing values and getter errors are reported separately.
See [Shooting metadata](docs/capture-metadata.md) for fields, units and validation
limits. Python and plugin versions are 2.10.0; the tool count remains **104**.

## Smart previews and relative batch adjustments (2.11)

Six tools bring the total to **110**. Inspect original availability and smart
previews, create/delete previews through cancellable session jobs, and apply
explicit per-photo deltas without flattening differences between photos.
Color Grading documentation now groups the existing `SplitToning` controls with
the other color wheels. See [preview and relative workflows](docs/preview-and-relative.md)
and [color grading](docs/color-grading.md) for examples and verification limits.

## Available tools

| Tool                      | What it does                                                  |
| ------------------------- | ------------------------------------------------------------- |
| `lr_ping`                 | Check the connection is working                               |
| `lr_get_settings`         | Read all current develop slider values + filename + rating    |
| `lr_apply_settings`       | Apply develop parameters to the selected photo                |
| `lr_export_preview`       | Export a JPEG preview; AI client sees the photo inline        |
| `lr_batch_apply_settings` | Apply develop parameters to **all** currently selected photos |
| `lr_auto_tone`            | Run Lightroom's Auto Tone                                     |
| `lr_reset`                | Reset all develop settings to defaults                        |
| `lr_crop`                 | Crop and/or straighten the selected photo                     |
| `lr_add_mask`             | Add a mask with optional local adjust sliders (subject, sky, gradient…) |
| `lr_update_mask`          | Update local sliders on a specified or currently selected mask |
| `lr_list_masks`           | List masks, component tools and selected IDs |
| `lr_get_selected_mask`    | Read selected IDs and available local sliders |
| `lr_select_mask`          | Select a mask and optionally one of its component tools |
| `lr_delete_mask`          | Delete an explicit mask ID and verify removal |
| `lr_delete_mask_tool`     | Delete a component tool within its specified parent mask |
| `lr_lens_blur`            | Apply AI Lens Blur with bokeh shape control                   |
| `lr_enhance`              | Run AI Denoise, Super Resolution, or Raw Details              |
| `lr_list_snapshots` | List current photo snapshots and their IDs |
| `lr_create_snapshot` | Save current edits as a named snapshot |
| `lr_apply_snapshot` | Restore an explicit snapshot |
| `lr_delete_snapshot` | Delete an explicit snapshot and verify removal |
| `lr_list_virtual_copies` | List the master and its virtual copies |
| `lr_create_virtual_copies` | Create named copies of the current or selected photos |
| `lr_select_virtual_copy` | Switch to a master/copy in the current family |
| `lr_list_presets` | Search and paginate SDK-visible develop presets |
| `lr_apply_preset` | Apply a preset by UUID to the current or selected photos |
| `lr_combine_mask` | Add, subtract or intersect a new component on an explicit mask |
| `lr_set_mask_visibility` | Set hidden state of a mask or child tool |
| `lr_invert_mask` | Invert a whole mask once |
| `lr_duplicate_inverted_mask` | Duplicate and invert a mask |
| `lr_set_mask_tool_inverted` | Set an explicit child tool's inversion state |
| `lr_auto_white_balance` | Run automatic white balance and read actual values |
| `lr_get_curve` | Read a global/local RGB or channel point curve |
| `lr_set_curve` | Set and verify a global/local point curve |
| `lr_list_point_colors` | Read global/local point-color swatches |
| `lr_add_point_color` | Add/select a source-color swatch |
| `lr_update_point_color` | Update a guarded swatch index |
| `lr_delete_point_color` | Delete one guarded swatch and verify remaining entries |
| `lr_get_selection` | Read active/selected photo UUIDs and catalog context |
| `lr_search_photos` | Search native metadata filters with pagination |
| `lr_select_photos` | Select explicit UUIDs and verify the result |
| `lr_get_metadata` | Read metadata and direct keyword assignments |
| `lr_set_metadata` | Set/clear supported metadata and verify each photo |
| `lr_list_keywords` | Enumerate keyword hierarchy and IDs |
| `lr_create_keyword` | Create a keyword under an optional parent |
| `lr_update_keyword` | Update name, synonyms or export flag |
| `lr_update_photo_keywords` | Add/remove explicit keyword assignments |
| `lr_list_collections` | Enumerate standard/smart collections and sets |
| `lr_create_collection` | Create a collection, smart collection or set |
| `lr_update_collection` | Rename or update smart-collection filters |
| `lr_update_collection_photos` | Add/remove standard-collection members |
| `lr_delete_collection` | Delete a collection definition, retaining photos |
| `lr_export_photos` | Start a native JPEG/TIFF file export job |
| `lr_get_export_status` | Read progress and actual per-photo output paths |
| `lr_cancel_export` | Cancel between photos, retaining completed files |
| `lr_get_smart_previews` | Read preview presence and original availability |
| `lr_build_smart_previews` | Start native smart-preview creation job |
| `lr_delete_smart_previews` | Start native smart-preview deletion job |
| `lr_get_smart_preview_job` | Inspect progress and per-photo results |
| `lr_cancel_smart_preview_job` | Request cancellation between photos |
| `lr_batch_adjust_relative` | Add deltas to each photo's own settings |

---

## Develop parameter reference

**Tone**

| Parameter  | Range       |
| ---------- | ----------- |
| Exposure   | -5 to 5     |
| Contrast   | -100 to 100 |
| Highlights | -100 to 100 |
| Shadows    | -100 to 100 |
| Whites     | -100 to 100 |
| Blacks     | -100 to 100 |
| Clarity    | -100 to 100 |
| Dehaze     | -100 to 100 |

**Color**

| Parameter   | Range        |
| ----------- | ------------ |
| Temperature | 2000–50000 K |
| Tint        | -150 to 150  |
| Vibrance    | -100 to 100  |
| Saturation  | -100 to 100  |

**HSL** (append Red / Orange / Yellow / Green / Aqua / Blue / Purple / Magenta)

| Parameter              | Range       |
| ---------------------- | ----------- |
| HueAdjustment\*        | -100 to 100 |
| SaturationAdjustment\* | -100 to 100 |
| LuminanceAdjustment\*  | -100 to 100 |

**Detail**

| Parameter           | Range   |
| ------------------- | ------- |
| Sharpness           | 0–150   |
| SharpenRadius       | 0.5–3.0 |
| SharpenDetail       | 0–100   |
| SharpenEdgeMasking  | 0–100   |
| LuminanceSmoothing  | 0–100   |
| ColorNoiseReduction | 0–100   |

**Effects**

| Parameter                | Range       |
| ------------------------ | ----------- |
| GrainAmount              | 0–100       |
| GrainSize                | 0–100       |
| PostCropVignetteAmount   | -100 to 100 |
| PostCropVignetteMidpoint | 0–100       |

**Transform**

| Parameter             | Range       |
| --------------------- | ----------- |
| PerspectiveVertical   | -100 to 100 |
| PerspectiveHorizontal | -100 to 100 |
| PerspectiveRotate     | -10 to 10   |
| PerspectiveScale      | 50–150      |
| PerspectiveAspect     | -100 to 100 |
| PerspectiveX/Y        | -100 to 100 |

**Color Grading**

| Parameter              | Range       |
| ---------------------- | ----------- |
| ColorGradeBlending     | 0–100       |
| ColorGradeGlobalHue    | 0–360       |
| ColorGradeGlobalLum    | -100 to 100 |
| ColorGradeGlobalSat    | 0–100       |
| ColorGradeMidtoneHue   | 0–360       |
| ColorGradeMidtoneLum   | -100 to 100 |
| ColorGradeMidtoneSat   | 0–100       |
| ColorGradeHighlightLum | -100 to 100 |
| ColorGradeShadowLum    | -100 to 100 |
| SplitToningHighlightHue | 0–360 |
| SplitToningHighlightSaturation | 0–100 |
| SplitToningShadowHue | 0–360 |
| SplitToningShadowSaturation | 0–100 |
| SplitToningBalance | -100 to 100 |

The SDK retains `SplitToning` names for the current Color Grading highlight/shadow
hue, saturation and balance controls. They are not limited to the old Split Toning
panel. `ColorGradeHighlightHue/Sat`, `ColorGradeShadowHue/Sat` and
`ColorGradeBalance` are not registered native keys. Balance shifts the relative
influence of shadows/highlights; blending controls overlap. See
[Color grading verification](docs/color-grading.md).

**B&W Mix** (append Red / Orange / Yellow / Green / Aqua / Blue / Purple / Magenta)

| Parameter   | Range       |
| ----------- | ----------- |
| GrayMixer\* | -100 to 100 |

**Defringe**

| Parameter              | Range |
| ---------------------- | ----- |
| DefringeGreenAmount    | 0–100 |
| DefringeGreenHueHi/Lo  | 0–100 |
| DefringePurpleAmount   | 0–100 |
| DefringePurpleHueHi/Lo | 0–100 |

Parameter names are **case-insensitive**: `exposure` and `Exposure` both work; the plugin normalises registered numeric names. Use `lr_get_settings` for the actual mappings available on the current photo.

---

## Troubleshooting

**"Cannot connect to Lightroom" / ping fails**

- Confirm Lightroom Classic is open (not Lightroom CC)
- Check the plugin is **Enabled** in File → Plug-in Manager
- Try starting it manually: **File → Plug-in Extras → Start MCP Bridge Server** (available in any module)

**Lightroom tools not appearing in your AI tool**

- Confirm the paths in your MCP config are absolute and correct
- Confirm you're pointing to the **venv** Python, not the system Python
- Fully restart your AI tool (not just reload) after config changes
- Check your AI tool's MCP logs or developer console for connection errors
- Test the server directly: `cd mcp-server && venv/bin/python3 server.py` (should start silently)

**Edits not applying to the photo**

- A photo must be selected in Lightroom
- The plugin auto-switches to the Develop module but may need a moment
- If settings apply then revert, check Lightroom's History panel for conflicts

**`lr_export_preview` returns an error instead of an image**

- The thumbnail request can time out if Lightroom is busy building previews
- Try again after Lightroom finishes its initial preview render (progress bar in Library)

---

## Development

To test the MCP server without Lightroom open, use the included mock server:

```bash
cd mcp-server
python -m pip install --isolated -r requirements-dev.txt
python -m pytest tests/ -v             # starts isolated mock processes automatically
```

The mock simulates basic adjustments, previews, batch edits and stateful mask management. It does not implement crop, lens blur or enhance. Tests also execute the actual mask module under Lua 5.1 with SDK doubles and exercise MCP over stdio. Live Lightroom validation is still required; see the [manual acceptance steps](docs/mask-management.md#manual-lightroom-acceptance-not-covered-by-simulated-tests).

MCP is constrained to 1.x because the existing server uses its low-level decorator API. After upgrading, confirm the actual Lua plugin path in Lightroom Plug-in Manager and update that copy too. If Lightroom reports `Could not load toolkit script: Masking`, fully quit and reopen Lightroom to refresh its cached file list. Restart the MCP client to load the new tools. See [deployment notes](docs/mask-management.md#deployment-verify-the-loaded-plugin-path).

---

## Reference

- [Lightroom Classic SDK Guide](docs/Lightroom%20Classic%20SDK%20Guide.pdf): official Adobe SDK documentation covering all `LrDevelopController` APIs, plugin lifecycle, and Lua sandbox constraints.
