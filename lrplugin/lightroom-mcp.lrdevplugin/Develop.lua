-- Unified catalog-backed numeric develop settings for single and batch edits.
local Application = import "LrApplication"
local Controller = import "LrDevelopController"
local Tasks = import "LrTasks"
local Date = import "LrDate"
local Develop = {VERSION="2.0.0"}
local PARAMETERS = {
    -- Additional documented numeric controls
    "ShadowTint", "RedHue", "RedSaturation", "GreenHue", "GreenSaturation", "BlueHue", "BlueSaturation",
    "LuminanceNoiseReductionContrast", "PostCropVignetteStyle", "PostCropVignetteHighlightContrast",
    "LensProfileDistortionScale", "LensProfileVignettingScale", "LensManualDistortionAmount",
    "CurveRefineSaturation", "PresetAmount", "ProfileAmount",
    -- Tone
    "Exposure", "Contrast", "Highlights", "Shadows", "Whites", "Blacks",
    "Brightness", "Recovery", "FillLight",
    -- Presence
    "Clarity", "Texture", "Dehaze", "Vibrance", "Saturation",
    -- White Balance
    "Temperature", "Tint",
    -- Tone Curve
    "ParametricDarks", "ParametricLights", "ParametricShadows", "ParametricHighlights",
    "ParametricShadowSplit", "ParametricMidtoneSplit", "ParametricHighlightSplit",
    -- HSL
    "HueAdjustmentRed", "HueAdjustmentOrange", "HueAdjustmentYellow",
    "HueAdjustmentGreen", "HueAdjustmentAqua", "HueAdjustmentBlue",
    "HueAdjustmentPurple", "HueAdjustmentMagenta",
    "SaturationAdjustmentRed", "SaturationAdjustmentOrange", "SaturationAdjustmentYellow",
    "SaturationAdjustmentGreen", "SaturationAdjustmentAqua", "SaturationAdjustmentBlue",
    "SaturationAdjustmentPurple", "SaturationAdjustmentMagenta",
    "LuminanceAdjustmentRed", "LuminanceAdjustmentOrange", "LuminanceAdjustmentYellow",
    "LuminanceAdjustmentGreen", "LuminanceAdjustmentAqua", "LuminanceAdjustmentBlue",
    "LuminanceAdjustmentPurple", "LuminanceAdjustmentMagenta",
    -- Detail
    "Sharpness", "SharpenRadius", "SharpenDetail", "SharpenEdgeMasking",
    "LuminanceSmoothing", "LuminanceNoiseReductionDetail",
    "ColorNoiseReduction", "ColorNoiseReductionDetail", "ColorNoiseReductionSmoothness",
    -- Lens
    "LensProfileEnable", "AutoLateralCA",
    "VignetteAmount", "VignetteMidpoint",
    -- Transform
    "PerspectiveVertical", "PerspectiveHorizontal",
    "PerspectiveRotate", "PerspectiveScale",
    "PerspectiveAspect", "PerspectiveX", "PerspectiveY", "PerspectiveUpright",
    -- Crop
    "CropAngle", "CropTop", "CropBottom", "CropLeft", "CropRight",
    -- Effects
    "PostCropVignetteAmount", "PostCropVignetteMidpoint",
    "PostCropVignetteFeather", "PostCropVignetteRoundness",
    "GrainAmount", "GrainSize", "GrainFrequency",
    -- Color Grading (3-way color wheels)
    "ColorGradeBlending",
    "ColorGradeGlobalHue", "ColorGradeGlobalLum", "ColorGradeGlobalSat",
    "ColorGradeHighlightLum",
    "ColorGradeMidtoneHue", "ColorGradeMidtoneLum", "ColorGradeMidtoneSat",
    "ColorGradeShadowLum",
    -- B&W Mix
    "GrayMixerRed", "GrayMixerOrange", "GrayMixerYellow", "GrayMixerGreen",
    "GrayMixerAqua", "GrayMixerBlue", "GrayMixerPurple", "GrayMixerMagenta",
    -- Split Toning (legacy but still functional)
    "SplitToningBalance",
    "SplitToningHighlightHue", "SplitToningHighlightSaturation",
    "SplitToningShadowHue", "SplitToningShadowSaturation",
    -- Defringe
    "DefringeGreenAmount", "DefringeGreenHueHi", "DefringeGreenHueLo",
    "DefringePurpleAmount", "DefringePurpleHueHi", "DefringePurpleHueLo",
    -- Lens Blur (AI depth-of-field)
    "LensBlurActive", "LensBlurAmount", "LensBlurCatEye",
    "LensBlurFocalRange", "LensBlurHighlightsBoost",
}

local index = {}
for _, name in ipairs(PARAMETERS) do index[name:lower()] = name end

local function fail(code, message, data)
    error({success=false, code=code, error=message, data=data}, 0)
end
local function finite(value)
    return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end
local function requireAPI(object, name)
    if type(object[name]) ~= "function" then fail("unsupported_api", "Lightroom does not provide " .. name) end
