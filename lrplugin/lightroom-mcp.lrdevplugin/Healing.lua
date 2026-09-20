-- Existing-spot management; no undocumented from-scratch stroke creation.
local Controller=import "LrDevelopController"
local View=import "LrApplicationView"
local Tasks=import "LrTasks"
local Date=import "LrDate"
local MD5=import "LrMD5"
local Library=require "Library"
local Healing={VERSION="2.4.2",commands={open_remove=true,list_spots=true,get_selected_spot=true,
    select_spot=true,update_spot=true,set_spot_type=true,move_spot=true,refresh_spot=true,delete_spot=true,
    cycle_spot_variation=true,get_remove_preferences=true,set_remove_preferences=true,reset_healing=true,
    update_ai_settings=true,get_ai_update_status=true,cancel_ai_update=true,cleanup_empty_masks=true}}
local fail=Library.fail
local kinds={heal_patchmatch=true,heal=true,clone=true}
local function api(name) if type(Controller[name])~="function" then fail("unsupported_api","Lightroom does not provide "..name.." (Remove APIs require SDK 14.1+)") end end
local function finite(v) return type(v)=="number" and v==v and math.abs(v)<math.huge end
local function copy(v,seen)
    if type(v)~="table" then
        if type(v)=="function" or type(v)=="userdata" or type(v)=="thread" or (type(v)=="number" and not finite(v)) then fail("unsupported_spot_data","SDK returned non-serializable spot data") end
        return v
    end
    seen=seen or {};if seen[v] then fail("unsupported_spot_data","Cyclic spot data") end;seen[v]=true
    local out={};for k,x in pairs(v) do
        if type(k)~="string" and type(k)~="number" then fail("unsupported_spot_data","Invalid SDK table key") end
        out[k]=copy(x,seen)
    end
    seen[v]=nil;return out
end
local function equal(a,b)
    if type(a)~=type(b) then return false end
    if type(a)=="number" then return finite(a) and finite(b) and math.abs(a-b)<0.00001 end
    if type(a)~="table" then return a==b end
    for k,v in pairs(a) do if not equal(v,b[k]) then return false end end
    for k in pairs(b) do if a[k]==nil then return false end end
    return true
