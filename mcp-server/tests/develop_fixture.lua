state = {now=0, writes=0, selected="a", failPhoto=nil, noop=false, lockTimeout=false}
photos = {}
local function newPhoto(id)
    local photo = {id=id, raw={ProcessVersion="15.4", Exposure=4, Exposure2012=0, Contrast2012=0,
        Highlights2012=0, Shadows2012=0, Whites2012=0, Blacks2012=0, Clarity2012=0,
        Temperature=6500, Tint=0, WhiteBalance="As Shot", RedHue=0, LensBlurActive=false,
        CropTop=0, CropBottom=1, CropLeft=0, CropRight=1, CropAngle=0,
        ToneCurvePV2012={0,0,255,255}}}
    function photo:getRawMetadata(key) if key=="uuid" then return self.id elseif key=="rating" then return 3 elseif key=="isVideo" then return self.video end end
    function photo:getFormattedMetadata() return self.id .. ".NEF" end
    function photo:getDevelopSettings()
        local result = {}
        for key,value in pairs(self.raw) do result[key] = value end
        return result
    end
    function photo:applyDevelopSettings(settings)
        state.writes=state.writes+1
        if state.failPhoto==self.id then error("injected write failure") end
        if state.noop then return end
        for key,value in pairs(settings) do self.raw[key]=value end
    end
    return photo
end
photos.a, photos.b = newPhoto("a"), newPhoto("b")
catalog = {}
function catalog:getTargetPhoto() return photos[state.selected] end
function catalog:getTargetPhotos() return {photos.a, photos.b} end
function catalog:withReadAccessDo(fn) return fn() end
function catalog:withWriteAccessDo(name, fn)
    if state.lockTimeout then return "aborted" end
    if state.switchBeforeWrite then state.selected="b" end
    return fn()
end
controller = {getValue=function() return 0 end}
function import(name)
    if name=="LrApplication" then return {activeCatalog=function() return catalog end, versionString=function() return "15.4" end} end
    if name=="LrDevelopController" then return controller end
    if name=="LrTasks" then return {pcall=pcall, sleep=function(t) state.now=state.now+t end} end
    if name=="LrDate" then return {currentTime=function() return state.now end} end
    error("unexpected import " .. name)
end
