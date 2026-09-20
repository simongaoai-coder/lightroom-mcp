--[[
  Lightroom MCP Bridge - Server Module
  Uses file-based IPC to communicate with the Python MCP server.
  Python writes /tmp/lr_mcp_req.json; Lua polls, processes, writes /tmp/lr_mcp_res.json.
--]]

local LrTasks             = import "LrTasks"
local LrFileUtils         = import "LrFileUtils"
local LrDevelopController = import "LrDevelopController"
local LrApplication       = import "LrApplication"
local LrLogger            = import "LrLogger"

local REQ_FILE      = "/tmp/lr_mcp_req.json"
local RES_FILE      = "/tmp/lr_mcp_res.json"
local POLL_INTERVAL = 0.05  -- seconds
local VERSION       = "2.4.2"  -- keep in sync with Info.lua VERSION

-- ── Bundled JSON encoder/decoder (no LrJSON dependency) ─────────────────────
local function jsonEncodeValue(val)
    local t = type(val)
    if t == "nil" then
        return "null"
    elseif t == "boolean" then
        return val and "true" or "false"
    elseif t == "number" then
        if val ~= val then return "null" end
        return tostring(val)
    elseif t == "string" then
        return '"' .. val:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n'):gsub('\r', '\\r'):gsub('\t', '\\t') .. '"'
    elseif t == "table" then
        local meta = getmetatable(val)
        local isArray = not (type(meta) == "table" and meta.__jsontype == "object")
        local maxN = 0
        for k, _ in pairs(val) do
            if type(k) ~= "number" or k ~= math.floor(k) or k < 1 then
                isArray = false; break
            end
            if k > maxN then maxN = k end
        end
        if isArray and maxN == #val then
            local items = {}
            for _, v in ipairs(val) do items[#items+1] = jsonEncodeValue(v) end
            return "[" .. table.concat(items, ",") .. "]"
        else
            local items = {}
            for k, v in pairs(val) do
                items[#items+1] = '"' .. tostring(k) .. '":' .. jsonEncodeValue(v)
            end
            return "{" .. table.concat(items, ",") .. "}"
        end
    end
    return "null"
end

local function jsonEncode(val)
    return jsonEncodeValue(val)
end

local jsonDecodeValue  -- forward declaration

local function jsonSkipWS(s, i)
    while i <= #s and s:sub(i,i):match("%s") do i = i + 1 end
    return i
end

local function jsonDecodeString(s, i)
    i = i + 1
    local res = {}
    while i <= #s do
        local c = s:sub(i, i)
        if c == '"' then return table.concat(res), i + 1
        elseif c == '\\' then
            local e = s:sub(i+1, i+1)
            local map = { ['"']='"', ['\\']='\\', n='\n', r='\r', t='\t', ['/']='/' }
            res[#res+1] = map[e] or e
            i = i + 2
        else res[#res+1] = c; i = i + 1 end
    end
    error("Unterminated string")
end

local function jsonDecodeArray(s, i)
    i = i + 1
    local arr = {}
    i = jsonSkipWS(s, i)
    if s:sub(i,i) == ']' then return arr, i + 1 end
    while true do
        local v; v, i = jsonDecodeValue(s, i)
        arr[#arr+1] = v
        i = jsonSkipWS(s, i)
        local c = s:sub(i,i)
        if c == ']' then return arr, i + 1 end
        i = i + 1; i = jsonSkipWS(s, i)
    end
end

local function jsonDecodeObject(s, i)
    i = i + 1
    local obj = {}
    i = jsonSkipWS(s, i)
    if s:sub(i,i) == '}' then return obj, i + 1 end
    while true do
        i = jsonSkipWS(s, i)
        local k; k, i = jsonDecodeString(s, i)
        i = jsonSkipWS(s, i); i = i + 1; i = jsonSkipWS(s, i)
        local v; v, i = jsonDecodeValue(s, i)
        obj[k] = v
        i = jsonSkipWS(s, i)
        local c = s:sub(i,i)
        if c == '}' then return obj, i + 1 end
        i = i + 1
    end
end

jsonDecodeValue = function(s, i)
    i = jsonSkipWS(s, i)
    local c = s:sub(i,i)
    if     c == '"' then return jsonDecodeString(s, i)
    elseif c == '{' then return jsonDecodeObject(s, i)
    elseif c == '[' then return jsonDecodeArray(s, i)
    elseif c == 't' then return true,  i + 4
    elseif c == 'f' then return false, i + 5
    elseif c == 'n' then return nil,   i + 4
    else
        local num = s:match("^-?%d+%.?%d*[eE]?[+-]?%d*", i)
        if num then return tonumber(num), i + #num end
        error("Unexpected character: " .. c)
    end
end

local function jsonDecode(s)
    local val, _ = jsonDecodeValue(s, 1)
    return val
end

-- ── Base64 encoder ──────────────────────────────────────────────────────────
local _b64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

local function base64Encode(data)
    local result  = {}
    local len     = #data
    local padding = (3 - len % 3) % 3
    -- Process 3 bytes at a time without unpacking the whole string onto the stack
    for i = 1, len, 3 do
        local b1 = data:byte(i)     or 0
        local b2 = data:byte(i + 1) or 0
        local b3 = data:byte(i + 2) or 0
        local n  = b1 * 65536 + b2 * 256 + b3
        result[#result + 1] = _b64:sub(math.floor(n / 262144) % 64 + 1, math.floor(n / 262144) % 64 + 1)
        result[#result + 1] = _b64:sub(math.floor(n /   4096) % 64 + 1, math.floor(n /   4096) % 64 + 1)
        result[#result + 1] = _b64:sub(math.floor(n /     64) % 64 + 1, math.floor(n /     64) % 64 + 1)
        result[#result + 1] = _b64:sub(              n        % 64 + 1,               n        % 64 + 1)
    end
    local encoded = table.concat(result)
    -- Replace trailing padding chars
    if padding == 1 then
        return encoded:sub(1, #encoded - 1) .. "="
    elseif padding == 2 then
        return encoded:sub(1, #encoded - 2) .. "=="
    end
    return encoded
end

local log = LrLogger("LrMCPBridge")
log:enable("logfile")

Server = {}
Server._running = false
-- _clrb_gen is a persistent global (not inside Server{}) so it survives
-- each re-execution of this file via require "Server". This ensures the
-- generation counter actually evicts old polling tasks even when require
-- creates a fresh Server table.
_clrb_gen = (_clrb_gen or 0)

local Develop = require "Develop"
local Versions = require "Versions"
local function getCurrentPhoto()
    return LrApplication.activeCatalog():getTargetPhoto()
end

local function prepareController(api)
    if type(LrDevelopController[api]) ~= "function" then
        error({success=false, code="unsupported_api", error="Lightroom does not provide " .. api}, 0)
    end
    local photo = getCurrentPhoto()
    if not photo then error({success=false, code="no_photo", error="No photo selected"}, 0) end
    local View = import "LrApplicationView"
    if View.getCurrentModuleName() ~= "develop" then View.switchToModule("develop") end
    local elapsed = 0
    while View.getCurrentModuleName() ~= "develop" and elapsed < 5 do
        LrTasks.sleep(0.05)
        elapsed = elapsed + 0.05
    end
    if getCurrentPhoto() ~= photo then error({success=false, code="photo_changed", error="Photo selection changed"}, 0) end
    if View.getCurrentModuleName() ~= "develop" then error({success=false, code="context_timeout", error="Develop is not ready"}, 0) end
    return photo
end

local function applyAutoTone()
    prepareController("setAutoTone")
    LrDevelopController.setAutoTone()
    return true, "Auto tone applied"
end

local function resetAllSettings()
    prepareController("resetAllDevelopAdjustments")
    LrDevelopController.resetAllDevelopAdjustments()
    return true, "All develop settings reset"
end

local function exportPreview(size)
    log:info("exportPreview called size=" .. tostring(size))
    local photo = getCurrentPhoto()
    if not photo then return nil, "No photo selected" end

    local thumbSize = math.min(tonumber(size) or 1500, 2048)
    local jpegData  = nil

    -- This tool intentionally reads the preview cache rather than rendering a
    -- formal LrExportSession. Cached thumbnails may exceed the requested size.
    local catalog = LrApplication.activeCatalog()
    local sizes   = { thumbSize }
    if thumbSize > 640 then sizes[#sizes + 1] = 640 end
    if thumbSize > 240 then sizes[#sizes + 1] = 240 end

    for _, sz in ipairs(sizes) do
        local fired    = false
        local cbReason = nil
        catalog:withReadAccessDo(function()
            photo:requestJpegThumbnail(sz, sz, function(jpeg, reason)
                cbReason = tostring(reason)
                if jpeg then jpegData = jpeg end
                fired = true
            end)
        end)
        if not fired then
            local t = 0
            while not fired and t < 2.0 do
                LrTasks.sleep(0.05)
                t = t + 0.05
            end
        end
        log:info("requestJpegThumbnail size=" .. sz
            .. " fired=" .. tostring(fired)
            .. " hasData=" .. tostring(jpegData ~= nil)
            .. " reason=" .. tostring(cbReason))
        if jpegData then break end
    end

    if not jpegData or #jpegData < 3 then
        return nil, "Thumbnail unavailable — try building Standard previews in Lightroom"
    end

    -- Validate JPEG magic bytes; preview cache can occasionally return garbage.
    local b1, b2, b3 = jpegData:byte(1), jpegData:byte(2), jpegData:byte(3)
    if b1 ~= 0xFF or b2 ~= 0xD8 or b3 ~= 0xFF then
        return nil, string.format("Preview has unexpected format (%02X %02X %02X) — rebuild previews", b1, b2, b3)
    end

    log:info("exportPreview ok size=" .. #jpegData)
    -- getRawMetadata requires a read lock; fetch orientation here.
    local orientation = 1
    local catalog = LrApplication.activeCatalog()
    catalog:withReadAccessDo(function()
        local v = photo:getRawMetadata("orientation")
        log:info("getRawMetadata orientation=" .. tostring(v))
        if v then orientation = v end
    end)
    return base64Encode(jpegData), nil, orientation
end

local function cropPhoto(params)
    local settings = {}
    if params.angle ~= nil then settings.CropAngle = params.angle end
    for _, key in ipairs({"CropTop", "CropBottom", "CropLeft", "CropRight"}) do
        if params[key] ~= nil then settings[key] = params[key] end
    end
    return Develop.handle({command="apply_settings", settings=settings})
end

-- Mask management is isolated so the SDK workflow can be tested directly.
local Masking = require "Masking"
local Fine = require "Fine"
local Library = require "Library"
local Delivery = require "Delivery"
local Healing = require "Healing"

-- Valid bokeh shapes for Lens Blur
local BOKEH_TYPES = {
    Circle=true, SoapBubble=true, Blade=true, Ring=true, Anamorphic=true,
}

local function lensBlur(params)
    local photo = prepareController("setValue")
    local settings = {}
    if params.active ~= nil then settings.LensBlurActive = params.active and 1 or 0 end
    for key, param in pairs({amount="LensBlurAmount", catEye="LensBlurCatEye", highlightsBoost="LensBlurHighlightsBoost"}) do
        if params[key] ~= nil then settings[param] = params[key] end
    end
    -- Check optional APIs before any mutation.
    if params.bokeh ~= nil then
        if not BOKEH_TYPES[params.bokeh] then return false, "Invalid bokeh shape" end
        if type(LrDevelopController.setLensBlurBokeh) ~= "function" then
            error({success=false, code="unsupported_api", error="setLensBlurBokeh is unavailable"}, 0)
        end
    end
    if params.focalRangeFromSubject and type(LrDevelopController.setLensBlurFocalRangeFromSubject) ~= "function" then
        error({success=false, code="unsupported_api", error="setLensBlurFocalRangeFromSubject is unavailable"}, 0)
    end
    -- Lens blur is nested in catalog settings; use its documented controller
    -- API instead of pretending these are flat catalog keys.
    for param, value in pairs(settings) do
        local low, high = LrDevelopController.getRange(param)
        if type(low) ~= "number" or type(high) ~= "number" then
            error({success=false, code="unsupported_parameter", error="No range for " .. param}, 0)
        end
        if value < low or value > high then error({success=false, code="out_of_range", error=param .. " is out of range"}, 0) end
    end
    for param, value in pairs(settings) do
        if getCurrentPhoto() ~= photo then error({success=false, code="photo_changed", error="Selected photo changed"}, 0) end
        LrDevelopController.setValue(param, value)
        local matched = false
        for attempt=1,60 do
            if getCurrentPhoto() ~= photo then error({success=false, code="photo_changed", error="Selected photo changed"}, 0) end
            local current = LrDevelopController.getValue(param)
            if type(current) == "boolean" then current = current and 1 or 0 end
            if type(current) == "number" and math.abs(current-value) < 0.0001 then matched=true; break end
            LrTasks.sleep(0.05)
        end
        if not matched then error({success=false, code="readback_failed", error="Lens blur did not retain " .. param}, 0) end
    end
    if getCurrentPhoto() ~= photo then error({success=false, code="photo_changed", error="Selected photo changed"}, 0) end
    if params.bokeh then LrDevelopController.setLensBlurBokeh(params.bokeh) end
    if params.focalRangeFromSubject then LrDevelopController.setLensBlurFocalRangeFromSubject() end
    return true, "Lens blur settings applied; depth processing may continue in Lightroom"
end

local function enhancePhoto(params)
    prepareController("setEnhance")
    local catalog = LrApplication.activeCatalog()
    local photo = getCurrentPhoto()
    if not photo then return false, "No photo selected" end

    -- Build the enhance options table
    local opts = {}
    if params.denoise ~= nil then
        opts.denoise = params.denoise and true or false
    end
    if params.denoiseAmount ~= nil then
        opts.denoiseAmount = tonumber(params.denoiseAmount)
    end
    if params.superRes ~= nil then
        opts.superRes = params.superRes and true or false
    end
    if params.rawDetails ~= nil then
        opts.rawDetails = params.rawDetails and true or false
    end

    if next(opts) == nil then
        return false, "No enhance options provided. Use: denoise, denoiseAmount (0-100), superRes, rawDetails"
    end

    local ok2, err2 = LrTasks.pcall(function()
        catalog:withWriteAccessDo("Enhance", function()
            LrDevelopController.setEnhance(opts)
        end, {timeout = 30})
    end)
    if not ok2 then
        return false, "Enhance failed: " .. tostring(err2)
    end

    local parts = {}
    for k, v in pairs(opts) do
        parts[#parts+1] = k .. "=" .. tostring(v)
    end
    return true, "Enhance triggered: " .. table.concat(parts, ", ") ..
        ". Note: AI Denoise/Super Resolution may take time to complete in the background."
end

local function dispatch(req)
    local cmd = req.command
    local response = {}

    if Healing.commands[cmd] then
        return Healing.handle(req)
    elseif Library.commands[cmd] then
        return Library.handle(req)
    elseif Delivery.commands[cmd] then
        return Delivery.handle(req)
    elseif Fine.commands[cmd] then
        return Fine.handle(req)
    elseif Versions.commands[cmd] then
        return Versions.handle(req)
    elseif Masking.commands[cmd] then
        return Masking.handle(req)
    elseif cmd == "ping" then
        response = Develop.capabilities()
        response.success = true
        response.version = VERSION
        response.maskingVersion = Masking.VERSION
        response.developVersion = Develop.VERSION
        response.versionsVersion = Versions.VERSION
        response.fineVersion = Fine.VERSION
        response.libraryVersion = Library.VERSION
        response.healingVersion = Healing.VERSION
        response.capabilities.healing = Healing.capabilities()
        response.deliveryVersion = Delivery.VERSION
        response.capabilities.library = Library.capabilities()
        response.capabilities.delivery = Delivery.capabilities()
        response.capabilities.fine = Fine.capabilities()
        response.capabilities.versions = Versions.capabilities()
        response.pluginPath = _PLUGIN.path
        response.protocolVersion = 2

    elseif cmd == "apply_settings" or cmd == "get_settings" or cmd == "batch_apply_settings" then
        response = Develop.handle(req)

    elseif cmd == "auto_tone" then
        local s, msg = applyAutoTone()
        response = { success = s, message = msg }

    elseif cmd == "reset" then
        local s, msg = resetAllSettings()
        response = { success = s, message = msg }

    elseif cmd == "export_preview" then
        local b64, err, orientation = exportPreview(req.size)
        if b64 then
            response = { success = true, data = b64, orientation = orientation }
        else
            response = { success = false, error = err }
        end

    elseif cmd == "crop" then
        response = cropPhoto(req.params or {})

    elseif cmd == "lens_blur" then
        local s, msg = lensBlur(req.params or {})
        response = { success = s, message = msg }

    elseif cmd == "enhance" then
        local s, msg = enhancePhoto(req.params or {})
        response = { success = s, message = msg }

    else
        response = { success = false, error = "Unknown command: " .. tostring(cmd) }
    end

return response
end

function Server.handleRequest(data)
    local decoded, req = pcall(jsonDecode, data)
    if not decoded or type(req) ~= "table" then
        return jsonEncode({success=false, code="invalid_request", error="Expected a JSON object"})
    end
    local ok, response = LrTasks.pcall(function()
        if req.command ~= "ping" and req.expectedPluginVersion ~= VERSION then
            return {success=false, code="version_mismatch", error="Restart/update both MCP server and Lightroom plugin", version=VERSION}
        end
        return dispatch(req)
    end)
    if not ok then
        response = type(response) == "table" and response or {success=false, code="sdk_error", error=tostring(response)}
    end
    if response.success == false and not response.code then response.code = "operation_failed" end
    response.requestId = req.requestId
    return jsonEncode(response)
end

function Server.start()
    -- Bump the persistent global generation counter so any currently-running
    -- loop self-terminates on its next iteration. Using a global (not Server._generation)
    -- ensures tasks from a previous require "Server" call (which created a fresh Server{})
    -- are also evicted — they still read _clrb_gen from the shared Lua environment.
    _clrb_gen = _clrb_gen + 1
    local myGeneration = _clrb_gen
    Server._running    = true

    -- Clean up any stale files from a previous run
    LrFileUtils.delete(REQ_FILE)
    LrFileUtils.delete(RES_FILE)
    log:info("LR MCP Bridge v" .. VERSION .. " started (file IPC mode), masking=" .. tostring(Masking.VERSION))

    local PROC_FILE = REQ_FILE .. ".processing"
    while Server._running and _clrb_gen == myGeneration do
        -- Atomic rename: only one polling loop can claim each request file.
        -- LrFileUtils.move returns true/false (no throw), so check return value directly.
        if LrFileUtils.exists(REQ_FILE) and LrFileUtils.move(REQ_FILE, PROC_FILE) then
            local f = io.open(PROC_FILE, "r")
            local data = f and f:read("*a")
            if f then f:close() end
            LrFileUtils.delete(PROC_FILE)

            if data and #data > 0 then
                local responseStr = Server.handleRequest(data)
                log:info("Writing response len=" .. #responseStr)
                local rf = io.open(RES_FILE .. ".tmp", "w")
                if rf then
                    rf:write(responseStr)
                    rf:close()
                    LrFileUtils.move(RES_FILE .. ".tmp", RES_FILE)
                    log:info("Response written OK")
                else
                    log:error("Failed to open RES_FILE for writing")
                end
            end
        end
        LrTasks.sleep(POLL_INTERVAL)
    end

    log:info("LR MCP Bridge stopped")
end

function Server.stop()
    Server._running = false
end

return Server
