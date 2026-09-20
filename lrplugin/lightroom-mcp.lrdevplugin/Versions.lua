-- Native snapshots, virtual copies and SDK-visible develop presets.
local Application = import "LrApplication"
local Tasks = import "LrTasks"
local View = import "LrApplicationView"
local Date = import "LrDate"
local Versions = {VERSION="2.7.0"}
Versions.commands = {
    list_snapshots=true, create_snapshot=true, apply_snapshot=true, delete_snapshot=true,
    list_virtual_copies=true, create_virtual_copies=true, select_virtual_copy=true,
    list_presets=true, apply_preset=true,
}
local function fail(code, message, data)
    error({success=false, code=code, error=message, data=data}, 0)
end
local function api(object, name)
    if type(object[name]) ~= "function" then fail("unsupported_api", "Lightroom does not provide " .. name) end
end
local function text(value, label)
    if type(value) ~= "string" or not value:match("%S") or value:find("[%z\1-\31\127]") then fail("invalid_arguments", label .. " must be a non-empty string") end
    return value
end
local function identifier(value)
    if type(value)=="string" and value~="" then return value end
    if type(value)=="number" and value==math.floor(value) and math.abs(value)<math.huge then return tostring(value) end
    fail("unsupported_snapshot_data", "Snapshot ID is missing or has an unknown type")
end
local function uuid(photo) return photo:getRawMetadata("uuid") end
local function catalog() return Application.activeCatalog() end
local function check(photo, expected)
    if catalog():getTargetPhoto() ~= photo or (expected and uuid(photo)~=expected) then
        fail("photo_changed", "The active photo changed; no fallback target was used")
    end
end
local function current(req)
    local photo = catalog():getTargetPhoto()
    if not photo then fail("no_photo", "No photo selected") end
    if req.expectedPhotoId ~= nil then text(req.expectedPhotoId,"expectedPhotoId") end
    check(photo, req.expectedPhotoId)
    return photo
end
local function image(photo)
    if photo:getRawMetadata("isVideo") then fail("unsupported_photo", "This operation supports photos, not video") end
end
local function write(photo, expected, label, fn)
    local entered, result = false, nil
    catalog():withWriteAccessDo(label, function()
        check(photo, expected)
        entered = true
        result = fn()
    end, {timeout=5})
    if not entered then fail("write_timeout", "Could not obtain catalog write access") end
    return result
end
local function wait(photo, predicate)
    local deadline = Date.currentTime()+5
    repeat
        check(photo)
        local value = predicate()
        if value then return value end
        Tasks.sleep(0.05)
    until Date.currentTime()>=deadline
    return nil
end
local function develop(photo)
    if View.getCurrentModuleName()~="develop" then View.switchToModule("develop") end
    if not wait(photo,function() return View.getCurrentModuleName()=="develop" end) then
        fail("context_timeout", "Develop module is not ready")
    end
end
local function raw(photo)
    api(photo,"getDevelopSettings")
    local value=photo:getDevelopSettings()
    if type(value)~="table" then fail("settings_unavailable", "Cannot read develop settings") end
    return value
end
local function equal(a,b)
    if type(a)~=type(b) then return false end
    if type(a)~="table" then return a==b end
    for k,v in pairs(a) do if not equal(v,b[k]) then return false end end
    for k in pairs(b) do if a[k]==nil then return false end end
    return true
