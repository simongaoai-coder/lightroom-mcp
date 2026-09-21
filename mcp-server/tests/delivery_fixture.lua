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
        state.exportSettingsHistory=state.exportSettingsHistory or {};state.exportSettingsHistory[#state.exportSettingsHistory+1]=params.exportSettings
        local p=params.photosToExport[1]
        local rendition={photo=p}
        function rendition:waitForRender()
            if state.failRender==p.id then return false,'injected render failure' end
            local settings=params.exportSettings
            local stem=state.sameBasename and 'same' or p.id
            if settings.LR_renamingTokensOn then
                local digits=tonumber(settings.LR_tokens:match('sequenceNumber_(%d)'))
                if settings.LR_tokens:find('custom_token',1,true) then stem=settings.LR_tokenCustomString end
                stem=stem..'-'..string.format('%0'..digits..'d',settings.LR_initialSequenceNumber)
            end
            local ext=settings.LR_format=='TIFF' and '.tif' or '.jpg'
            if settings.LR_extensionCase=='uppercase' then ext=ext:upper()end
            local path=settings.LR_export_destinationPathPrefix..'/'..stem..ext
            local suffix=1
            while py_exists(path) do
                assert(settings.LR_collisionHandling=='rename')
                suffix=suffix+1;path=settings.LR_export_destinationPathPrefix..'/'..stem..'-'..suffix..ext
            end
            local f=assert(io.open(path,'wb'));f:write(state.emptyRender and '' or state.renderBytes and string.rep('x',state.renderBytes) or 'rendered-test-file');f:close()
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
