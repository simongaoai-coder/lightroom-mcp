-- Native file exports run in a separate cooperative task, never inside a catalog write gate.
local Tasks=import "LrTasks"
local Files=import "LrFileUtils"
local Paths=import "LrPathUtils"
local ExportSession=import "LrExportSession"
local Date=import "LrDate"
local Library=require "Library"
local Delivery={VERSION="2.3.2",commands={export_photos=true,get_export_status=true,cancel_export=true}}
_lrMcpDeliveryJobs=_lrMcpDeliveryJobs or {}
local jobs=_lrMcpDeliveryJobs
local fail=Library.fail
local function finite(v,low,high)
    return type(v)=="number" and v==v and math.abs(v)<math.huge and v>=low and v<=high
end
local function validate(req)
    if type(req.jobId)~="string" or not req.jobId:match("^[a-f0-9]+$") or #req.jobId~=32 then fail("invalid_arguments","Invalid export job ID") end
    if type(req.destination)~="string" or req.destination:find("[%z\1-\31]") or not Paths.isAbsolute(req.destination) then fail("invalid_arguments","destination must be an absolute directory") end
    if Files.exists(req.destination)~="directory" then fail("destination_not_found","Export destination must already exist") end
    local format=req.format or "JPEG"
    if format~="JPEG" and format~="TIFF" then fail("invalid_arguments","format must be JPEG or TIFF") end
    if req.quality~=nil and (format~="JPEG" or not finite(req.quality,1,100) or req.quality~=math.floor(req.quality)) then fail("invalid_arguments","quality is a JPEG integer from 1 to 100") end
    if req.bitDepth~=nil and (format~="TIFF" or (req.bitDepth~=8 and req.bitDepth~=16)) then fail("invalid_arguments","bitDepth is 8 or 16 for TIFF only") end
    if req.longEdge~=nil and (not finite(req.longEdge,1,65000) or req.longEdge~=math.floor(req.longEdge)) then fail("invalid_arguments","Invalid longEdge") end
    if req.resolution~=nil and not finite(req.resolution,1,1200) then fail("invalid_arguments","Invalid resolution") end
    if not ({sRGB=true,AdobeRGB=true,ProPhotoRGB=true})[req.colorSpace or "sRGB"] then fail("invalid_arguments","Invalid colorSpace") end
    if not ({none=true,screen=true,matte=true,glossy=true})[req.sharpenFor or "none"] then fail("invalid_arguments","Invalid sharpenFor") end
    if req.sharpenAmount~=nil and req.sharpenAmount~=1 and req.sharpenAmount~=2 and req.sharpenAmount~=3 then fail("invalid_arguments","Invalid sharpenAmount") end
    if not ({all=true,allExceptCameraInfo=true,copyrightOnly=true,copyrightAndContactOnly=true})[req.metadata or "all"] then fail("invalid_arguments","Invalid metadata option") end
    for _,key in ipairs({"doNotEnlarge","removeLocation"}) do if req[key]~=nil and type(req[key])~="boolean" then fail("invalid_arguments",key.." must be boolean") end end
    if req.watermarkId~=nil and (type(req.watermarkId)~="string" or not req.watermarkId:match("%S")) then fail("invalid_arguments","Invalid watermarkId") end
    return format