end
local function stable(v)
    local t=type(v)
    if t=="string" then return "s"..#v..":"..v end
    if t=="number" then return "n"..string.format("%.17g",v)..";" end
    if t=="boolean" then return v and "true" or "false" end
    if t=="nil" then return "null" end
    local parts={}
    for k,x in pairs(v) do parts[#parts+1]={key=stable(k),value=stable(x)} end
    table.sort(parts,function(a,b)return a.key<b.key end)
    local out={};for _,p in ipairs(parts) do out[#out+1]=p.key..p.value end
    return "{"..table.concat(out).."}"
end
local function current(c) Library.check(c);if c.catalog:getTargetPhoto()~=c.target then fail("photo_changed","Active photo changed") end end
local function wait(c,fn,seconds)
    local deadline=Date.currentTime()+(seconds or 3)
    repeat current(c);local result=fn();if result then return result end;Tasks.sleep(.05) until Date.currentTime()>=deadline
    current(c);return fn()
end
local function prepare(req)
    local c=Library.context(req)
    if not c.target then fail("no_photo","No photo selected") end
    if c.target:getRawMetadata("isVideo") then fail("unsupported_photo","Remove controls require a photo") end
    c.guardTarget=true
    api("goToRemove");api("getSelectedTool")
    if View.getCurrentModuleName()~="develop" then View.switchToModule("develop") end
    if not wait(c,function()return View.getCurrentModuleName()=="develop"end,5) then fail("context_timeout","Develop did not become ready") end
    if req.command=="open_remove" and req.spotType~=nil then
        if not kinds[req.spotType] then fail("invalid_arguments","Invalid spotType") end
        Controller.goToRemove(req.spotType)
    elseif Controller.getSelectedTool()~="dust" then Controller.goToRemove() end
    if not wait(c,function()return Controller.getSelectedTool()=="dust"end,5) then fail("context_timeout","Remove tool did not open") end
    return c
end
local function readOnce(c)
    api("countAllSpots");api("getAllSpots")
    current(c)
    local count=Controller.countAllSpots()
    if not finite(count) or count<0 or count~=math.floor(count) then return nil end
    local raw=Controller.getAllSpots()
    if count==0 and (raw==nil or raw==false) then return {} end
    if raw==nil or raw==false then return nil end
    if type(raw)~="table" then fail("unsupported_spot_data","Spot list is not a table") end
    local rows={}
    for index,spot in pairs(raw) do
        if not finite(index) or index<0 or index~=math.floor(index) or (type(spot)~="table" and type(spot)~="string") then fail("unsupported_spot_data","Unknown spot list layout") end
        rows[#rows+1]={spotIndex=index,spot=copy(spot)}
    end
    if #rows~=count then return nil end
    table.sort(rows,function(a,b)return a.spotIndex<b.spotIndex end)
    if #rows>0 then
        local base=rows[1].spotIndex
        if base~=0 and base~=1 then fail("unsupported_spot_data","Unknown native index base") end
        for i,row in ipairs(rows) do if row.spotIndex~=base+i-1 then fail("unsupported_spot_data","Sparse spot list") end end
    end
    current(c)
    return rows
end
local function spots(c)
    local rows=wait(c,function()return readOnce(c)end,5)
    if not rows then fail("spots_unavailable","SDK spot list/count did not become consistent; not treated as empty") end
    return rows
end
local function find(rows,index) for _,row in ipairs(rows) do if row.spotIndex==index then return row end end end
local function revision(c,rows) return MD5.digest(c.target:getRawMetadata("uuid")..":"..stable(rows)) end
local function selectedIndex() api("getSelectedSpotIndex");return Controller.getSelectedSpotIndex() end
local function selection(c,rows)
    local data={photoId=c.target:getRawMetadata("uuid"),catalogPath=c.path,count=#rows,revision=revision(c,rows)}
    local index=selectedIndex();local row=index~=nil and find(rows,index) or nil
    data.hasSelection=row~=nil
    if row then
        api("getSelectedSpotParams");api("getSelectedSpotType")
        local params=Controller.getSelectedSpotParams()
        if type(params)~="table" then fail("spot_params_unavailable","Selected spot parameters are unavailable") end
        data.spotIndex=index;data.spot=copy(row.spot);data.params=copy(params)
        data.spotType,data.useGenerativeAI=Controller.getSelectedSpotType()
    end
    current(c)
    return data
end
local function selectTarget(c,req)
    if not finite(req.spotIndex) or req.spotIndex<0 or req.spotIndex~=math.floor(req.spotIndex) or req.expectedSpot==nil then fail("invalid_arguments","spotIndex and expectedSpot are required") end
    local before=spots(c);local target=find(before,req.spotIndex)
    if not target then fail("spot_not_found","No spot at the requested native index") end
    if not equal(target.spot,req.expectedSpot) then fail("spot_changed","Spot changed or indices shifted; list spots again") end
    api("setSelectedSpotIndex")
    if selectedIndex()~=req.spotIndex then
        current(c);local ok,message=Controller.setSelectedSpotIndex(req.spotIndex)
        if ok==false then fail("selection_failed",tostring(message or "Spot selection rejected")) end
    end
    if not wait(c,function()return selectedIndex()==req.spotIndex end) then fail("selection_failed","Requested spot did not become selected") end
    local after=spots(c);local selected=find(after,req.spotIndex)
    if not selected or not equal(selected.spot,req.expectedSpot) then fail("spot_changed","Spot changed while selecting it") end
    return selection(c,after),after
end
local function targetStillSelected(c,index)
    current(c)
    if selectedIndex()~=index then fail("selection_changed","Selected spot changed") end
end
local preferenceFields={newSpotType="kind",brushSize="size",brushFeather="percent",useGenerativeAI="boolean",
    detectObjects="boolean",toolOverlay="overlay",visualizeSpots="boolean",visualizationThreshold="percent"}
local function preferences()
    api("getRemovePanelPreferences")
    local value=Controller.getRemovePanelPreferences()
    if type(value)~="table" then fail("preferences_unavailable","Remove preferences unavailable") end
    return copy(value)
end
local function validatePrefs(changes)
    if type(changes)~="table" or next(changes)==nil then fail("invalid_arguments","Non-empty changes required") end
    for k,v in pairs(changes) do
        local kind=preferenceFields[k]
        if not kind then fail("invalid_arguments","Unknown Remove preference: "..tostring(k)) end
        if kind=="boolean" then if type(v)~="boolean" then fail("invalid_arguments",k.." must be boolean") end
        elseif kind=="kind" then if not kinds[v] then fail("invalid_arguments","Invalid newSpotType") end
        elseif kind=="overlay" then if not ({always=true,auto=true,selected=true,never=true})[v] then fail("invalid_arguments","Invalid toolOverlay") end
        elseif not finite(v) or v>(100) or v<(kind=="size" and 1 or 0) then fail("invalid_arguments","Invalid preference range: "..k) end
    end
end
local function observed(c,req,status)
    local ok,value=Tasks.pcall(function()return selection(c,spots(c))end)
    if ok then value.status=status;value.verification="sdk_completed_and_observed";return {success=true,data=value} end
    if type(value)~="table" or (value.code~="spots_unavailable" and value.code~="spot_params_unavailable") then error(value,0) end
    return {success=true,data={photoId=c.target:getRawMetadata("uuid"),spotIndex=req.spotIndex,status="pending",
        verification="sdk_request_submitted",note="SDK call returned but refreshed state is not yet available. Read state before retrying."}}
end
local function handleSpot(req)
    if req.command=="set_remove_preferences" then validatePrefs(req.changes) end
    local c=prepare(req);local cmd=req.command
    if cmd=="open_remove" or cmd=="get_remove_preferences" then
        return {success=true,data={photoId=c.target:getRawMetadata("uuid"),preferences=preferences(),status="ready",creationRequiresUserDrawing=true}}
    elseif cmd=="set_remove_preferences" then
        api("setRemovePanelPreferences");current(c)
        local ok,message=Controller.setRemovePanelPreferences(copy(req.changes))
        if ok==false then fail("preference_failed",tostring(message or "Remove preference rejected")) end
        local actual
        if not wait(c,function()
            actual=preferences()
            for k,v in pairs(req.changes) do if not equal(actual[k],v) then return false end end
            return true
        end) then fail("readback_failed","Remove preferences did not match the requested values",{preferences=actual}) end
        return {success=true,data={photoId=c.target:getRawMetadata("uuid"),preferences=actual}}
    elseif cmd=="list_spots" or cmd=="get_selected_spot" then
        local rows=spots(c);local data=selection(c,rows)
        if cmd=="list_spots" then
            local offset,limit=req.offset or 0,req.limit or 50
            if not finite(offset) or offset<0 or offset~=math.floor(offset) or not finite(limit) or limit<1 or limit>200 or limit~=math.floor(limit) then fail("invalid_arguments","Invalid pagination") end
            data.spots={};data.offset=offset;data.hasMore=offset+limit<#rows
            for i=offset+1,math.min(offset+limit,#rows) do data.spots[#data.spots+1]=rows[i] end
        end
        return {success=true,data=data}
    elseif cmd=="reset_healing" then
        local before=spots(c)
        if req.expectedRevision~=revision(c,before) then fail("spots_changed","Spot list revision changed; list again before resetting") end
        api("resetHealing");current(c);Controller.resetHealing()
        if not wait(c,function()local rows=readOnce(c);return rows and #rows==0 end,5) then fail("readback_failed","Healing reset was not verified") end
        return {success=true,data={photoId=c.target:getRawMetadata("uuid"),status="reset",removedCount=#before}}
    end
    local before,rows=selectTarget(c,req)
    if cmd=="select_spot" then return {success=true,data=before} end
    local index=req.spotIndex
    if cmd=="update_spot" then
        api("setSelectedSpotParams")
        if type(req.changes)~="table" or next(req.changes)==nil then fail("invalid_arguments","Non-empty numeric changes required") end
        local params=copy(before.params)
        for key,value in pairs(req.changes) do
            if (key~="Opacity" and key~="Feather") or not finite(value) or value<0 or value>1 or not finite(params[key]) then fail("unsupported_parameter","Only observed Opacity/Feather values from 0 to 1 can be patched") end
            params[key]=value
        end
        targetStillSelected(c,index)
        local ok=Controller.setSelectedSpotParams(params)
        if ok==false then fail("spot_update_failed","Lightroom rejected spot parameters") end
        local actual
        if not wait(c,function()
            targetStillSelected(c,index);actual=Controller.getSelectedSpotParams()
            if type(actual)~="table" then return false end
            for key,value in pairs(req.changes) do if not equal(actual[key],value) then return false end end
            return true
        end) then fail("readback_failed","SDK did not retain spot parameters (observed on Lightroom 15.2); no raw-settings fallback",{params=actual,spotIndex=index}) end
        return observed(c,req,"updated")
    elseif cmd=="set_spot_type" then
        if not kinds[req.spotType] or (req.useGenerativeAI~=nil and type(req.useGenerativeAI)~="boolean") or (req.useGenerativeAI and req.spotType~="heal_patchmatch") then fail("invalid_arguments","Invalid spot type/generative combination") end
        api("setSelectedSpotType");targetStillSelected(c,index)
        local accepted=Controller.setSelectedSpotType(req.spotType,req.useGenerativeAI==true)
        if accepted==false then fail("spot_update_failed","Lightroom rejected spot type") end
        if req.useGenerativeAI then return observed(c,req,"requested") end
        if not wait(c,function()
            targetStillSelected(c,index)
            local kind,gen=Controller.getSelectedSpotType()
            return kind==req.spotType and (kind~="heal_patchmatch" or gen~=true)
        end) then fail("readback_failed","Spot type was not retained") end
        return observed(c,req,"updated")
    elseif cmd=="move_spot" then
        if (req.horizontal~=nil and req.horizontal~="left" and req.horizontal~="right") or (req.vertical~=nil and req.vertical~="up" and req.vertical~="down") or (not req.horizontal and not req.vertical) then fail("invalid_arguments","Provide valid horizontal and/or vertical direction") end
        for _,key in ipairs({"horizontalUnits","verticalUnits"}) do if req[key]~=nil and (not finite(req[key]) or req[key]<=0 or req[key]>1000) then fail("invalid_arguments","Invalid movement units") end end
        if (req.horizontalUnits and not req.horizontal) or (req.verticalUnits and not req.vertical) then fail("invalid_arguments","Units require a direction") end
        if req.sourceArea and before.spotType~="heal" and before.spotType~="clone" then fail("unsupported_operation","Source-area movement requires heal or clone") end
        api("moveSelectedSpot");targetStillSelected(c,index)
        Controller.moveSelectedSpot(req.horizontal,req.vertical,req.horizontalUnits,req.verticalUnits,req.sourceArea==true)
        if not wait(c,function()
            targetStillSelected(c,index)
            local after=find(spots(c),index)
            return after and not equal(after.spot,before.spot)
        end) then fail("movement_unverified","SDK call returned but no region/source change was observed; inspect before retrying",{spotIndex=index}) end
        return observed(c,req,"moved")
    elseif cmd=="refresh_spot" then
        if before.useGenerativeAI and req.allowGenerativeRefresh~=true then fail("generative_refresh_not_authorized","Set allowGenerativeRefresh=true only when Adobe generative reprocessing is intended") end
        api("refreshSelectedSpot");targetStillSelected(c,index);Controller.refreshSelectedSpot()
        return observed(c,req,before.useGenerativeAI and "requested" or "sdk_completed")
    elseif cmd=="cycle_spot_variation" then
        if before.spotType~="heal_patchmatch" or before.useGenerativeAI~=true then fail("not_generative_spot","Variation navigation requires an existing generative spot") end
        if req.direction~="next" and req.direction~="previous" then fail("invalid_arguments","direction must be next or previous") end
        local method=req.direction=="next" and "gotoNextVariation" or "gotoPreviousVariation"
        api(method);targetStillSelected(c,index);Controller[method]()
        return observed(c,req,"sdk_completed")
    elseif cmd=="delete_spot" then
        api("deleteSelectedSpot");targetStillSelected(c,index)
        Controller.deleteSelectedSpot()
        local remaining={};for _,row in ipairs(rows) do if row.spotIndex~=index then remaining[#remaining+1]=row.spot end end
        if not wait(c,function()
            local after=readOnce(c)
            if not after or #after~=#remaining then return false end
            for i,row in ipairs(after) do if not equal(row.spot,remaining[i]) then return false end end
            return true
        end,5) then fail("deletion_unverified","Remaining spot list did not match; inspect before retrying",{spotIndex=index}) end
        return {success=true,data={photoId=c.target:getRawMetadata("uuid"),status="deleted",deletedSpotIndex=index,remainingCount=#remaining}}
    end
    fail("unknown_command","Unknown healing command")
end
-- SDK AI maintenance writes target photo objects, not the current UI region.
_lrMcpAIUpdateJobs=_lrMcpAIUpdateJobs or {}
local jobs=_lrMcpAIUpdateJobs
local function jobStatus(job)
    return {success=true,data=copy(job)}
end
local function write(c,label,fn)
    local entered,result=false,nil
    c.catalog:withWriteAccessDo(label,function()Library.check(c,true);entered=true;result=fn()end,{timeout=5})
    if not entered then fail("write_timeout","Catalog write access was not acquired") end
    return result
end
local function startAI(req)
    if type(req.jobId)~="string" or not req.jobId:match("^[a-f0-9]+$") or #req.jobId~=32 then fail("invalid_arguments","Invalid job ID") end
    if jobs[req.jobId] then fail("duplicate_job","AI job ID already exists") end
    for _,job in pairs(jobs) do if job.status=="queued" or job.status=="running" or job.status=="cancelling" then fail("ai_update_busy","An AI update is still running",{jobId=job.jobId}) end end
    local c=Library.context(req);local photos=Library.targets(c,req)
    for _,photo in ipairs(photos) do
        if type(photo.updateAISettings)~="function" then fail("unsupported_api","This Lightroom version has no photo:updateAISettings") end
        if photo:getRawMetadata("isVideo") then fail("unsupported_photo","AI maintenance requires photos") end
    end
    local job={jobId=req.jobId,catalogPath=c.path,status="queued",total=#photos,completed=0,failed=0,notStarted=#photos,
        cancelRequested=false,results={},createdAt=Date.currentTime(),verification="native_calls_only"}
    jobs[req.jobId]=job
    Tasks.startAsyncTask(function()
        local ok,err=Tasks.pcall(function()
            job.status="running"
            for _,photo in ipairs(photos) do
                if job.cancelRequested then break end
                local row={photoId=photo:getRawMetadata("uuid"),status="updating"};job.results[#job.results+1]=row;job.notStarted=job.total-#job.results
                local accepted,problem=Tasks.pcall(function()
                    Library.check(c,true)
                    local result=write(c,"MCP Update AI Settings",function()return photo:updateAISettings()end)
                    if result==false then fail("ai_update_failed","Lightroom rejected the AI update") end
                end)
                if accepted then row.success=true;row.status="sdk_completed";job.completed=job.completed+1
                else row.success=false;row.status="failed";row.error=type(problem)=="table" and problem.error or tostring(problem);row.code=type(problem)=="table" and problem.code or "sdk_error";row.outcomeUnknown=true;job.failed=job.failed+1;break end
                Tasks.sleep(0) -- Let the bridge service status/cancellation between photos.
            end
            job.status=job.cancelRequested and "cancelled" or (job.failed>0 and "failed" or "sdk_completed")
        end)
        if not ok then job.status="failed";job.error=type(err)=="table" and err.error or tostring(err) end
        job.finishedAt=Date.currentTime()
    end)
    return jobStatus(job)
end
local function maskIDs(photo)
    local settings=photo:getDevelopSettings()
    if type(settings)~="table" then fail("settings_unavailable","Catalog develop settings unavailable") end
    local raw=settings.MaskGroupBasedCorrections or {}
    if type(raw)~="table" then fail("unsupported_mask_data","Unknown catalog mask layout") end
    local ids={}
    for _,entry in pairs(raw) do if type(entry)~="table" or type(entry.CorrectionID)~="string" then fail("unsupported_mask_data","Unknown catalog mask ID") end;ids[entry.CorrectionID]=true end
    return ids
end
local function cleanup(req)
    local c=Library.context(req);local photos=Library.targets(c,req)
    if type(c.catalog.deleteAllEmptyMasks)~="function" then fail("unsupported_api","Empty-mask cleanup requires catalog:deleteAllEmptyMasks") end
    for _,p in ipairs(photos) do if p:getRawMetadata("isVideo") then fail("unsupported_photo","Mask cleanup requires photos") end end
    local results={}
    for _,photo in ipairs(photos) do
        local row={photoId=photo:getRawMetadata("uuid"),success=false};results[#results+1]=row
        local ok,err=Tasks.pcall(function()
            Library.check(c);local before=maskIDs(photo)
            local result=write(c,"MCP Clean Empty Masks",function()return c.catalog:deleteAllEmptyMasks({photo})end)
            if result==false then fail("cleanup_failed","SDK rejected empty-mask cleanup") end
            Library.check(c,true);local after=maskIDs(photo);row.removedMaskIds={}
            for id in pairs(before) do if not after[id] then row.removedMaskIds[#row.removedMaskIds+1]=id end end
            for id in pairs(after) do if not before[id] then fail("mask_state_changed","New masks appeared during cleanup") end end
            table.sort(row.removedMaskIds);row.success=true;row.verification="sdk_completed_and_catalog_diff"
        end)
        if not ok then row.error=type(err)=="table" and err.error or tostring(err);row.outcomeUnknown=true;return {success=false,code="partial_failure",error="Empty-mask cleanup stopped after a failed photo",data={results=results}} end
    end
    return {success=true,data={catalogPath=c.path,results=results}}
end
function Healing.handle(req)
    local ok,result=Tasks.pcall(function()
        if req.command=="update_ai_settings" then return startAI(req) end
        if req.command=="get_ai_update_status" or req.command=="cancel_ai_update" then
            local job=jobs[req.jobId]
            if not job then fail("job_not_found","Unknown AI job in this plugin session; a prior update may still have occurred") end
            if req.command=="cancel_ai_update" and (job.status=="queued" or job.status=="running" or job.status=="cancelling") then job.cancelRequested=true;job.status="cancelling" end
            return jobStatus(job)
        end
        if req.command=="cleanup_empty_masks" then return cleanup(req) end
        return handleSpot(req)
    end)
    if ok then return result end
    return type(result)=="table" and result or {success=false,code="sdk_error",error=tostring(result)}
end
function Healing.capabilities()
    local result={}
    for _,name in ipairs({"goToRemove","countAllSpots","getAllSpots","getSelectedSpotIndex","getSelectedSpotParams","getSelectedSpotType",
        "setSelectedSpotIndex","setSelectedSpotParams","setSelectedSpotType","moveSelectedSpot","refreshSelectedSpot","deleteSelectedSpot",
        "gotoNextVariation","gotoPreviousVariation","getRemovePanelPreferences","setRemovePanelPreferences","resetHealing"}) do result[name]=type(Controller[name])=="function" end
    local c=Library.context({});result.deleteAllEmptyMasks=type(c.catalog.deleteAllEmptyMasks)=="function"
    result.updateAISettings=c.target and type(c.target.updateAISettings)=="function" or false
    result.programmaticStrokeCreation=false;result.aiJobCompletion="native_call_returned"
    return result
end
return Healing