end
local function snapshot(photo)
    requireAPI(photo, "getDevelopSettings")
    local raw
    Application.activeCatalog():withReadAccessDo(function() raw = photo:getDevelopSettings() end)
    if type(raw) ~= "table" then fail("settings_unavailable", "Develop settings are unavailable") end
    return raw
end
local function photoId(photo)
    return photo:getRawMetadata("uuid")
end
local function checkTarget(photo, expected)
    if Application.activeCatalog():getTargetPhoto() ~= photo then fail("photo_changed", "Photo selection changed") end
    if expected and photoId(photo) ~= expected then fail("photo_changed", "Photo does not match expectedPhotoId") end
end

-- Controller labels and catalog develop keys are different APIs. Resolve only
-- known mappings; never send a controller name blindly to applyDevelopSettings.
local modernKeys = {
    Exposure="Exposure2012", Contrast="Contrast2012", Highlights="Highlights2012",
    Shadows="Shadows2012", Whites="Whites2012", Blacks="Blacks2012", Clarity="Clarity2012",
}
local function resolve(name, raw)
    local key = name
    local process = tonumber(raw.ProcessVersion)
    local modern = (process and process >= 6.6) or (not process and raw.Exposure2012 ~= nil)
    if modernKeys[name] then
        if modern then key = modernKeys[name]
        elseif name == "Highlights" then key = "HighlightRecovery"
        elseif name == "Shadows" then key = "FillLight"
        elseif name == "Blacks" then key = "Shadows"
        elseif name == "Whites" then return nil
        end
    elseif name == "Recovery" then key = "HighlightRecovery"
    elseif name == "Temperature" and raw.IncrementalTemperature ~= nil then key = "IncrementalTemperature"
    elseif name == "Tint" and raw.IncrementalTint ~= nil then key = "IncrementalTint"
    end
    if modern and (name == "Brightness" or name == "Recovery" or name == "FillLight") then return nil end
    local value = raw[key]
    if finite(value) or type(value) == "boolean" then return key end
    -- Complex controls (e.g. focal ranges, point curves) are readable via rawSettings,
    -- but deliberately not advertised as numeric writable sliders.
    return nil
end
local function readValue(raw, key)
    if type(raw[key]) == "boolean" then return raw[key] and 1 or 0 end
    return raw[key]
end
local function normalize(settings)
    if type(settings) ~= "table" or next(settings) == nil then fail("invalid_arguments", "Non-empty settings object required") end
    local normalized = {}
    for key, value in pairs(settings) do
        local name = type(key) == "string" and index[key:lower()]
        if not name then fail("unsupported_parameter", "Unknown numeric parameter: " .. tostring(key)) end
        if normalized[name] ~= nil then fail("invalid_arguments", "Duplicate parameter: " .. name) end
        if not finite(value) then fail("invalid_arguments", name .. " must be a finite number") end
        if name:match("^Crop") then
            local low, high = 0, 1
            if name == "CropAngle" then low, high = -45, 45 end
            if value < low or value > high then fail("out_of_range", name .. " is outside its valid range") end
        end
        normalized[name] = value
    end
    return normalized
end
local function plan(photo, normalized)
    requireAPI(photo, "applyDevelopSettings")
    if photo:getRawMetadata("isVideo") then fail("unsupported_photo", "Video develop writes are not supported") end
    local raw = snapshot(photo)
    local settings, keys = {}, {}
    for name, value in pairs(normalized) do
        local key = resolve(name, raw)
        if not key then fail("unsupported_parameter", name .. " has no supported numeric mapping on this photo", {photoId=photoId(photo), parameter=name}) end
        if keys[key] then fail("invalid_arguments", "Parameters address the same catalog key: " .. key) end
        keys[key] = name
        if type(raw[key]) == "boolean" then
            if value ~= 0 and value ~= 1 then fail("out_of_range", name .. " requires 0 or 1") end
            settings[key] = value == 1
        else settings[key] = value end
    end
    local top, bottom = settings.CropTop or raw.CropTop, settings.CropBottom or raw.CropBottom
    local left, right = settings.CropLeft or raw.CropLeft, settings.CropRight or raw.CropRight
    if (settings.CropTop or settings.CropBottom or settings.CropLeft or settings.CropRight) and
        ((finite(top) and finite(bottom) and top >= bottom) or (finite(left) and finite(right) and left >= right)) then
        fail("invalid_arguments", "Crop bounds must have positive width and height")
    end
    if settings.Temperature ~= nil or settings.Tint ~= nil or settings.IncrementalTemperature ~= nil or settings.IncrementalTint ~= nil then
        settings.WhiteBalance = "Custom"
    end
    if settings.CropTop or settings.CropBottom or settings.CropLeft or settings.CropRight or settings.CropAngle then settings.HasCrop = true end
    return {photo=photo, settings=settings, keys=keys, photoId=photoId(photo)}