end
local function status(job,req)
    local offset,limit=req.offset or 0,req.limit or 50
    if not finite(offset,0,math.huge) or offset~=math.floor(offset) or not finite(limit,1,200) or limit~=math.floor(limit) then fail("invalid_arguments","Invalid status pagination") end
    local result={jobId=job.jobId,status=job.status,catalogPath=job.catalogPath,outputDirectory=job.outputDirectory,
        total=job.total,completed=job.completed,failed=job.failed,notStarted=job.total-#job.results,
        cancelRequested=job.cancelRequested,createdAt=job.createdAt,finishedAt=job.finishedAt,error=job.error,
        format=job.format,results={},offset=offset,hasMore=offset+limit<#job.results}
    for i=offset+1,math.min(offset+limit,#job.results) do result.results[#result.results+1]=Library.clone(job.results[i]) end
    return {success=true,data=result}
end
local function canonical(path)
    return Paths.standardizePath(Files.resolveAllAliases(path)):gsub("[/\\]+$", "")
end
local function settings(req,folder,index)
    local format=req.format or "JPEG"
    return {
        LR_export_destinationType="specificFolder",LR_export_destinationPathPrefix=folder,LR_export_useSubfolder=false,
        LR_format=format,LR_export_colorSpace=req.colorSpace or "sRGB",LR_export_bitDepth=req.bitDepth or 16,
        LR_jpeg_quality=(req.quality or 90)/100,LR_jpeg_useLimitSize=false,
        LR_tiff_compressionMethod="compressionMethod_ZIP",
        LR_size_doConstrain=req.longEdge~=nil,LR_size_resizeType="longEdge",LR_size_maxHeight=req.longEdge or 0,
        LR_size_maxWidth=req.longEdge or 0,LR_size_units="pixels",LR_size_doNotEnlarge=req.doNotEnlarge~=false,
        LR_size_resolution=req.resolution or 240,LR_size_resolutionUnits="inch",
        LR_outputSharpeningOn=req.sharpenFor~=nil and req.sharpenFor~="none",LR_outputSharpeningMedia=req.sharpenFor~="none" and req.sharpenFor or "screen",
        LR_outputSharpeningLevel=req.sharpenAmount or 2,LR_embeddedMetadataOption=req.metadata or "all",
        LR_minimizeEmbeddedMetadata=false,LR_removeLocationMetadata=req.removeLocation==true,
        LR_metadata_keywordOptions="flat",LR_useWatermark=req.watermarkId~=nil,LR_watermarking_id=req.watermarkId,
        LR_reimportExportedPhoto=false,LR_includeVideoFiles=false,LR_collisionHandling="rename",LR_extensionCase="lowercase",
        LR_renamingTokensOn=true,LR_tokens="{{image_name}}-{{naming_sequenceNumber_4Digits}}",LR_initialSequenceNumber=index,
    }
end
local function start(req)
    local format=validate(req)
    if jobs[req.jobId] then fail("duplicate_job","Export job ID already exists") end
    for _,job in pairs(jobs) do if job.status=="queued" or job.status=="running" or job.status=="cancelling" then fail("export_busy","Another export is still running",{jobId=job.jobId}) end end
    local c=Library.context(req);local photos=Library.targets(c,req)
    for _,photo in ipairs(photos) do
        if photo:getRawMetadata("isVideo") then fail("unsupported_photo","Video export is outside this tool") end
        if type(photo.checkPhotoAvailability)~="function" then fail("unsupported_api","Photo availability check is unavailable") end
        if not photo:checkPhotoAvailability() then fail("photo_unavailable","Original photo is offline; no export started",{photoId=photo:getRawMetadata("uuid")}) end
    end
    Library.check(c)
    local folder=Paths.child(req.destination,"LR-MCP-export-"..req.jobId)
    if Files.exists(folder) then fail("destination_exists","Batch folder already exists; refusing to reuse it") end
    Files.createAllDirectories(folder)
    if Files.exists(folder)~="directory" then fail("destination_not_writable","Could not create batch folder") end
    local job={jobId=req.jobId,status="queued",catalogPath=c.path,outputDirectory=folder,
        total=#photos,completed=0,failed=0,results={},cancelRequested=false,createdAt=Date.currentTime(),format=format}
    jobs[req.jobId]=job
    local options=Library.clone(req)
    Tasks.startAsyncTask(function()
        local ok,err=Tasks.pcall(function()
            job.status="running"
            for index,photo in ipairs(photos) do
                if job.cancelRequested then break end
                Library.check(c,true)
                local item={photoId=photo:getRawMetadata("uuid"),status="rendering"};job.results[#job.results+1]=item
                local success,problem=Tasks.pcall(function()
                    -- One native session per photo bounds cancellation to one active render.
                    local session=ExportSession{photosToExport={photo},exportSettings=settings(options,folder,index)}
                    local count=0
                    for _,rendition in session:renditions() do
                        count=count+1
                        local rendered,path= rendition:waitForRender()
                        if not rendered then fail("render_failed",tostring(path)) end
                        if type(path)~="string" then fail("output_unverified","Renderer did not return a file path") end
                        item.path=path
                        local parent=Paths.parent(path)
                        if not parent or canonical(parent)~=canonical(folder) or Files.exists(path)~="file" then
                            fail("output_unverified","Renderer path could not be verified in the batch folder: "..path)
                        end
                        local f,openError=io.open(path,"rb")
                        if not f then fail("output_unreadable",tostring(openError)) end
                        local size=f:seek("end");f:close()
                        if not size or size<=0 then fail("empty_output","Rendered file was empty") end
                        item.path=path;item.bytes=size
                    end
                    if count~=1 then fail("output_unverified","Expected one rendered file per photo") end
                    item.success=true;item.status="completed"
                end)
                if success then job.completed=job.completed+1
                else
                    job.failed=job.failed+1;item.success=false;item.status="failed";item.code=type(problem)=="table" and problem.code or "sdk_error"
                    item.error=type(problem)=="table" and problem.error or tostring(problem)
                end
            end
            if job.cancelRequested then job.status="cancelled"
            elseif job.failed>0 then job.status="failed"
            else job.status="completed" end
        end)
        if not ok then job.status="failed";job.error=type(err)=="table" and err.error or tostring(err) end
        job.finishedAt=Date.currentTime()
    end)
    return status(job,{})
end
function Delivery.handle(req)
    local ok,result=Tasks.pcall(function()
        if req.command=="export_photos" then return start(req) end
        local job=jobs[req.jobId]
        if not job then fail("job_not_found","Job is unknown in this plugin session; existing files may still be present. Do not assume no export occurred.",{jobId=req.jobId}) end
        if req.command=="cancel_export" and (job.status=="queued" or job.status=="running" or job.status=="cancelling") then
            job.cancelRequested=true;job.status="cancelling"
        end
        return status(job,req)
    end)
    if ok then return result end
    return type(result)=="table" and result or {success=false,code="sdk_error",error=tostring(result)}
end
function Delivery.capabilities() return {nativeExport=true,formats={"JPEG","TIFF"},jobsSurvivePluginReload=false,cancellation="between_photos"} end
return Delivery