end
local function changes(before,after)
    local keys,seen={},{}
    for k,v in pairs(before) do if not equal(v,after[k]) then keys[#keys+1]=k;seen[k]=true end end
    for k,v in pairs(after) do if not seen[k] and not equal(v,before[k]) then keys[#keys+1]=k end end
    table.sort(keys)
    return keys
end
local function snapshots(photo)
    api(photo,"getDevelopSnapshots")
    local source=photo:getDevelopSnapshots()
    if type(source)~="table" then fail("unsupported_snapshot_data", "Snapshot enumeration did not return a table") end
    local items, seen = {}, {}
    for _,entry in pairs(source) do
        if type(entry)~="table" or type(entry.name)~="string" then fail("unsupported_snapshot_data", "Unknown snapshot entry") end
        local id=identifier(entry.snapshotID)
        if seen[id] then fail("unsupported_snapshot_data", "Duplicate snapshot ID") end
        seen[id]=true
        items[#items+1]={snapshotId=id, name=entry.name, globalId=identifier(entry.id_global)}
    end
    table.sort(items,function(a,b) if a.name==b.name then return a.snapshotId<b.snapshotId end; return a.name<b.name end)
    return items
end
local function findSnapshot(photo,id)
    for _,entry in ipairs(snapshots(photo)) do if entry.snapshotId==id then return entry end end
end
local function namedSnapshot(photo,name)
    local match
    for _,entry in ipairs(snapshots(photo)) do
        if entry.name==name then
            if match then fail("ambiguous_snapshot", "Multiple snapshots share this name; use explicit IDs") end
            match=entry
        end
    end
    return match
end
local function snapshotCommand(req,photo)
    local cmd=req.command
    local data={photoId=uuid(photo)}
    if cmd=="list_snapshots" then data.snapshots=snapshots(photo);check(photo);return {success=true,data=data} end
    image(photo)
    if cmd=="create_snapshot" then
        text(req.name,"name")
        if req.updateExisting~=nil and type(req.updateExisting)~="boolean" then fail("invalid_arguments","updateExisting must be boolean") end
        api(photo,"createDevelopSnapshot")
        local prior=namedSnapshot(photo,req.name)
        if prior and not req.updateExisting then fail("snapshot_exists","Snapshot name already exists",{photoId=uuid(photo),snapshotId=prior.snapshotId}) end
        local result=write(photo,req.expectedPhotoId,"MCP Save Snapshot",function()
            if namedSnapshot(photo,req.name) and not req.updateExisting then fail("snapshot_exists","Snapshot name already exists") end
            return photo:createDevelopSnapshot(req.name, req.updateExisting==true)
        end)
        if result==false then fail("snapshot_not_saved","Lightroom did not save the snapshot",data) end
        local saved=wait(photo,function() return namedSnapshot(photo,req.name) end)
        if not saved then fail("snapshot_not_verified","Save returned but snapshot was not enumerated; inspect before retrying",data) end
        data.snapshotId=saved.snapshotId;data.name=saved.name;data.globalId=saved.globalId
        data.status=prior and "updated" or "created"
        data.verification="sdk_completed_and_enumerated"
    else
        text(req.snapshotId,"snapshotId")
        local entry=findSnapshot(photo,req.snapshotId)
        if not entry then fail("snapshot_not_found","Snapshot ID does not belong to the current photo") end
        local method=cmd=="apply_snapshot" and "applyDevelopSnapshot" or "deleteDevelopSnapshot"
        api(photo,method)
        develop(photo)
        entry=findSnapshot(photo,req.snapshotId)
        if not entry then fail("snapshot_not_found","Snapshot disappeared before the operation") end
        data.snapshotId=entry.snapshotId;data.name=entry.name
        local before=cmd=="apply_snapshot" and raw(photo) or nil
        check(photo,req.expectedPhotoId)
        -- These two SDK methods control Develop. Do not surround them with a
        -- catalog write gate. Apply takes snapshotID; delete takes id_global.
        local result=photo[method](photo,cmd=="apply_snapshot" and entry.snapshotId or entry.globalId)
        if result==false then fail("snapshot_operation_failed","Lightroom rejected the snapshot operation",data) end
        if cmd=="delete_snapshot" then
            if not wait(photo,function() return not findSnapshot(photo,req.snapshotId) end) then fail("deletion_failed","Snapshot remains after deletion",data) end
            data.status="deleted";data.verification="enumerated_absent"
        else
            check(photo)
            data.changedKeys=changes(before,raw(photo))
            data.status="applied";data.verification="sdk_completed_and_observed"
            data.note="Snapshot contents are not exposed by the SDK; changedKeys is observation, not full content verification."
        end
    end
    return {success=true,data=data}
end
local function master(photo)
    if photo:getRawMetadata("isVirtualCopy") then
        local parent=photo:getRawMetadata("masterPhoto")
        if not parent then fail("unavailable_master","Cannot resolve the virtual copy's master") end
        return parent
    end
    return photo
end
local function info(photo)
    return {photoId=uuid(photo),filename=photo:getFormattedMetadata("fileName"),
        copyName=photo:getFormattedMetadata("copyName") or "",isVirtualCopy=photo:getRawMetadata("isVirtualCopy")==true,
        masterPhotoId=uuid(master(photo))}
end
local function family(photo)
    local parent=master(photo)
    local copies=parent:getRawMetadata("virtualCopies")
    if type(copies)~="table" then fail("copies_unavailable","Virtual copy enumeration is unavailable") end
    local result={parent}
    for _,copy in ipairs(copies) do result[#result+1]=copy end
    return result
end
local function targets(req,photo)
    if req.scope~=nil and req.scope~="current" and req.scope~="selected" then fail("invalid_arguments","scope must be current or selected") end
    local result=req.scope=="selected" and catalog():getTargetPhotos() or {photo}
    if not result or #result==0 then fail("no_photo","No photos selected") end
    for _,item in ipairs(result) do image(item) end
    return result
end
local function selectedExactly(photos)
    local selection=catalog():getTargetPhotos()
    if not selection or #selection~=#photos then return false end
    local ids={}
    for _,photo in ipairs(photos) do ids[uuid(photo)]=true end
    for _,photo in ipairs(selection) do if not ids[uuid(photo)] then return false end end
    return true
end
local function copyCommand(req,photo)
    local data={photoId=uuid(photo)}
    if req.command=="list_virtual_copies" then
        data.versions={}
        for _,item in ipairs(family(photo)) do data.versions[#data.versions+1]=info(item) end
        check(photo);return {success=true,data=data}
    end
    api(catalog(),"setSelectedPhotos")
    if req.command=="select_virtual_copy" then
        text(req.photoId,"photoId")
        local target
        for _,item in ipairs(family(photo)) do if uuid(item)==req.photoId then target=item end end
        if not target then fail("copy_not_found","Photo is outside the current master/copy family") end
        check(photo,req.expectedPhotoId)
        catalog():setSelectedPhotos(target,{target})
        if not wait(target,function() return selectedExactly({target}) end) then fail("selection_failed","Lightroom did not select this version") end
        return {success=true,data=info(target)}
    end
    api(catalog(),"createVirtualCopies")
    if req.copyName~=nil then text(req.copyName,"copyName") end
    local source=targets(req,photo)
    local before, masters = {}, {}
    data.sources={}
    for _,item in ipairs(source) do
        data.sources[#data.sources+1]=info(item)
        local id=uuid(master(item));masters[id]=(masters[id] or 0)+1
        for _,member in ipairs(family(item)) do before[uuid(member)]=true end
    end
    check(photo,req.expectedPhotoId)
    -- SDK copies the selection, not a supplied photo array. Narrow explicitly
    -- for default current-photo scope, and verify before the creation call.
    if req.scope~="selected" then catalog():setSelectedPhotos(photo,{photo}) end
    if not wait(photo,function() return selectedExactly(source) end) then fail("selection_changed","Selection no longer matches source photos") end
    local created=catalog():createVirtualCopies(req.copyName)
    data.created={}
    if type(created)~="table" then fail("creation_unverified","SDK did not return copies; inspect before retrying",data) end
    local counts, seen = {}, {}
    for _,copy in ipairs(created) do
        local item=info(copy)
        data.created[#data.created+1]=item
        if not item.isVirtualCopy or before[item.photoId] or seen[item.photoId] or not masters[item.masterPhotoId] then
            fail("creation_unverified","Unexpected copy returned; inspect IDs before retrying",data)
        end
        seen[item.photoId]=true;counts[item.masterPhotoId]=(counts[item.masterPhotoId] or 0)+1
    end
    for id,count in pairs(masters) do if counts[id]~=count then fail("partial_creation","Copy count does not match source selection; do not blindly retry",data) end end
    data.count=#data.created;data.status="created"
    local active=catalog():getTargetPhoto()
    data.selectedPhotoId=active and uuid(active) or nil
    data.selectionMatchesCreated=selectedExactly(created)
    return {success=true,data=data}
end
local function presets()
    api(Application,"developPresetFolders")
    local folders=Application.developPresetFolders()
    if type(folders)~="table" then fail("presets_unavailable","SDK did not return preset folders") end
    local list, seen={},{}
    local function add(preset,folder,owned)
        local id=text(preset:getUuid(),"preset UUID")
        if seen[id] then return end
        seen[id]=true
        list[#list+1]={presetId=id,name=preset:getName(),folder=folder,pluginOwned=owned,object=preset}
    end
    for _,folder in ipairs(folders) do
        local children=folder:getDevelopPresets()
        if type(children)~="table" then fail("presets_unavailable","Cannot enumerate preset folder") end
        for _,preset in ipairs(children) do add(preset,folder:getName(),false) end
    end
    if type(Application.getDevelopPresetsForPlugin)=="function" then
        for _,preset in ipairs(Application.getDevelopPresetsForPlugin(_PLUGIN) or {}) do add(preset,"Lightroom MCP",true) end
    end
    table.sort(list,function(a,b)
        if a.folder~=b.folder then return a.folder<b.folder end
        if a.name~=b.name then return a.name<b.name end
        return a.presetId<b.presetId
    end)
    return list
end
local function listPresets(req)
    local offset,limit=req.offset or 0,req.limit or 50
    if type(offset)~="number" or offset~=math.floor(offset) or offset<0 or offset==math.huge or
        type(limit)~="number" or limit~=math.floor(limit) or limit<1 or limit>200 or
        (req.query~=nil and type(req.query)~="string") then fail("invalid_arguments","Invalid query or pagination") end
    local found={}
    local query=(req.query or ""):lower()
    for _,entry in ipairs(presets()) do
        if (entry.name .. " " .. entry.folder):lower():find(query,1,true) then found[#found+1]=entry end
    end
    local page={}
    for i=offset+1,math.min(offset+limit,#found) do
        local e=found[i];page[#page+1]={presetId=e.presetId,name=e.name,folder=e.folder,pluginOwned=e.pluginOwned}
    end
    return {success=true,data={presets=page,total=#found,offset=offset,hasMore=offset+#page<#found}}
end
local function applyPreset(req,photo)
    text(req.presetId,"presetId")
    if req.amount~=nil and (type(req.amount)~="number" or req.amount~=math.floor(req.amount) or req.amount<0 or req.amount>200) then fail("invalid_arguments","amount must be an integer from 0 to 200") end
    if req.updateAISettings~=nil and type(req.updateAISettings)~="boolean" then fail("invalid_arguments","updateAISettings must be boolean") end
    local preset
    for _,entry in ipairs(presets()) do if entry.presetId==req.presetId then preset=entry end end
    if not preset then fail("preset_not_found","Preset UUID was not found; list presets again") end
    local photos=targets(req,photo)
    for _,item in ipairs(photos) do
        api(item,"applyDevelopPreset");api(item,"getDevelopSettings")
        if req.updateAISettings then api(item,"updateAISettings") end
    end
    check(photo,req.expectedPhotoId)
    local results,applied={},0
    for _,item in ipairs(photos) do
        local result={photoId=uuid(item),success=false}
        results[#results+1]=result
        local ok,err=Tasks.pcall(function()
            check(photo,req.expectedPhotoId)
            local before=raw(item)
            local status=write(photo,req.expectedPhotoId,"MCP Apply Preset",function()
                if req.amount==nil then
                    return item:applyDevelopPreset(preset.object,preset.pluginOwned and _PLUGIN or nil)
                end
                return item:applyDevelopPreset(preset.object,preset.pluginOwned and _PLUGIN or nil,req.amount)
            end)
            if status==false then fail("preset_rejected","Lightroom rejected the preset") end
            if req.updateAISettings then
                check(photo,req.expectedPhotoId)
                local updated=write(photo,req.expectedPhotoId,"MCP Update AI Settings",function() return item:updateAISettings() end)
                if updated==false then fail("ai_update_failed","Lightroom rejected the AI update") end
            end
            result.changedKeys=changes(before,raw(item))
            result.success=true;result.status="applied";result.verification="sdk_completed_and_observed"
        end)
        if not ok then
            result.code=type(err)=="table" and err.code or "sdk_error"
            result.error=type(err)=="table" and err.error or tostring(err)
            result.outcomeUnknown=true
            break
        end
        applied=applied+1
    end
    return {success=applied==#photos,code=applied~=#photos and "partial_failure" or nil,
        error=applied~=#photos and "Stopped on a failed photo; prior edits are not rolled back" or nil,
        applied=applied,failed=applied==#photos and 0 or 1,notAttempted=#photos-#results,
        data={presetId=preset.presetId,presetName=preset.name,results=results,
            aiUpdateRequested=req.updateAISettings==true,
            note="SDK call completion and observed changes do not verify every preset value or AI rendering completion."}}
end
local historyCommands={copy_settings=true,paste_settings=true,get_history_state=true,undo=true,redo=true}
for name in pairs(historyCommands)do Versions.commands[name]=true end
local copies,copyOrder={},{}
local historyObservation=nil
local function cloneHistory(v)
    if type(v)~='table'then return v end
    local out={};for k,x in pairs(v)do out[k]=cloneHistory(x)end;return out
end
local function token(value)
    if type(value)~='string' or #value~=32 or not value:match('^[a-f0-9]+$')then fail('invalid_arguments','Invalid session token')end
    return value
end
-- Read-only bridge commands do not consume history. Other MCP operations do,
-- even if they eventually fail: conservative invalidation is preferable to reuse.
function Versions.beforeCommand(cmd)
    if cmd=='get_history_state' or cmd=='undo' or cmd=='redo' or cmd=='ping' or cmd=='export_preview' or cmd:match('^get_') or cmd:match('^list_') or cmd:match('^search_')then return end
    historyObservation=nil
end
local function historyHandle(req)
    local c=catalog();local path=c:getPath();local photo=c:getTargetPhoto()
    local function guard(selectionMayChange)
        if catalog()~=c or c:getPath()~=path or (req.expectedCatalogPath and req.expectedCatalogPath~=path)then fail('catalog_changed','Catalog changed')end
        if not selectionMayChange and (c:getTargetPhoto()~=photo or (req.expectedPhotoId and (not photo or uuid(photo)~=req.expectedPhotoId)))then fail('photo_changed','Active photo changed')end
    end
    guard()
    local function capture()
        local active=c:getTargetPhoto();local state={catalogPath=path,selection={}}
        if active then
            state.photoId=uuid(active);state.settings=cloneHistory(raw(active));state.orientation=active:getRawMetadata('orientation')
            state.rating=active:getRawMetadata('rating');state.pickStatus=active:getRawMetadata('pickStatus')
            for _,p in ipairs(c:getTargetPhotos())do state.selection[#state.selection+1]=uuid(p)end
            table.sort(state.selection)
        end
        return state
    end
    local function observed(before)
        guard(true);local after=capture()
        local data={catalogPath=path,photoId=after.photoId,previousPhotoId=before.photoId,
            activePhotoChanged=after.photoId~=before.photoId,verification='current_photo_observation',changedKeys={}}
        if before.photoId and before.photoId==after.photoId then data.changedKeys=changes(before.settings,after.settings)end
        data.currentPhotoStateChanged=not equal(before,after)
        return data
    end
    local cmd=req.command
    if cmd=='copy_settings' then
        if not photo then fail('no_photo','Select a source photo')end;image(photo)
        token(req.copyId);if copies[req.copyId]then fail('duplicate_copy','Copy ID already exists')end;local mode=req.mode or 'native_ui'
        if mode~='native_ui' and mode~='explicit'then fail('invalid_arguments','Invalid copy mode')end
        if mode=='native_ui' and req.parameters~=nil then fail('invalid_arguments','Native copy uses UI categories; use explicit mode for named parameters')end
        local saved={copyId=req.copyId,mode=mode,sourcePhotoId=uuid(photo),catalogPath=path,createdAt=Date.currentTime()}
        if mode=='explicit'then
            if type(req.parameters)~='table' or #req.parameters<1 or #req.parameters>150 then fail('invalid_arguments','Explicit mode needs 1-150 parameters')end
            local result=require('Develop').handle({command='get_settings',expectedPhotoId=uuid(photo)})
            if not result.success then return result end
            local index={};for name in pairs(result.data.settings)do index[name:lower()]=name end
            saved.settings={};local seen={}
            for _,requested in ipairs(req.parameters)do
                text(requested,'parameter');local canonical=index[requested:lower()]
                if not canonical then fail('unsupported_parameter','Numeric parameter not available: '..requested)end
                if seen[canonical]then fail('invalid_arguments','Duplicate parameter alias')end;seen[canonical]=true
                saved.settings[canonical]=result.data.settings[canonical]
            end
            guard()
        else
            api(photo,'copySettings');local before=cloneHistory(raw(photo));guard()
            local accepted=photo:copySettings()
            if accepted~=true then fail('copy_failed','Native copy did not report success')end
            guard();if not equal(before,raw(photo))then fail('source_changed','Source changed while copying')end
            saved.sourceSettings=before
        end
        copies[req.copyId]=saved;copyOrder[#copyOrder+1]=req.copyId
        if #copyOrder>20 then copies[table.remove(copyOrder,1)]=nil end
        return {success=true,data={copyId=saved.copyId,mode=mode,sourcePhotoId=saved.sourcePhotoId,catalogPath=path,
            settings=cloneHistory(saved.settings),scope=mode=='explicit' and 'named_numeric_parameters' or 'ui_categories_unenumerated',
            nativeClipboardChanged=mode=='native_ui',survivesPluginReload=false}}
    elseif cmd=='paste_settings'then
        if not photo then fail('no_photo','Select a destination photo')end;image(photo);text(req.expectedPhotoId,'expectedPhotoId')
        local saved=copies[token(req.copyId)]
        if not saved then fail('copy_not_found','Copy expired/evicted or plugin reloaded; copy again')end
        if saved.catalogPath~=path then fail('catalog_changed','Copy belongs to another catalog')end
        local before=capture();local result
        if saved.mode=='explicit'then
            guard();result=require('Develop').handle({command='apply_settings',settings=cloneHistory(saved.settings),expectedPhotoId=uuid(photo)})
            if not result.success then result.copyId=req.copyId;return result end
            guard()
        else
            api(c,'findPhotoByUuid');local source=c:findPhotoByUuid(saved.sourcePhotoId)
            if not source then fail('photo_not_found','Copied source is no longer in this catalog')end
            if not equal(saved.sourceSettings,raw(source))then fail('source_changed','Native copied source changed; copy again')end
            api(source,'copySettings');api(photo,'pasteSettings');guard()
            -- Re-copy immediately so unrelated clipboard changes between requests
            -- do not intentionally become the paste source. UI categories remain
            -- controlled by Lightroom and cannot be enumerated by this API.
            if source:copySettings()~=true then fail('copy_failed','Native source refresh failed; paste not attempted')end
            guard()
            if not equal(saved.sourceSettings,raw(source))then fail('source_changed','Source changed before paste')end
            local accepted=photo:pasteSettings(false)
            if accepted~=true then fail('paste_failed','Native paste did not report success; inspect destination before retrying')end
            Tasks.sleep(.1);guard()
        end
        local d=observed(before);d.copyId=req.copyId;d.mode=saved.mode;d.sourcePhotoId=saved.sourcePhotoId
        d.verification=saved.mode=='explicit' and 'numeric_readback' or 'native_call_and_observation'
        d.clipboardScopeVerified=saved.mode=='explicit';d.aiUpdateRequested=false
        if saved.mode=='explicit'then d.settings=cloneHistory(saved.settings)
        else d.note='UI copy categories and native clipboard payload are not independently enumerable; changedKeys is not full-paste verification.'end
        return {success=true,data=d}
    end
    local Undo=import 'LrUndo';api(Undo,'canUndo');api(Undo,'canRedo')
    if cmd=='get_history_state'then
        token(req.historyToken)
        local state=capture();local canUndo,canRedo=Undo.canUndo(),Undo.canRedo();guard()
        historyObservation={token=req.historyToken,state=state,createdAt=Date.currentTime(),canUndo=canUndo,canRedo=canRedo}
        return {success=true,data={historyToken=req.historyToken,canUndo=canUndo,canRedo=canRedo,photoId=state.photoId,catalogPath=path,
            scope='application_global',expiresInSeconds=60,historyEntryIdentityAvailable=false,
            note='Context guard cannot detect every manual edit to other photos or identify the actual history entry. Not an MCP-operation rollback.'}}
    end
    if cmd~='undo' and cmd~='redo'then fail('unknown_command','Unknown history command')end
    local observation=historyObservation
    if not observation or observation.token~=req.historyToken then fail('history_token_invalid','Read history state again before every undo/redo')end
    historyObservation=nil -- One attempt only, including uncertain SDK outcomes.
    if Date.currentTime()-observation.createdAt>60 then fail('history_token_expired','Read fresh history state')end
    if not equal(observation.state,capture()) or Undo.canUndo()~=observation.canUndo or Undo.canRedo()~=observation.canRedo then fail('history_state_changed','Observed context changed; read fresh history state')end
    local available=cmd=='undo' and observation.canUndo or cmd=='redo' and observation.canRedo
    if not available then fail('history_unavailable','Native '..cmd..' is disabled')end
    api(Undo,cmd);guard();Undo[cmd]();Tasks.sleep(.1)
    local d=observed(observation.state);d.action=cmd;d.scope='application_global';d.canUndo=Undo.canUndo();d.canRedo=Undo.canRedo()
    d.historyEntryIdentityAvailable=false;d.status='native_call_completed'
    d.note='Only current-photo context was observed. Unchanged current-photo settings do not prove global history had no effect.'
    return {success=true,data=d}
end

function Versions.capabilities()
    local result={catalog={},application={},photo={}}
    for _,name in ipairs({"createVirtualCopies","setSelectedPhotos"}) do result.catalog[name]=type(catalog()[name])=="function" end
    for _,name in ipairs({"developPresetFolders","getDevelopPresetsForPlugin"}) do result.application[name]=type(Application[name])=="function" end
    local photo=catalog():getTargetPhoto()
    if photo then
        for _,name in ipairs({"getDevelopSnapshots","createDevelopSnapshot","applyDevelopSnapshot","deleteDevelopSnapshot","applyDevelopPreset","updateAISettings","copySettings","pasteSettings"}) do result.photo[name]=type(photo[name])=="function" end
    end
    result.photoSelected=photo~=nil
    return result
end
function Versions.handle(req)
    local ok,result=Tasks.pcall(function()
        if historyCommands[req.command] then return historyHandle(req) end
        if req.command=="list_presets" then return listPresets(req) end
        local photo=current(req)
        if req.command:find("snapshot",1,true) then return snapshotCommand(req,photo) end
        if req.command=="apply_preset" then return applyPreset(req,photo) end
        return copyCommand(req,photo)
    end)
    if ok then return result end
    return type(result)=="table" and result or {success=false,code="sdk_error",error=tostring(result)}
end
return Versions
