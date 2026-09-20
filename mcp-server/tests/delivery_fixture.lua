local oldImport=import
function import(name)
    if name=='LrFileUtils' then return {exists=py_exists,createAllDirectories=py_mkdir,resolveAllAliases=py_resolve} end
    if name=='LrPathUtils' then return {
        isAbsolute=function(path)return path:sub(1,1)=='/' end,standardizePath=py_resolve,
        child=function(a,b)return a:gsub('/$','')..'/'..b end,
        parent=function(path)local p=path:match('^(.*)/[^/]+$');return state.parentTrailingSlash and p..'/' or p end,
    } end
    if name=='LrExportSession' then return function(params)
        assert(#params.photosToExport==1)
        state.lastExportSettings=params.exportSettings
        local p=params.photosToExport[1]
        local rendition={photo=p}
        function rendition:waitForRender()
            if state.failRender==p.id then return false,'injected render failure' end
            local settings=params.exportSettings
            local path=settings.LR_export_destinationPathPrefix..'/'..p.id..'-'..settings.LR_initialSequenceNumber..(settings.LR_format=='TIFF' and '.tif' or '.jpg')
            local f=assert(io.open(path,'wb'));f:write(state.emptyRender and '' or 'rendered-test-file');f:close()
            if state.cancelAfterFirst then for _,job in pairs(_lrMcpDeliveryJobs) do job.cancelRequested=true end end
            return true,path
        end
        return {renditions=function()
            local i=0
            return function()i=i+1;if i==1 then return i,rendition end end
        end}
    end end
    return oldImport(name)
end
