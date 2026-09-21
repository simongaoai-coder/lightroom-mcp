-- Explicit targets; Quick Develop is UI-bound and requires temporary single selection.
local App=import 'LrApplication'
local Tasks=import 'LrTasks'
local Date=import 'LrDate'
local Library=require 'Library'
local Styles=require 'Styles'
local Batch={VERSION='2.12.2'}
local fail=Library.fail
local function api(object,name)
    if type(object[name])~='function' then fail('unsupported_api',name..' unavailable') end
end
local function presets()
    local list={}
    api(App,'developPresetFolders')
    for _,folder in ipairs(App.developPresetFolders()) do
        for _,p in ipairs(folder:getDevelopPresets()) do list[#list+1]={preset=p,owned=false} end
    end
    if type(App.getDevelopPresetsForPlugin)=='function' then
        for _,p in ipairs(App.getDevelopPresetsForPlugin(_PLUGIN) or {}) do list[#list+1]={preset=p,owned=true} end
    end
    return list
end
local function handle(req)
    if req.command=='save_style' then return Styles.save(req) end
    local c=Library.context(req);local photos=Library.targets(c,req);local plans={}
    local usesQuick=req.command=='set_treatment' or (req.command=='set_white_balance' and req.mode~='As Shot')
    local originalSelection,expectedSelection
    local function selection(active,items)
        local copy={};for i,p in ipairs(items or {}) do copy[i]=p end
        return {active=active,photos=copy}
    end
    local function matchesSelection(expected)
        if c.catalog:getTargetPhoto()~=expected.active then return false end
        local current=c.catalog:getTargetPhotos() or {}
        if #current~=#expected.photos then return false end
        local wanted={};for _,p in ipairs(expected.photos) do wanted[p]=true end
        for _,p in ipairs(current) do if not wanted[p] then return false end end
        return true
    end
    if usesQuick then
        api(c.catalog,'setSelectedPhotos');api(c.catalog,'getTargetPhotos')
        originalSelection=selection(c.target,c.catalog:getTargetPhotos());expectedSelection=originalSelection
        if not c.target then api(import 'LrSelection','selectNone') end
    end
    local function guard(p)
        Library.check(c,usesQuick)
        if usesQuick and not matchesSelection(expectedSelection) then fail('selection_changed','Selection changed during the batch; no further native operation attempted') end
        if p and c.catalog:findPhotoByUuid(p:getRawMetadata('uuid'))~=p then fail('photo_not_found','Target disappeared') end
    end
    local function waitSelection(expected)
        local deadline=Date.currentTime()+3
        repeat
            Library.check(c,true)
            if matchesSelection(expected) then return true end
            Tasks.sleep(.05)
        until Date.currentTime()>=deadline
        return false
    end
    local function selectNativeTarget(p)
        guard(p)
        local expected=selection(p,{p})
        if not matchesSelection(expected) then
            -- Do not change sources/filters to force hidden photos into view.
            -- If selection cannot be verified, never invoke Quick Develop.
            expectedSelection=expected
            c.catalog:setSelectedPhotos(p,{p})
            if not waitSelection(expected) then fail('selection_failed','Could not select exactly the target photo') end
        else expectedSelection=expected end
        guard(p)
    end
    local function write(p,fn)
        local entered,result=false,nil
        c.catalog:withWriteAccessDo('MCP Batch '..req.command,function() guard(p);entered=true;result=fn() end,{timeout=5})
        if not entered then fail('write_timeout','Catalog write access was not acquired') end
        return result
    end
    local preset,owned,manifest
    if req.command=='apply_preset' then
        if type(req.presetId)~='string' then fail('invalid_arguments','presetId required') end
        if req.amount~=nil and (type(req.amount)~='number' or req.amount%1~=0 or req.amount<0 or req.amount>200) then fail('invalid_arguments','Invalid amount') end
        if req.updateAISettings~=nil and type(req.updateAISettings)~='boolean' then fail('invalid_arguments','Invalid AI flag') end
        for _,entry in ipairs(presets()) do if entry.preset:getUuid()==req.presetId then preset=entry.preset;owned=entry.owned end end
        if not preset then fail('preset_not_found','Preset not enumerated') end
        if owned then manifest=Styles.check(preset,photos) end
        if manifest and req.amount~=nil and req.amount~=100 then fail('unsupported_amount','Saved selective styles require amount=100 or omitted') end
    elseif req.command=='set_treatment' then
        if req.treatment~='color' and req.treatment~='grayscale' then fail('invalid_arguments','Invalid treatment') end
    elseif req.command=='set_white_balance' then
        if not ({['As Shot']=true,Auto=true,Daylight=true,Cloudy=true,Shade=true,Tungsten=true,Fluorescent=true,Flash=true})[req.mode] then fail('invalid_arguments','Invalid WB mode') end
    elseif req.command=='rotate_photo' then
        if req.direction~='left' and req.direction~='right' then fail('invalid_arguments','Invalid direction') end
    else fail('unknown_command','Unsupported batch operation') end
    for _,p in ipairs(photos) do
        guard(p)
        if p:getRawMetadata('isVideo') then fail('unsupported_photo','Batch requires photos') end
        local plan={photo=p,photoId=p:getRawMetadata('uuid')}
        if req.command=='rotate_photo' then
            local o=p:getRawMetadata('orientation')
            if not ({AB=true,BC=true,CD=true,DA=true,BA=true,AD=true,DC=true,CB=true})[o] then fail('unsupported_orientation','Unknown orientation') end
            local map=req.direction=='right' and {A='B',B='C',C='D',D='A'} or {A='D',B='A',C='B',D='C'}
            plan.before=o;plan.wanted=map[o:sub(1,1)]..map[o:sub(2,2)]
            plan.method=req.direction=='right' and 'rotateRight' or 'rotateLeft';api(p,plan.method)
        else
            api(p,'getDevelopSettings')
            if req.command=='apply_preset' then
                api(p,manifest and 'applyDevelopSettings' or 'applyDevelopPreset');if req.updateAISettings then api(p,'updateAISettings') end
            elseif req.command=='set_treatment' then api(p,'quickDevelopSetTreatment')
            else
                local format=p:getRawMetadata('fileFormat')
                if req.mode~='As Shot' and req.mode~='Auto' and format~='RAW' and format~='DNG' then fail('unsupported_mode','Lighting WB modes require RAW/DNG for all targets') end
                api(p,req.mode=='As Shot' and 'applyDevelopSettings' or 'quickDevelopSetWhiteBalance')
            end
        end
        plans[#plans+1]=plan
    end
    local results,applied={},0
    for _,plan in ipairs(plans) do
        local p=plan.photo;local row={photoId=plan.photoId,success=false};results[#results+1]=row
        local ok,err=Tasks.pcall(function()
            guard(p)
            local before=req.command=='rotate_photo' and p:getRawMetadata('orientation') or p:getDevelopSettings()
            if req.command=='rotate_photo' and before~=plan.before then fail('settings_changed','Orientation changed after preflight') end
            row.before=Library.clone(before)
            if req.command=='apply_preset' then
                if owned then Styles.check(preset,{p}) end
                local accepted=write(p,function()
                    if owned then Styles.check(preset,{p}) end
                    row.writeAttempted=true
                    if manifest then
                        row.backend='selected_catalog_settings'
                        return p:applyDevelopSettings(Library.clone(manifest.settings),'MCP Saved Style')
                    end
                    row.backend='native_preset'
                    return p:applyDevelopPreset(preset,nil,req.amount)
                end)
                if accepted==false then fail('preset_rejected','Preset application rejected') end
                if req.updateAISettings then
                    if write(p,function() return p:updateAISettings() end)==false then fail('ai_update_failed','AI update rejected') end
                end
            elseif req.command=='set_treatment' then
                selectNativeTarget(p);row.writeAttempted=true
                p:quickDevelopSetTreatment(req.treatment)
            elseif req.command=='rotate_photo' then row.writeAttempted=true;p[plan.method](p)
            elseif req.mode=='As Shot' then
                write(p,function() row.writeAttempted=true;p:applyDevelopSettings({WhiteBalance=req.mode},'MCP White Balance') end)
            else
                selectNativeTarget(p);row.writeAttempted=true
                p:quickDevelopSetWhiteBalance(req.mode)
            end
            local deadline=Date.currentTime()+3
            repeat
                guard(p)
                local after=req.command=='rotate_photo' and p:getRawMetadata('orientation') or p:getDevelopSettings()
                row.after=Library.clone(after)
                local matches=req.command=='rotate_photo' and after==plan.wanted or
                    req.command=='set_treatment' and after.ConvertToGrayscale==(req.treatment=='grayscale') or
                    req.command=='set_white_balance' and after.WhiteBalance==req.mode or
                    req.command=='apply_preset' and (not manifest or Styles.matches(manifest,after))
                if matches then
                    if manifest then
                        row.unselectedFieldChanges=Styles.protectedChanges(manifest,before,after)
                        if #row.unselectedFieldChanges>0 then fail('unselected_settings_changed','An unselected protected field changed; inspect per-photo values before retrying') end
                        row.protectedFieldsVerified=true
                    end
                    row.success=true;row.status='applied'
                    row.verification=req.command=='apply_preset' and (manifest and 'saved_fields_readback' or 'sdk_completed_and_observed') or 'catalog_readback'
                    -- Keep responses bounded: return selected observations, not full mask tables.
                    if req.command~='rotate_photo' then
                        row.before=setmetatable({}, {__jsontype="object"});row.after=setmetatable({}, {__jsontype="object"});row.changedKeys={}
                        for k,v in pairs(after) do
                            if not Styles.equal(before[k],v) then row.changedKeys[#row.changedKeys+1]=k end
                        end
                        for k in pairs(before) do if after[k]==nil then row.changedKeys[#row.changedKeys+1]=k end end
                        table.sort(row.changedKeys)
                        local keys=manifest and manifest.settings or req.command=='set_treatment' and {ConvertToGrayscale=true} or
                            req.command=='set_white_balance' and {WhiteBalance=true,Temperature=true,Tint=true,IncrementalTemperature=true,IncrementalTint=true} or {}
                        for k in pairs(keys) do row.before[k]=before[k];row.after[k]=after[k] end
                    end
                    return
                end
                Tasks.sleep(.05)
            until Date.currentTime()>=deadline
            fail('readback_failed','Requested state was not observed; inspect before retrying')
        end)
        if not ok then
            row.code=type(err)=='table' and err.code or 'sdk_error';row.error=type(err)=='table' and err.error or tostring(err)
            row.outcomeUnknown=row.writeAttempted==true;break
        end
        applied=applied+1
    end
    local restored,restoreError=true,nil
    if usesQuick then
        local ok,result=Tasks.pcall(function()
            Library.check(c,true)
            if matchesSelection(originalSelection) then return true end
            if not matchesSelection(expectedSelection) then fail('selection_changed','Manual selection change detected; original selection was not forced back') end
            if originalSelection.active then
                for _,p in ipairs(originalSelection.photos) do
                    if c.catalog:findPhotoByUuid(p:getRawMetadata('uuid'))~=p then fail('photo_not_found','Original selection no longer exists') end
                end
                c.catalog:setSelectedPhotos(originalSelection.active,originalSelection.photos)
            else (import 'LrSelection').selectNone() end
            if not waitSelection(originalSelection) then fail('selection_restore_failed','Original selection could not be restored') end
            return true
        end)
        restored=ok and result==true
        if not restored then restoreError=type(result)=='table' and result.error or tostring(result) end
    end
    local success=applied==#plans and restored
    return {success=success,code=not success and (applied==#plans and 'selection_restore_failed' or 'partial_failure') or nil,
        error=not success and (restoreError or 'Stopped at first failure; prior writes remain') or nil,
        applied=applied,failed=applied==#plans and 0 or 1,notAttempted=#plans-#results,
        data={catalogPath=c.path,presetId=req.presetId,presetName=preset and preset:getName() or nil,
            results=results,aiUpdateRequested=req.updateAISettings==true,
            selectionTemporarilyChanged=usesQuick or false,selectionRestored=restored,selectionRestoreError=restoreError,
            note='Readback verifies stored values, not rendered pixels or AI completion.'}}
end
function Batch.handle(req)
    local ok,result=Tasks.pcall(function()return handle(req)end)
    if ok then return result end
    return type(result)=='table' and result or {success=false,code='sdk_error',error=tostring(result)}
end
return Batch
