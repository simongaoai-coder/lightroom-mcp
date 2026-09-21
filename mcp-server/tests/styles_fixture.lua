local oldImport=import
prefs={};nativePresets={};state.nativeCreates=0
local app=oldImport('LrApplication')
function app.developPresetFolders()return {}end
function app.getDevelopPresetsForPlugin()return nativePresets end
local function clone(v)
    if type(v)~='table' then return v end;local t={};for k,x in pairs(v)do t[k]=clone(x)end;return t
end
function app.addDevelopPresetForPlugin(plugin,name,values)
    state.nativeCreates=state.nativeCreates+1
    local p={id='style-'..state.nativeCreates,name=name,settings=clone(values)}
    function p:getUuid()return self.id end
    function p:getName()return self.name end
    function p:getSetting()return clone(self.settings)end
    if state.dropPresetField then p.settings[state.dropPresetField]=nil end
    if state.extraPresetField then p.settings.Exposure2012=3 end
    nativePresets[#nativePresets+1]=p;return p
end
function import(name)
    if name=='LrPrefs' then return {prefsForPlugin=function()return prefs end} end
    if name=='LrApplication' then return app end
    if name=='LrFileUtils' then return {}end
    if name=='LrLogger' then return function()return {enable=function()end}end end
    return oldImport(name)
end
_PLUGIN={id='test.plugin',path='/test/plugin'}
for _,p in pairs(photos) do
    p.meta.orientation='AB'
    for _,k in ipairs({'ColorGradeBlending','ColorGradeGlobalHue','ColorGradeGlobalSat','ColorGradeGlobalLum','ColorGradeMidtoneHue','ColorGradeMidtoneSat','ColorGradeMidtoneLum','ColorGradeHighlightLum','ColorGradeShadowLum'}) do p.raw[k]=0 end
    p.raw.GrainAmount=20;p.raw.GrainSize=25;p.raw.GrainFrequency=50
    for _,k in ipairs({'ToneCurvePV2012','ToneCurvePV2012Red','ToneCurvePV2012Green','ToneCurvePV2012Blue'})do p.raw[k]={0,0,255,255}end
    function p:applyDevelopPreset(preset,plugin,amount)
        state.presetCalls=(state.presetCalls or 0)+1
        if state.failPhoto==self.id then error('preset failed')end
        if not state.noop then for k,v in pairs(preset.settings)do self.raw[k]=clone(v)end end
    end
    function p:quickDevelopSetTreatment(value)
        state.writes=state.writes+1
        if not state.noop then self.raw.ConvertToGrayscale=value=='grayscale' end
    end
    function p:quickDevelopSetWhiteBalance(value)
        state.writes=state.writes+1
        if not state.noop then self.raw.WhiteBalance=value end
    end
    function p:rotateRight()
        state.writes=state.writes+1
        if not state.noop then
            local map={A='B',B='C',C='D',D='A'}
            self.meta.orientation=map[self.meta.orientation:sub(1,1)]..map[self.meta.orientation:sub(2,2)]
        end
    end
    function p:rotateLeft()
        state.writes=state.writes+1
        if not state.noop then
            local map={A='D',B='A',C='B',D='C'}
            self.meta.orientation=map[self.meta.orientation:sub(1,1)]..map[self.meta.orientation:sub(2,2)]
        end
    end
end
