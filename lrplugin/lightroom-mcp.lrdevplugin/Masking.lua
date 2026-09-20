-- Public SDK mask operations. Never use catalog write gates around masking UI calls.
local Controller = import "LrDevelopController"
local Tasks = import "LrTasks"
local Application = import "LrApplication"
local View = import "LrApplicationView"
local Date = import "LrDate"
local Masking = {VERSION="2.2.2"}
Masking.commands = {
    list_masks=true, get_selected_mask=true, select_mask=true, update_mask=true,
    delete_mask=true, delete_mask_tool=true, add_mask=true,
    combine_mask=true, set_mask_visibility=true, invert_mask=true, duplicate_inverted_mask=true, set_mask_tool_inverted=true,
}
local params = {}
for name in string.gmatch("Exposure Contrast Highlights Shadows Whites Blacks Clarity Texture Dehaze Vibrance Saturation Temperature Tint Sharpness LuminanceNoise ColorNoise Moire Defringe ToningHue ToningSaturation Hue Amount Grain RefineSaturation", "%S+") do
    params[name:lower()] = "local_" .. name
end
params.moirefilter = "local_Moire"
local ai = {subject=true, sky=true, background=true, objects=true, people=true, landscape=true}
local ranges = {luminance=true, color=true, depth=true}
local manual = {brush=true, gradient=true, radialGradient=true}
local automatic = {subject=true, sky=true, background=true}
local function fail(code, message, data)
    error({success=false, code=code, error=message, data=data}, 0)
end
local function requireAPI(name)
    if type(Controller[name]) ~= "function" then
        fail("unsupported_api", "Lightroom does not provide " .. name .. "; mask management requires SDK 11+.")
    end
end
local function id(value, label)
    if type(value) ~= "string" or not value:match("%S") then
        fail("invalid_arguments", label .. " must be a non-empty string")
    end
    return value
end
local function currentPhoto()
    return Application.activeCatalog():getTargetPhoto()
end
local function checkPhoto(photo)
    if currentPhoto() ~= photo then fail("photo_changed", "Selected photo changed during the operation") end
end
local function waitFor(photo, predicate, timeout)
    local deadline = Date.currentTime() + timeout
    repeat
        checkPhoto(photo)
        if predicate() then return true end
        Tasks.sleep(0.05)
    until Date.currentTime() >= deadline
    checkPhoto(photo)
    return predicate()
end
local function prepare(req)
    for _, name in ipairs({"getAllMasks", "getSelectedMask", "getSelectedMaskTool", "goToMasking"}) do requireAPI(name) end
    local photo = currentPhoto()
    if not photo then fail("no_photo", "No photo selected") end
    local photoId
    Application.activeCatalog():withReadAccessDo(function() photoId = photo:getRawMetadata("uuid") end)
    if req.expectedPhotoId ~= nil and id(req.expectedPhotoId, "expectedPhotoId") ~= photoId then
        fail("photo_changed", "Current photo does not match expectedPhotoId")
    end
    checkPhoto(photo)
    local expected = {}
    Application.activeCatalog():withReadAccessDo(function()
        local settings = photo:getDevelopSettings()
        for _, correction in pairs(settings.MaskGroupBasedCorrections or {}) do
            if type(correction.CorrectionID) == "string" then expected[correction.CorrectionID] = true end
        end
    end)
    if View.getCurrentModuleName() ~= "develop" then View.switchToModule("develop") end
    if not waitFor(photo, function() return View.getCurrentModuleName() == "develop" end, 3) then
        fail("context_timeout", "Develop module did not become active")
    end
    local function maskingActive()
        local tool=Controller.getSelectedTool()
        return tool=="masking" or tool=="local_point_color"
    end
    if not maskingActive() then Controller.goToMasking() end
    if not waitFor(photo, maskingActive, 3) then
        fail("context_timeout", "Masking panel did not open")
    end
    -- A newly opened Develop module can report an empty (or previous-photo)
    -- UI summary even after its tool panel is ready. Compare against the catalog
    -- before accepting that summary or selecting an ID copied by a virtual copy.
    if not waitFor(photo, function()
        local raw = Controller.getAllMasks()
        if raw == nil or raw == false then return false end
        if type(raw) ~= "table" then fail("unsupported_mask_data", "Unexpected SDK mask summary") end
        local seen = {}
        for _, mask in pairs(raw) do
            if type(mask) ~= "table" or type(mask.ID) ~= "string" then
                fail("unsupported_mask_data", "Unexpected SDK mask entry")
            end
            if not expected[mask.ID] then return false end
            seen[mask.ID] = true
        end
        for maskId in pairs(expected) do if not seen[maskId] then return false end end
        return true
    end, 5) then fail("context_timeout", "Mask summary has not caught up with the selected photo") end
    return photo, photoId
