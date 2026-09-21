-- Photo-object operations: explicit batches never change Lightroom selection.
local App=import 'LrApplication'
local Tasks=import 'LrTasks'
local Date=import 'LrDate'
local Library=require 'Library'
local Styles=require 'Styles'
local Batch={VERSION='2.12.0'}
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
    local function guard(p)
        Library.check(c)
        if p and c.catalog:findPhotoByUuid(p:getRawMetadata('uuid'))~=p then fail('photo_not_found','Target disappeared') end
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
                api(p,'applyDevelopPreset');if req.updateAISettings then api(p,'updateAISettings') end
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
                    return p:applyDevelopPreset(preset,owned and _PLUGIN or nil,req.amount)
                end)
                if accepted==false then fail('preset_rejected','Preset application rejected') end
                if req.updateAISettings then
                    if write(p,function() return p:updateAISettings() end)==false then fail('ai_update_failed','AI update rejected') end
                end
            elseif req.command=='set_treatment' then row.writeAttempted=true;p:quickDevelopSetTreatment(req.treatment)
            elseif req.command=='rotate_photo' then row.writeAttempted=true;p[plan.method](p)
            elseif req.mode=='As Shot' then write(p,function()row.writeAttempted=true;p:applyDevelopSettings({WhiteBalance='As Shot'})end)
            else row.writeAttempted=true;p:quickDevelopSetWhiteBalance(req.mode) end
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
    local success=applied==#plans
    return {success=success,code=not success and 'partial_failure' or nil,
        error=not success and 'Stopped at first failure; prior writes remain' or nil,
        applied=applied,failed=success and 0 or 1,notAttempted=#plans-#results,
        data={catalogPath=c.path,presetId=req.presetId,presetName=preset and preset:getName() or nil,
            results=results,aiUpdateRequested=req.updateAISettings==true,
            note='Readback verifies stored values, not rendered pixels or AI completion.'}}
end
function Batch.handle(req)
    local ok,result=Tasks.pcall(function()return handle(req)end)
    if ok then return result end
    return type(result)=='table' and result or {success=false,code='sdk_error',error=tostring(result)}
end
return Batch
