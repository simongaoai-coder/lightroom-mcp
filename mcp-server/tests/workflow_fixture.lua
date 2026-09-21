local oldImport=import
function import(name)
    if name=='LrDevelopController' then return {} end
    return oldImport(name)
end
function catalog:withReadAccessDo(fn)return fn()end
local oldWrite=catalog.withWriteAccessDo
function catalog:withWriteAccessDo(label,fn,opts)
    if state.staleBeforeWrite then photos.a.raw.Exposure2012=2 end
    return oldWrite(self,label,fn,opts)
end
for _,p in pairs(photos) do
    p.meta.smartPreviewInfo={}
    p.raw={ProcessVersion='15.4',Exposure2012=p.id=='a' and 0 or 1,
        Contrast2012=0,Temperature=6500,Tint=0,WhiteBalance='As Shot',
        SplitToningHighlightHue=0,SplitToningHighlightSaturation=0,
        SplitToningShadowHue=0,SplitToningShadowSaturation=0,SplitToningBalance=0}
    function p:getDevelopSettings()
        local t={};for k,v in pairs(self.raw)do t[k]=v end;return t
    end
    function p:applyDevelopSettings(settings)
        state.writes=state.writes+1
        if state.failPhoto==self.id then error('injected failure') end
        if not state.noop then for k,v in pairs(settings)do self.raw[k]=v end end
    end
    function p:buildSmartPreview()
        state.previewCalls=(state.previewCalls or 0)+1
        if state.nativeFail==self.id then return 'failed' end
        if state.nativeThrow==self.id then error('build exploded') end
        if not state.noop then self.meta.smartPreviewInfo={smartPreviewPath='/preview/'..self.id..'.dng',smartPreviewSize=123} end
        if state.afterPreview then state.afterPreview(self) end
        return 'created'
    end
    function p:deleteSmartPreview()
        state.previewCalls=(state.previewCalls or 0)+1
        if state.nativeFail==self.id then return 'failed','delete failed' end
        if not state.noop then self.meta.smartPreviewInfo={} end
        if state.afterPreview then state.afterPreview(self) end
        return 'deleted'
    end
end
