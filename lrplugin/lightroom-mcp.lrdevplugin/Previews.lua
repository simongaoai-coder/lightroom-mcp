-- SDK-owned smart previews only. No direct preview/original filesystem mutation.
local Tasks=import 'LrTasks'
local Date=import 'LrDate'
local Library=require 'Library'
local Previews={VERSION='2.11.0',commands={get_smart_previews=true,build_smart_previews=true,
    delete_smart_previews=true,get_smart_preview_job=true,cancel_smart_preview_job=true}}
local jobs,order={},{}
local fail=Library.fail
local function api(p,name)
    if type(p[name])~='function' then fail('unsupported_api',name..' unavailable') end
end
local function info(p)
    api(p,'checkPhotoAvailability')
    local value=p:getRawMetadata('smartPreviewInfo')
    if type(value)~='table' then fail('preview_state_unknown','SDK did not return smartPreviewInfo') end
    local present=next(value)~=nil
    if present and (type(value.smartPreviewPath)~='string' or value.smartPreviewPath=='') then
        fail('preview_state_unknown','Unrecognized smart-preview metadata')
    end
    local available=p:checkPhotoAvailability()
    if type(available)~='boolean' then fail('availability_unknown','Original availability is unknown') end
    return {photoId=p:getRawMetadata('uuid'),isVideo=p:getRawMetadata('isVideo')==true,
        hasSmartPreview=present,originalAvailable=available,
        path=value.smartPreviewPath,bytes=value.smartPreviewSize}
end
local function id(value)
    if type(value)~='string' or #value~=32 or not value:match('^[a-f0-9]+$') then fail('invalid_arguments','Invalid jobId') end
    return value