end
-- SDK summaries use { ID, Name, Hidden, Tools = { { ID, Name, Type, Subtype, ... } } }.
-- Reject unknown layouts rather than inventing IDs or silently omitting entries.
local function masks(allowPending)
    local raw = Controller.getAllMasks()
    -- Lightroom briefly returns nil while AI creation/deletion refreshes its UI.
    -- A pending snapshot is never evidence that a mask was deleted.
    if (raw == nil or raw == false) and allowPending then return nil end
    if type(raw) ~= "table" then fail("unsupported_mask_data", "getAllMasks did not return a table (" .. type(raw) .. ")") end
    local result, seen = {}, {}
    for _, mask in pairs(raw) do
        if type(mask) ~= "table" or type(mask.ID) ~= "string" or mask.ID == "" or type(mask.Tools) ~= "table" or seen[mask.ID] then
            fail("unsupported_mask_data", "Unexpected SDK mask summary; expected unique ID and Tools")
        end
        seen[mask.ID] = true
        local entry = {id=mask.ID, name=mask.Name, hidden=mask.Hidden, tools={}}
        local toolsSeen = {}
        for _, tool in pairs(mask.Tools) do
            if type(tool) ~= "table" or type(tool.ID) ~= "string" or tool.ID == "" or toolsSeen[tool.ID] then
                fail("unsupported_mask_data", "Unexpected SDK tool summary; expected unique ID")
            end
            toolsSeen[tool.ID] = true
            entry.tools[#entry.tools+1] = {id=tool.ID, name=tool.Name, type=tool.Type,
                subtype=tool.Subtype, hidden=tool.Hidden, inverted=tool.Inverted}
        end
        table.sort(entry.tools, function(a,b) return a.id < b.id end)
        result[#result+1] = entry
    end
    table.sort(result, function(a,b) return a.id < b.id end)
    return result
end
local function findMask(list, maskId)
    for _, mask in ipairs(list) do if mask.id == maskId then return mask end end
end
local function findTool(mask, toolId)
    if mask then for _, tool in ipairs(mask.tools) do if tool.id == toolId then return tool end end end
end
local function selection(photoId)
    local maskId, toolId = Controller.getSelectedMask(), Controller.getSelectedMaskTool()
    return {photoId=photoId,
        selectedMaskId=type(maskId) == "string" and maskId ~= "" and maskId or nil,
        selectedToolId=type(toolId) == "string" and toolId ~= "" and toolId or nil}
end
local function selectTarget(photo, maskId, toolId)
    id(maskId, "maskId")
    local mask = findMask(masks(), maskId)
    if not mask then fail("mask_not_found", "Mask not found on current photo: " .. maskId) end
    if toolId ~= nil and not findTool(mask, id(toolId, "toolId")) then
        fail("tool_not_found", "Tool does not belong to mask: " .. toolId)
    end
    requireAPI("selectMask")
    checkPhoto(photo)
    Controller.selectMask(maskId)
    if not waitFor(photo, function() return Controller.getSelectedMask() == maskId end, 3) then
        fail("selection_failed", "Requested mask did not become selected")
    end
    if toolId ~= nil then
        requireAPI("selectMaskTool")
        Controller.selectMaskTool(toolId)
        if not waitFor(photo, function()
            return Controller.getSelectedMask() == maskId and Controller.getSelectedMaskTool() == toolId
        end, 3) then fail("selection_failed", "Requested mask tool did not become selected") end
    end
end
local function checkTarget(photo, maskId)
    checkPhoto(photo)
    if Controller.getSelectedMask() ~= maskId or not findMask(masks(), maskId) then
        fail("selection_changed", "Target mask is no longer selected or no longer exists")
    end
end
local function validateAdjustments(values, required)
    if values == nil and not required then return {} end
    if type(values) ~= "table" or (required and next(values) == nil) then
        fail("invalid_arguments", "No adjustments provided; expected a non-empty object")
    end
    local normalized = {}
    for key, value in pairs(values) do
        local parameter = type(key) == "string" and params[key:lower()]
        if not parameter then fail("invalid_arguments", "Unsupported local parameter: " .. tostring(key)) end
        if type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge then
            fail("invalid_arguments", tostring(key) .. " must be a finite number")
        end
        if normalized[parameter] ~= nil then fail("invalid_arguments", "Duplicate parameter: " .. key) end
        normalized[parameter] = value
    end
    return normalized
end
local function writeAdjustments(photo, maskId, normalized)
    checkTarget(photo, maskId)
    -- Validate every parameter against this photo/process version before any slider write.
    for parameter, value in pairs(normalized) do
        local ok, low, high = Tasks.pcall(function() return Controller.getRange(parameter) end)
        if not ok or type(low) ~= "number" or type(high) ~= "number" then
            fail("unsupported_parameter", "Local slider is unavailable: " .. parameter)
        end
        if value < low or value > high then
            fail("invalid_arguments", parameter .. " must be between " .. low .. " and " .. high)
        end
    end
    local applied, actual = {}, {}
    for parameter, value in pairs(normalized) do
        checkTarget(photo, maskId)
        local ok, err = Tasks.pcall(function() Controller.setValue(parameter, value) end)
        if not ok then fail("adjustment_failed", tostring(err), {maskId=maskId, applied=applied}) end
        applied[#applied+1] = parameter:sub(7)
    end
    local matched = waitFor(photo, function()
        checkTarget(photo, maskId)
        local allMatch = true
        for parameter, requested in pairs(normalized) do
            local value = Controller.getValue(parameter)
            checkTarget(photo, maskId)
            actual[parameter:sub(7)] = value
            if type(value) ~= "number" or math.abs(value - requested) > 0.0001 then allMatch = false end
        end
        return allMatch
    end, 3)
    if not matched then
        fail("readback_failed", "Requested slider values could not be verified; inspect actual values before retrying",
            {maskId=maskId, applied=applied, adjustments=actual})
    end
    return actual
end
local function handle(req)
    local cmd = req.command
    -- Reject malformed mutation arguments before changing the UI or creating a mask.
    local normalized
    if cmd == "add_mask" or cmd == "update_mask" then normalized = validateAdjustments(req.adjustments, cmd == "update_mask") end
    if cmd == "add_mask" then
        if not (ai[req.maskType] or ranges[req.maskType] or manual[req.maskType]) then fail("invalid_arguments", "Unknown maskType") end
        if req.params ~= nil and (type(req.params) ~= "table" or next(req.params)) then
            fail("invalid_arguments", "params must be empty; SDK creation does not accept geometry")
        end
    end
    if cmd == "select_mask" or cmd == "delete_mask" or cmd == "delete_mask_tool" then id(req.maskId, "maskId") end
    if cmd == "delete_mask_tool" then id(req.toolId, "toolId") end
    if cmd=="combine_mask" or cmd=="set_mask_visibility" or cmd=="invert_mask" or cmd=="duplicate_inverted_mask" or cmd=="set_mask_tool_inverted" then
        id(req.maskId,"maskId")
        if req.toolId~=nil then id(req.toolId,"toolId") end
    end
    local photo, photoId = prepare(req)
    local data = selection(photoId)
    if cmd == "list_masks" then data.masks = masks()
    elseif cmd == "get_selected_mask" then
        if data.selectedMaskId then
            checkTarget(photo, data.selectedMaskId)
            data.adjustments = {}
            for _, parameter in pairs(params) do
                local ok, value = Tasks.pcall(function() return Controller.getValue(parameter) end)
                checkTarget(photo, data.selectedMaskId)
                if ok and type(value) == "number" then data.adjustments[parameter:sub(7)] = value end
            end
            if next(data.adjustments) == nil then data.adjustments = nil end
        end
    elseif cmd == "select_mask" then
        selectTarget(photo, req.maskId, req.toolId)
        data = selection(photoId)
    elseif cmd == "update_mask" then
        local maskId = req.maskId
        if maskId ~= nil then selectTarget(photo, maskId) else maskId = data.selectedMaskId end
        if not maskId then fail("no_mask_selected", "No mask selected; provide maskId or select a mask") end
        local actual = writeAdjustments(photo, maskId, normalized)
        data = selection(photoId)
        data.maskId, data.adjustments = maskId, actual
    elseif cmd == "delete_mask" or cmd == "delete_mask_tool" then
        local isTool = cmd == "delete_mask_tool"
        requireAPI(isTool and "deleteMaskTool" or "deleteMask")
        selectTarget(photo, req.maskId, isTool and req.toolId or nil)
        checkTarget(photo, req.maskId)
        if isTool then Controller.deleteMaskTool(req.toolId) else Controller.deleteMask(req.maskId) end
        if not waitFor(photo, function()
            local snapshot = masks(true)
            if not snapshot then return false end
            local mask = findMask(snapshot, req.maskId)
            return (not mask) or (isTool and not findTool(mask, req.toolId))
        end, 3) then fail("deletion_failed", "Deletion could not be verified; refresh masks before retrying") end
        data = selection(photoId)
        data.deletedMaskId = not isTool and req.maskId or nil
        data.deletedToolId = isTool and req.toolId or nil
        data.maskId = req.maskId
        data.masks = masks()
        data.parentMaskDeleted = isTool and not findMask(data.masks, req.maskId) or nil
    elseif cmd == "combine_mask" then
        local functions={add="addToCurrentMask",subtract="subtractFromCurrentMask",intersect="intersectWithCurrentMask"}
        local method=functions[req.operation]
        if not method or not (ai[req.maskType] or ranges[req.maskType] or manual[req.maskType]) then fail("invalid_arguments","Invalid operation or maskType") end
        requireAPI(method)
        selectTarget(photo,req.maskId)
        local before={}
        for _,tool in ipairs(findMask(masks(),req.maskId).tools) do before[tool.id]=true end
        checkTarget(photo,req.maskId)
        if ai[req.maskType] then Controller[method]("aiSelection",req.maskType)
        elseif ranges[req.maskType] then Controller[method]("rangeMask",req.maskType)
        else Controller[method](req.maskType) end
        local added={}
        local ready=waitFor(photo,function()
            local selected=Controller.getSelectedMask()
            if selected and selected~="" and selected~=req.maskId then fail("selection_changed","Target mask selection changed during combination") end
            local snapshot=masks(true)
            if not snapshot then return false end
            local target=findMask(snapshot,req.maskId)
            if not target then return false end
            added={}
            for _,tool in ipairs(target.tools) do if not before[tool.id] then added[#added+1]=tool.id end end
            return #added>0
        end,automatic[req.maskType] and 15 or 0.5)
        data=selection(photoId);data.maskId=req.maskId;data.newToolIds=added;data.operation=req.operation
        data.status=not automatic[req.maskType] and "awaiting_user_input" or (ready and "component_created" or "pending")
        data.note="A component appearing does not verify its pixel coverage; drawing/sampling may require Lightroom interaction."
    elseif cmd == "set_mask_visibility" or cmd == "set_mask_tool_inverted" then
        local invert=cmd=="set_mask_tool_inverted"
        local field=invert and "inverted" or "hidden"
        local wanted=req[field]
        if type(wanted)~="boolean" then fail("invalid_arguments",field .. " must be boolean") end
        if invert then id(req.toolId,"toolId") end
        local method=invert and "toggleInvertMaskTool" or (req.toolId and "toggleHideMaskTool" or "toggleHideMask")
        requireAPI(method)
        selectTarget(photo,req.maskId,req.toolId)
        local function value(allowPending)
            local list=masks(allowPending)
            if not list then return nil end
            local target=findMask(list,req.maskId)
            if req.toolId then target=findTool(target,req.toolId) end
            return target and target[field]
        end
        local previous=value(false)
        if type(previous)~="boolean" then fail("unsupported_mask_state","SDK does not expose the requested state") end
        if previous~=wanted then
            checkTarget(photo,req.maskId)
            Controller[method](req.toolId or req.maskId)
            if not waitFor(photo,function()
                if Controller.getSelectedMask()~=req.maskId then fail("selection_changed","Mask selection changed") end
                return value(true)==wanted
            end,3) then fail("readback_failed","Requested mask state was not retained") end
        end
        data=selection(photoId);data.maskId=req.maskId;data.toolId=req.toolId;data[field]=wanted
        data.changed=previous~=wanted
    elseif cmd == "invert_mask" or cmd == "duplicate_inverted_mask" then
        local duplicate=cmd=="duplicate_inverted_mask"
        local method=duplicate and "duplicateAndInvertMask" or "invertMask"
        requireAPI(method)
        selectTarget(photo,req.maskId)
        local before={}
        for _,mask in ipairs(masks()) do before[mask.id]=true end
        checkTarget(photo,req.maskId)
        local accepted=Controller[method](req.maskId)
        if accepted==false then fail("inversion_failed","Lightroom rejected the inversion") end
        data=selection(photoId);data.sourceMaskId=req.maskId
        if duplicate then
            local newId
            if not waitFor(photo,function()
                local list=masks(true)
                if not list then return false end
                local candidates={}
                for _,mask in ipairs(list) do if not before[mask.id] then candidates[#candidates+1]=mask.id end end
                if #candidates>1 then fail("ambiguous_creation","Multiple new masks appeared; inspect before retrying") end
                newId=candidates[1]
                return newId~=nil
            end,15) then
                data.status="pending"
            else data.maskId=newId;data.status="created" end
        else
            data.maskId=req.maskId;data.status="inverted"
            data.verification="sdk_completed"
            data.note="Whole-mask inversion is a toggle. SDK completion is not independent verification of pixel coverage."
        end
    elseif cmd == "add_mask" then
        requireAPI("createNewMask")
        local before = {}
        for _, mask in ipairs(masks()) do before[mask.id] = true end
        checkPhoto(photo)
        if ai[req.maskType] then Controller.createNewMask("aiSelection", req.maskType)
        elseif ranges[req.maskType] then Controller.createNewMask("rangeMask", req.maskType)
        else Controller.createNewMask(req.maskType) end
        local newId
        local ready = waitFor(photo, function()
            local snapshot = masks(true)
            if not snapshot then return false end
            local selected = Controller.getSelectedMask()
            local mask = findMask(snapshot, selected)
            if mask and not before[selected] then
                newId = selected
                return #mask.tools > 0
            end
            return false
        end, automatic[req.maskType] and 15 or 0.5)
        data = selection(photoId)
        data.maskType, data.maskId = req.maskType, newId
        if not automatic[req.maskType] then
            data.status = "awaiting_user_input"
            data.adjustmentsDeferred = next(normalized) ~= nil
        elseif not ready then
            data.status = "pending"
            data.adjustmentsDeferred = next(normalized) ~= nil
        else
            data.status = "created"
            if next(normalized) then
                local ok, result = Tasks.pcall(function() return writeAdjustments(photo, newId, normalized) end)
                if not ok then
                    if type(result) ~= "table" then result = {success=false, code="sdk_error", error=tostring(result)} end
                    result.data = result.data or {}
                    result.data.maskId, result.data.photoId = newId, photoId
                    result.data.creationStatus = "created"
                    error(result, 0) -- Preserve the new ID even if applying its sliders failed.
                end
                data.adjustments = result
            end
        end
    end
    checkPhoto(photo)
    return {success=true, data=data, message=cmd .. ": " .. (data.status or "verified")}
end
function Masking.handle(req)
    -- LrTasks.pcall permits cooperative SDK yields; plain Lua 5.1 pcall does not.
    local ok, result = Tasks.pcall(function() return handle(req) end)
    if ok then return result end
    if type(result) == "table" and result.success == false then return result end
    return {success=false, code="sdk_error", error=tostring(result)}
end
-- Shared target preparation for fine local controls. No implicit mask fallback.
function Masking.prepareTarget(req)
    id(req.maskId,"maskId")
    local photo,photoId=prepare(req)
    selectTarget(photo,req.maskId)
    return photo,photoId
end
Masking.checkTarget=checkTarget
return Masking