end
local function readback(item, normalized)
    local values, matches = {}, true
    local raw = snapshot(item.photo)
    for key, name in pairs(item.keys) do
        local value = readValue(raw, key)
        values[name] = value
        if not finite(value) or math.abs(value - normalized[name]) > 0.0001 then matches = false end
    end
    return matches, values
end
local function apply(req, batch)
    local catalog = Application.activeCatalog()
    local target = catalog:getTargetPhoto()
    if not target then fail("no_photo", "No photo selected") end
    checkTarget(target, req.expectedPhotoId)
    local normalized = normalize(req.settings)
    local photos = batch and catalog:getTargetPhotos() or {target}
    if not photos or #photos == 0 then fail("no_photo", "No photos selected") end
    -- Preflight the complete batch before any write. Capture photo objects so UI
    -- changes cannot redirect later edits to an unrelated photo.
    local plans = {}
    for _, photo in ipairs(photos) do plans[#plans+1] = plan(photo, normalized) end
    checkTarget(target, req.expectedPhotoId)
    local results, applied = {}, 0
    for _, item in ipairs(plans) do
        local result = {photoId=item.photoId, success=false}
        results[#results+1] = result
        local ok, err = Tasks.pcall(function()
            checkTarget(target, req.expectedPhotoId)
            local entered = false
            catalog:withWriteAccessDo("MCP Develop Settings", function()
                entered = true
                checkTarget(target, req.expectedPhotoId)
                item.photo:applyDevelopSettings(item.settings, "MCP Develop Settings")
            end, {timeout=5})
            if not entered then fail("write_timeout", "Catalog write access was not acquired") end
            local deadline = Date.currentTime() + 3
            repeat
                local matches, values = readback(item, normalized)
                result.settings = values
                if matches then result.success = true; return end
                Tasks.sleep(0.05)
            until Date.currentTime() >= deadline
            fail("readback_failed", "Lightroom did not retain all requested values; inspect returned settings")
        end)
        if not ok then
            result.code = type(err) == "table" and err.code or "sdk_error"
            result.error = type(err) == "table" and err.error or tostring(err)
            -- No rollback promise: some values may have changed before an SDK failure.
            local readOK, _, values = Tasks.pcall(function() return readback(item, normalized) end)
            if readOK then result.settings = values end
            break
        end
        applied = applied + 1
    end
    local success = applied == #plans
    return {success=success, code=not success and "partial_failure" or nil,
        error=not success and "Stopped after a failed photo; inspect per-photo results before retrying" or nil,
        applied=applied, failed=success and 0 or 1, notAttempted=#plans-#results,
        data={photoId=photoId(target), settings=not batch and results[1].settings or nil, results=results}}
end
local function get(req)
    local photo = Application.activeCatalog():getTargetPhoto()
    if not photo then fail("no_photo", "No photo selected") end
    checkTarget(photo, req.expectedPhotoId)
    local raw, settings, mapping, unavailable = snapshot(photo), {}, {}, {}
    for _, name in ipairs(PARAMETERS) do
        local key = resolve(name, raw)
        if key then settings[name] = readValue(raw, key); mapping[name] = key
        else unavailable[#unavailable+1] = name end
    end
    checkTarget(photo, req.expectedPhotoId)
    return {success=true, data={photoId=photoId(photo), filename=photo:getFormattedMetadata("fileName"),
        rating=photo:getRawMetadata("rating"), processVersion=raw.ProcessVersion,
        settings=settings, parameterKeys=mapping, unavailableParameters=unavailable,
        rawSettings=req.includeRaw and raw or nil}}
end
function Develop.capabilities()
    local apis = {}
    for _, name in ipairs({"setValue", "getValue", "getRange", "setAutoTone", "resetAllDevelopAdjustments",
        "getAllMasks", "getSelectedMask", "getSelectedMaskTool", "selectMask", "selectMaskTool",
        "createNewMask", "deleteMask", "deleteMaskTool", "goToMasking", "setEnhance", "setLensBlurBokeh",
        "setLensBlurFocalRangeFromSubject"}) do apis[name] = type(Controller[name]) == "function" end
    local photo = Application.activeCatalog():getTargetPhoto()
    local photoAPIs = {}
    if photo then
        for _, name in ipairs({"getDevelopSettings", "applyDevelopSettings", "requestJpegThumbnail"}) do
            photoAPIs[name] = type(photo[name]) == "function"
        end
    end
    return {lightroomVersion=Application.versionString(), capabilities={controllerAPIs=apis,
        photoAPIs=photo and photoAPIs or nil, photoSelected=photo ~= nil,
        numericParameters=PARAMETERS, settingsBackend="LrPhoto.applyDevelopSettings",
        note="API presence is not a guarantee of support on every photo. Use get_settings for photo-specific mappings."}}
end
function Develop.handle(req)
    local ok, result = Tasks.pcall(function()
        if req.command == "get_settings" then return get(req) end
        return apply(req, req.command == "batch_apply_settings")
    end)
    if ok then return result end
    return type(result) == "table" and result or {success=false, code="sdk_error", error=tostring(result)}
end
return Develop