end
local function active(job) return job.status=='queued' or job.status=='running' or job.status=='cancelling' end
local function status(job,req)
    local offset,limit=req.offset or 0,req.limit or 50
    if type(offset)~='number' or offset<0 or offset%1~=0 or type(limit)~='number' or limit<1 or limit>200 or limit%1~=0 then
        fail('invalid_arguments','Invalid pagination')
    end
    local out=Library.clone(job);out.results={}
    for i=offset+1,math.min(offset+limit,#job.results) do out.results[#out.results+1]=Library.clone(job.results[i]) end
    out.offset=offset;out.hasMore=offset+limit<#job.results;out.notStarted=job.total-#job.results
    return {success=true,data=out}
end
local function guard(c,p,pid)
    Library.check(c,true)
    if c.catalog:findPhotoByUuid(pid)~=p then fail('photo_not_found','Captured photo is no longer in the catalog') end
end
local function preflight(p,operation,allowOffline)
    local current=info(p)
    if current.isVideo then fail('unsupported_photo','Smart preview operations require photos') end
    api(p,operation=='build' and 'buildSmartPreview' or 'deleteSmartPreview')
    if operation=='build' and not current.hasSmartPreview and not current.originalAvailable then
        fail('photo_unavailable','Original is offline; cannot build a missing smart preview')
    end
    if operation=='delete' and current.hasSmartPreview and not current.originalAvailable and not allowOffline then
        fail('offline_preview_protected','Use allowOffline=true to delete a preview whose original is offline')
    end
    return current
end
local function start(req)
    local jobId=id(req.jobId)
    if jobs[jobId] then fail('duplicate_job','Job already exists; inspect its status') end
    for _,job in pairs(jobs) do if active(job) then fail('preview_busy','Another smart-preview job is active') end end
    if req.allowOffline~=nil and type(req.allowOffline)~='boolean' then fail('invalid_arguments','allowOffline must be boolean') end
    local operation=req.command=='build_smart_previews' and 'build' or 'delete'
    local c=Library.context(req);local photos,ids={},{}
    for i,p in ipairs(Library.targets(c,req)) do photos[i]=p end
    api(c.catalog,'findPhotoByUuid')
    for i,p in ipairs(photos) do preflight(p,operation,req.allowOffline);ids[i]=p:getRawMetadata('uuid') end
    Library.check(c)
    local job={jobId=jobId,status='queued',operation=operation,catalogPath=c.path,total=#photos,
        completed=0,failed=0,cancelRequested=false,results={},createdAt=Date.currentTime()}
    while #order>=20 do jobs[table.remove(order,1)]=nil end
    jobs[jobId]=job;order[#order+1]=jobId
    local allowOffline=req.allowOffline==true
    Tasks.startAsyncTask(function()
        job.status=job.cancelRequested and 'cancelling' or 'running'
        local ok,problem=Tasks.pcall(function()
            for i,p in ipairs(photos) do
                if job.cancelRequested then break end
                local row={photoId=ids[i],success=false};job.results[#job.results+1]=row
                local success,err=Tasks.pcall(function()
                    guard(c,p,ids[i]);row.before=preflight(p,operation,allowOffline);guard(c,p,ids[i])
                    if row.before.hasSmartPreview==(operation=='build') then
                        row.status='unchanged';row.after=row.before;row.success=true;return
                    end
                    local native,detail
                    row.nativeCallAttempted=true
                    if operation=='build' then native,detail=p:buildSmartPreview()
                    else native,detail=p:deleteSmartPreview() end
                    row.nativeResult=native
                    if (operation=='build' and native~='created' and native~='existed') or
                       (operation=='delete' and native~='deleted') then
                        fail('preview_operation_failed',tostring(detail or native or 'No native result'))
                    end
                    local deadline=Date.currentTime()+3
                    repeat
                        guard(c,p,ids[i]);row.after=info(p);guard(c,p,ids[i])
                        if row.after.hasSmartPreview==(operation=='build') then
                            row.status=native;row.success=true;return
                        end
                        Tasks.sleep(.05)
                    until Date.currentTime()>=deadline
                    fail('readback_failed','Smart preview state did not match requested state')
                end)
                if not success then
                    row.code=type(err)=='table' and err.code or 'sdk_error'
                    row.error=type(err)=='table' and err.error or tostring(err)
                    row.outcomeUnknown=row.nativeCallAttempted==true
                    if row.nativeCallAttempted then
                        local readOK,observed=Tasks.pcall(function() guard(c,p,ids[i]);return info(p) end)
                        if readOK then row.after=observed end
                    end
                    job.failed=job.failed+1;break
                end
                job.completed=job.completed+1
                Tasks.sleep(0) -- allow status/cancel requests between photos
            end
        end)
        if not ok then job.error=type(problem)=='table' and problem.error or tostring(problem) end
        if not ok or job.failed>0 then job.status='failed'
        elseif job.cancelRequested then job.status='cancelled'
        else job.status='completed' end
        job.finishedAt=Date.currentTime()
    end)
    return status(job,{})
end
function Previews.handle(req)
    local ok,result=Tasks.pcall(function()
        if req.command=='get_smart_previews' then
            local c=Library.context(req);local out={}
            for _,p in ipairs(Library.targets(c,req)) do
                Library.check(c);out[#out+1]=info(p);Library.check(c)
            end
            return {success=true,data={photos=out,catalogPath=c.path}}
        elseif req.command=='build_smart_previews' or req.command=='delete_smart_previews' then return start(req)
        elseif req.command=='get_smart_preview_job' or req.command=='cancel_smart_preview_job' then
            local job=jobs[id(req.jobId)]
            if not job then fail('job_not_found','Unknown session job; work may already have occurred') end
            if req.command=='cancel_smart_preview_job' and active(job) then job.cancelRequested=true;job.status='cancelling' end
            return status(job,req)
        end
        fail('unknown_command','Unknown preview command')
    end)
    if ok then return result end
    return type(result)=='table' and result or {success=false,code='sdk_error',error=tostring(result)}
end
function Previews.capabilities()
    local p=Library.context({}).target;local apis={}
    if p then for _,name in ipairs({'buildSmartPreview','deleteSmartPreview','checkPhotoAvailability'}) do apis[name]=type(p[name])=='function' end end
    return {sessionJobs=true,retainedJobs=20,cancellation='between_photos',verification='smartPreviewInfo',
        photoSelected=p~=nil,photoAPIs=p and apis or nil}
end
return Previews
