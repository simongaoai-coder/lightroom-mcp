local baseGet=state.photo.getDevelopSettings
state.raw={ProcessVersion="11.0",WhiteBalance="Custom",Temperature=5000,Tint=0,
    ToneCurvePV2012={0,0,255,255},ToneCurvePV2012Red={0,0,255,255},
    ToneCurvePV2012Green={0,0,255,255},ToneCurvePV2012Blue={0,0,255,255}}
local function clone(v) if type(v)~="table" then return v end;local t={};for k,x in pairs(v) do t[k]=clone(x) end;return t end
function state.photo:getRawMetadata(key) if key=="uuid" then return "photo-1" elseif key=="isVideo" then return false end end
function state.photo:getDevelopSettings()
    local t=clone(state.raw);t.MaskGroupBasedCorrections=baseGet().MaskGroupBasedCorrections
    for _,m in ipairs(t.MaskGroupBasedCorrections) do
        local points=state.values[m.CorrectionID] and state.values[m.CorrectionID].local_PointColors
        if points and #points>0 then m.LocalPointColors=clone(points) end
    end
    return t
end
function state.photo:applyDevelopSettings(values)
    state.writes=state.writes+1
    if state.writeNoop then return end
    for k,v in pairs(values) do state.raw[k]=clone(v) end
end
local catalog=import('LrApplication').activeCatalog()
function catalog:withWriteAccessDo(name,fn) if state.lockTimeout then return 'aborted' end;return fn() end
state.points={};state.pointIndex=nil
state.values.A.local_PointColors={};state.values.B.local_PointColors={}
for _,v in pairs(state.values) do
    v.local_Maincurve={0,0,1,1};v.local_Redcurve={0,0,1,1};v.local_Greencurve={0,0,1,1};v.local_Bluecurve={0,0,1,1}
end
local oldGet=controller.getValue
function controller.getValue(key)
    if key=='Temperature' or key=='Tint' then return state.raw[key] end
    if key=='PointColors' then return clone(state.points) end
    return clone(oldGet(key))
end
function controller.setAutoWhiteBalance()
    state.writes=state.writes+1
    if state.writeNoop then return end
    state.raw.WhiteBalance='Auto';state.raw.Temperature=6100;state.raw.Tint=7
end
local function points(localMode) return localMode and state.values[state.selected].local_PointColors or state.points end
function controller.getSelectedPointColorSwatchIndex(localMode) return state.pointIndex end
function controller.selectPointColorSwatch(index,localMode) if not state.pointSelectNoop then state.pointIndex=index end end
function controller.addPointColorSwatch(swatch,localMode)
    if state.pointFail then return false,'injected failure' end
    local list=points(localMode)
    for i,v in ipairs(list) do if v.SrcHue==swatch.SrcHue and v.SrcSat==swatch.SrcSat and v.SrcLum==swatch.SrcLum then state.pointIndex=i;return true end end
    if state.writeNoop then return true end
    local s=clone(swatch)
    for _,key in ipairs({'HueShift','SatScale','LumScale'}) do if s[key]==nil then s[key]=0 end end
    if s.RangeAmount==nil then s.RangeAmount=.5 end
    for _,key in ipairs({'HueRange','SatRange','LumRange'}) do if not s[key] then s[key]={LowerNone=0,LowerFull=.25,UpperFull=.75,UpperNone=1} end end
    list[#list+1]=s;state.pointIndex=#list;state.writes=state.writes+1
    return true
end
function controller.updateSelectedPointColorSwatch(swatch,localMode)
    if state.writeNoop then return true end
    points(localMode)[state.pointIndex]=clone(swatch);state.writes=state.writes+1;return true
end
function controller.deletePointColorSwatch(all,index,localMode)
    assert(all==false)
    if not state.writeNoop then table.remove(points(localMode),index);state.writes=state.writes+1 end
    return true
end

function controller.selectTool(name) state.panel=name end
