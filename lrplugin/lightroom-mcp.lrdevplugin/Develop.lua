-- Unified catalog-backed numeric develop settings for single and batch edits.
local Application = import "LrApplication"
local Controller = import "LrDevelopController"
local Tasks = import "LrTasks"
local Date = import "LrDate"
local Develop = {VERSION="2.13.0"}
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
    -- Color Grading highlights/shadows and balance retain SDK SplitToning names.
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
local relativeNames={}
for name in string.gmatch('Exposure Contrast Highlights Shadows Whites Blacks Clarity Texture Dehaze Vibrance Saturation Temperature Tint','%S+') do relativeNames[name]=true end
local function bounds(name,key,raw)
    if name=='Temperature' then if key=='IncrementalTemperature' then return -100,100 end;return 2000,50000 end
    if name=='Tint' then if key=='IncrementalTint' then return -100,100 end;return -150,150 end
    if name:match('^Crop') then if name=='CropAngle' then return -45,45 end;return 0,1 end
    if relativeNames[name] and finite(raw.Exposure2012) and (not tonumber(raw.ProcessVersion) or tonumber(raw.ProcessVersion)>=6.6) then
        if name=='Exposure' then return -5,5 end;return -100,100
    end
end
local function plan(photo, normalized, observed)
    requireAPI(photo, "applyDevelopSettings")
    if photo:getRawMetadata("isVideo") then fail("unsupported_photo", "Video develop writes are not supported") end
    local raw = observed or snapshot(photo)
    local settings, keys, before, ranges, unchecked = {}, {}, {}, {}, {}
    for name, value in pairs(normalized) do
        local key = resolve(name, raw)
        if not key then fail("unsupported_parameter", name .. " has no supported numeric mapping on this photo", {photoId=photoId(photo), parameter=name}) end
        if keys[key] then fail("invalid_arguments", "Parameters address the same catalog key: " .. key) end
        keys[key] = name;before[name]=readValue(raw,key)
        local low,high=bounds(name,key,raw)
        if type(raw[key])=='boolean' then low,high=0,1 end
        if low then
            ranges[name]={minimum=low,maximum=high}
            if value<low or value>high then fail('out_of_range','Target outside supported bounds',{photoId=photoId(photo),parameter=name,before=before[name],target=value,minimum=low,maximum=high}) end
        else unchecked[#unchecked+1]=name end
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
    return {photo=photo, settings=settings, keys=keys, photoId=photoId(photo),before=before,processVersion=raw.ProcessVersion,checkedRanges=ranges,uncheckedRanges=unchecked}
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
    if not target and not req.photoIds then fail("no_photo", "No photo selected") end
    if not req.photoIds then checkTarget(target, req.expectedPhotoId) end
    local normalized = normalize(req.settings)
    local photos = batch and catalog:getTargetPhotos() or {target}
    local context,Library
    if req.photoIds~=nil or req.scope~=nil or req.expectedCatalogPath~=nil then
        Library=require 'Library';context=Library.context(req)
        local targeting=Library.clone(req)
        if batch and targeting.photoIds==nil and targeting.scope==nil then targeting.scope='selected' end
        photos=Library.targets(context,targeting)
    end
    local function guard()
        if context then
            Library.check(context)
            for _,p in ipairs(photos) do if catalog:findPhotoByUuid(photoId(p))~=p then fail('photo_not_found','Target photo disappeared') end end
        else checkTarget(target,req.expectedPhotoId) end
    end
    if not photos or #photos == 0 then fail("no_photo", "No photos selected") end
    if #photos>200 then fail('batch_too_large','At most 200 photos per call') end
    -- Preflight the complete batch before any write. Capture photo objects so UI
    -- changes cannot redirect later edits to an unrelated photo.
    local plans = {}
    for _, photo in ipairs(photos) do plans[#plans+1] = plan(photo, normalized) end
    guard()
    local results, applied = {}, 0
    for _, item in ipairs(plans) do
        local result = {photoId=item.photoId, success=false}
        results[#results+1] = result
        local ok, err = Tasks.pcall(function()
            guard()
            local entered = false
            catalog:withWriteAccessDo("MCP Develop Settings", function()
                entered = true
                guard()
                result.writeAttempted=true
                item.photo:applyDevelopSettings(item.settings, "MCP Develop Settings")
            end, {timeout=5})
            if not entered then fail("write_timeout", "Catalog write access was not acquired") end
            local deadline = Date.currentTime() + 3
            repeat
                guard()
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
            result.outcomeUnknown=result.writeAttempted==true
            -- No rollback promise: some values may have changed before an SDK failure.
            local readOK, _, values = Tasks.pcall(function() guard();return readback(item, normalized) end)
            if readOK then result.settings = values end
            break
        end
        applied = applied + 1
    end
    local success = applied == #plans
    return {success=success, code=not success and "partial_failure" or nil,
        error=not success and "Stopped after a failed photo; inspect per-photo results before retrying" or nil,
        applied=applied, failed=success and 0 or 1, notAttempted=#plans-#results,
        data={photoId=target and photoId(target) or nil, catalogPath=context and context.path or nil, settings=#plans==1 and results[1].settings or nil, results=results}}
end
local function object() return setmetatable({}, {__jsontype='object'}) end
local function parameterList(requested)
    if requested==nil then return PARAMETERS end
    if type(requested)~='table' or #requested<1 or #requested>150 then fail('invalid_arguments','parameters must contain 1-150 names') end
    local list,seen={},{}
    for i,name in pairs(requested) do
        if type(i)~='number' or i%1~=0 or i<1 or i>#requested then fail('invalid_arguments','parameters must be an array') end
        local canonical=type(name)=='string' and index[name:lower()]
        if not canonical then fail('unsupported_parameter','Unknown parameter: '..tostring(name)) end
        if seen[canonical] then fail('invalid_arguments','Duplicate parameter: '..canonical) end
        seen[canonical]=true;list[i]=canonical
    end
    return list
end
local function readPhoto(photo,req,names)
    local raw,settings,mapping,unavailable=snapshot(photo),object(),object(),{}
    for _,name in ipairs(names) do
        local key=resolve(name,raw)
        if key then settings[name]=readValue(raw,key);mapping[name]=key
        else unavailable[#unavailable+1]=name end
    end
    return {photoId=photoId(photo),filename=photo:getFormattedMetadata('fileName'),
        rating=photo:getRawMetadata('rating'),processVersion=raw.ProcessVersion,
        settings=settings,parameterKeys=mapping,unavailableParameters=unavailable,
        rawSettings=req.includeRaw and raw or nil}
end
local function get(req)
    if req.includeRaw~=nil and type(req.includeRaw)~='boolean' then fail('invalid_arguments','includeRaw must be boolean') end
    local names=parameterList(req.parameters)
    if req.photoIds==nil and req.scope==nil and req.expectedCatalogPath==nil then
        local photo=Application.activeCatalog():getTargetPhoto()
        if not photo then fail('no_photo','No photo selected') end
        checkTarget(photo,req.expectedPhotoId)
        local row=readPhoto(photo,req,names);checkTarget(photo,req.expectedPhotoId)
        return {success=true,data=row}
    end
    local Library=require 'Library'
    local c=Library.context(req);local photos=Library.targets(c,req);local rows,failed={},0
    for _,photo in ipairs(photos) do
        Library.check(c)
        local ok,row=Tasks.pcall(function()return readPhoto(photo,req,names)end)
        Library.check(c)
        if ok then row.success=true else
            failed=failed+1
            row={photoId=photoId(photo),success=false,code=type(row)=='table' and row.code or 'sdk_error',error=type(row)=='table' and row.error or tostring(row)}
        end
        rows[#rows+1]=row
    end
    if req.photoIds==nil and req.scope==nil and failed==0 then
        rows[1].catalogPath=c.path;return {success=true,data=rows[1]}
    end
    return {success=failed==0,code=failed>0 and 'partial_failure' or nil,
        data={catalogPath=c.path,total=#photos,read=#photos-failed,failed=failed,photos=rows}}
end
-- Exact per-photo deltas on the existing catalog-backed numeric API. Quick
-- Develop's small/large buttons have different semantics and are not used here.
local function relativePlan(photo,deltas,observed)
    local units={}
    local raw=observed or snapshot(photo)
    if not finite(raw.Exposure2012) or (tonumber(raw.ProcessVersion) and tonumber(raw.ProcessVersion)<6.6) then fail('unsupported_process_version','Relative adjustments require modern process settings (Exposure2012)') end
    local before,target,keys={},{},{}
    for name,delta in pairs(deltas) do
        local key=resolve(name,raw)
        if not key or not finite(raw[key]) then fail('unsupported_parameter','No numeric mapping for '..name) end
        local unit=(name=='Temperature' or name=='Tint') and key or name
        units[name]=unit
        local low,high=bounds(name,key,raw)
        before[name]=raw[key];target[name]=raw[key]+delta;keys[name]=key
        if not finite(target[name]) or target[name]<low or target[name]>high then
            fail('out_of_range','Relative target outside supported range; no clamping',
                {photoId=photoId(photo),parameter=name,before=raw[key],target=target[name],minimum=low,maximum=high})
        end
    end
    local item=plan(photo,target,raw)
    -- A zero WB delta must not switch Auto/As Shot to Custom when another
    -- parameter is changed in the same request.
    for name,delta in pairs(deltas) do if delta==0 then item.settings[keys[name]]=nil end end
    if (deltas.Temperature or 0)==0 and (deltas.Tint or 0)==0 then item.settings.WhiteBalance=nil end
    item.before=before;item.target=target;item.parameterKeys=keys
    item.processVersion=raw.ProcessVersion;item.whiteBalance=raw.WhiteBalance
    item.units=units;return item
end
local function unitIssue(plans)
    local units={}
    for _,item in ipairs(plans) do for name,unit in pairs(item.units or {}) do
        if units[name] and units[name]~=unit then return {code='mixed_parameter_units',parameter=name,error='Split RAW and rendered white-balance adjustments into separate batches'} end
        units[name]=unit
    end end
end

local function relative(req)
    local Library=require 'Library'
    local c=Library.context(req);local photos=Library.targets(c,req)
    local deltas=normalize(req.deltas)
    for name in pairs(deltas) do if not relativeNames[name] then fail('unsupported_parameter','Not an additive parameter: '..name) end end
    local plans={}
    for _,photo in ipairs(photos) do
        Library.check(c);plans[#plans+1]=relativePlan(photo,deltas)
    end
    local issue=unitIssue(plans);if issue then fail(issue.code,issue.error) end
    Library.check(c)
    local results,applied={},0
    for _,item in ipairs(plans) do
        local row={photoId=item.photoId,success=false,before=item.before,target=item.target,parameterKeys=item.parameterKeys}
        results[#results+1]=row
        local ok,err=Tasks.pcall(function()
            local entered=false
            c.catalog:withWriteAccessDo('MCP Relative Adjustments',function()
                Library.check(c)
                if c.catalog:findPhotoByUuid(item.photoId)~=item.photo then fail('photo_not_found','Target photo no longer exists') end
                local now=item.photo:getDevelopSettings()
                if now.ProcessVersion~=item.processVersion or
                   ((deltas.Temperature or deltas.Tint) and now.WhiteBalance~=item.whiteBalance) then
                    fail('settings_changed','Process version or white balance changed after preflight')
                end
                local changed=false
                for name,key in pairs(item.parameterKeys) do
                    if not finite(now[key]) or math.abs(now[key]-item.before[name])>.0001 then fail('settings_changed','Target values changed after preflight') end
                    if item.target[name]~=item.before[name] then changed=true end
                end
                entered=true
                if changed then
                    row.writeAttempted=true
                    item.photo:applyDevelopSettings(item.settings,'MCP Relative Adjustments')
                end
                row.status=changed and 'applied' or 'unchanged'
            end,{timeout=5})
            if not entered then fail('write_timeout','Catalog write access was not acquired') end
            local deadline=Date.currentTime()+3
            repeat
                Library.check(c)
                local matches,values=readback(item,item.target);row.after=values
                if matches then row.success=true;return end
                Tasks.sleep(.05)
            until Date.currentTime()>=deadline
            fail('readback_failed','Relative target was not retained; inspect actual values before retrying')
        end)
        if not ok then
            row.code=type(err)=='table' and err.code or 'sdk_error'
            row.error=type(err)=='table' and err.error or tostring(err)
            row.outcomeUnknown=row.writeAttempted==true
            local readOK,_,values=Tasks.pcall(function() Library.check(c);return readback(item,item.target) end)
            if readOK then row.after=values end
            break
        end
        applied=applied+1
    end
    local success=applied==#plans
    return {success=success,code=not success and 'partial_failure' or nil,
        error=not success and 'Stopped on first failure; no rollback or automatic retry' or nil,
        applied=applied,failed=success and 0 or 1,notAttempted=#plans-#results,
        data={catalogPath=c.path,results=results,deltas=deltas,verification='numeric_readback'}}
end

local function preflight(req)
    local Library=require 'Library'
    local c=Library.context(req);local photos=Library.targets(c,req)
    local mode=req.mode or 'absolute'
    if mode~='absolute' and mode~='relative' then fail('invalid_arguments','Invalid preflight mode') end
    if (mode=='absolute' and (req.deltas~=nil or req.settings==nil)) or
       (mode=='relative' and (req.settings~=nil or req.deltas==nil)) then fail('invalid_arguments','Use settings for absolute or deltas for relative') end
    local normalized=normalize(mode=='absolute' and req.settings or req.deltas)
    if mode=='relative' then for name in pairs(normalized) do if not relativeNames[name] then fail('unsupported_parameter','Not an additive parameter: '..name) end end end
    local rows,plans,blocked={}, {},0
    for _,photo in ipairs(photos) do
        Library.check(c)
        local row={photoId=photoId(photo),ready=false}
        local ok,err=Tasks.pcall(function()
            local raw=snapshot(photo)
            row.processVersion=raw.ProcessVersion
            row.before=object();row.parameterKeys=object();row.unavailableParameters={}
            for name in pairs(normalized) do
                local key=resolve(name,raw)
                if key then row.before[name]=readValue(raw,key);row.parameterKeys[name]=key
                else row.unavailableParameters[#row.unavailableParameters+1]=name end
            end
            table.sort(row.unavailableParameters)
            local item=mode=='relative' and relativePlan(photo,normalized,raw) or plan(photo,normalized,raw)
            row.target=mode=='relative' and item.target or Library.clone(normalized)
            row.catalogChanges=next(item.settings) and Library.clone(item.settings) or object()
            row.checkedRanges=next(item.checkedRanges) and item.checkedRanges or object();row.uncheckedRanges=item.uncheckedRanges
            table.sort(row.uncheckedRanges)
            row.ready=true;plans[#plans+1]=item
        end)
        Library.check(c)
        if not ok then
            blocked=blocked+1;row.code=type(err)=='table' and err.code or 'sdk_error'
            row.error=type(err)=='table' and err.error or tostring(err);row.details=type(err)=='table' and err.data or nil
        end
        rows[#rows+1]=row
    end
    local issues={};local issue=unitIssue(plans);if issue then issues[1]=issue end
    return {success=true,data={mode=mode,catalogPath=c.path,total=#photos,readyCount=#photos-blocked,blockedCount=blocked,
        canApply=blocked==0 and #issues==0,photos=rows,batchIssues=issues,readOnly=true,
        validationScope='existing_execution_preflight',
        note='Observation only, not a reservation or rendering guarantee. Execution rechecks state. Known numeric bounds, crop geometry and boolean constraints are checked. uncheckedRanges lists controls without per-photo range validation; native clamping/rendering is not guaranteed.'}}
end

function Develop.captureStyle(photo,names,curve)
    if photo:getRawMetadata('isVideo') then fail('unsupported_photo','Styles require a photo') end
    local raw=snapshot(photo);local settings={}
    if type(raw.ProcessVersion)~='string' then fail('settings_unavailable','Process version unavailable') end
    for _,requested in ipairs(names) do
        local name=index[requested:lower()]
        local key=name and resolve(name,raw)
        if not key then fail('unsupported_parameter','Unavailable style parameter: '..requested) end
        settings[key]=raw[key]
    end
    if settings.Temperature~=nil or settings.Tint~=nil or settings.IncrementalTemperature~=nil or settings.IncrementalTint~=nil then
        settings.WhiteBalance='Custom'
    end
    if curve then
        for _,key in ipairs({'ToneCurvePV2012','ToneCurvePV2012Red','ToneCurvePV2012Green','ToneCurvePV2012Blue'}) do
            local points=raw[key]
            if type(points)~='table' or #points<4 or #points>64 or #points%2~=0 then fail('unsupported_curve','Unavailable RGB point curve: '..key) end
            settings[key]={}
            for i,v in ipairs(points) do
                if not finite(v) or v<0 or v>255 or (i%2==1 and i>1 and v<=points[i-2]) then fail('unsupported_curve','Invalid point curve') end
                settings[key][i]=v
            end
        end
    end
    return settings,raw.ProcessVersion
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
        if req.command == "preflight_settings" then return preflight(req) end
        if req.command == "batch_adjust_relative" then return relative(req) end
        return apply(req, req.command == "batch_apply_settings")
    end)
    if ok then return result end
    return type(result) == "table" and result or {success=false, code="sdk_error", error=tostring(result)}
end
return Develop
