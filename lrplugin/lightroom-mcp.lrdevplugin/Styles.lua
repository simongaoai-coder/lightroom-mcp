-- Lightroom persists native presets; plugin preferences retain their selection
-- manifest and compatibility guards across sessions. Never export raw settings.
local App=import 'LrApplication'
local Prefs=import 'LrPrefs'
local Library=require 'Library'
local Develop=require 'Develop'
local Styles={VERSION='2.12.2'}
local fail=Library.fail
local groups={
    colorGrading={'SplitToningHighlightHue','SplitToningHighlightSaturation','SplitToningShadowHue',
        'SplitToningShadowSaturation','SplitToningBalance','ColorGradeBlending','ColorGradeGlobalHue',
        'ColorGradeGlobalSat','ColorGradeGlobalLum','ColorGradeMidtoneHue','ColorGradeMidtoneSat',
        'ColorGradeMidtoneLum','ColorGradeHighlightLum','ColorGradeShadowLum'},
    grain={'GrainAmount','GrainSize','GrainFrequency'},
}
local function equal(a,b)
    if type(a)~=type(b) then return false end
    if type(a)=='number' then return a==a and b==b and math.abs(a-b)<.0001 end
    if type(a)~='table' then return a==b end
    for k,v in pairs(a) do if not equal(v,b[k]) then return false end end
    for k in pairs(b) do if a[k]==nil then return false end end
    return true
end
local function owned()
    if type(App.getDevelopPresetsForPlugin)~='function' then fail('unsupported_api','Plugin preset enumeration unavailable') end
    local result=App.getDevelopPresetsForPlugin(_PLUGIN)
    if type(result)~='table' then fail('presets_unavailable','Plugin presets unavailable') end
    return result
end
Styles.equal=equal
function Styles.manifest(id)
    return (Prefs.prefsForPlugin().savedStyles or {})[id]
end
function Styles.check(preset,photos)
    local m=Styles.manifest(preset:getUuid())
    if not m then fail('style_manifest_missing','Plugin preset has no verified selection manifest; recreate the style before applying') end
    if not m.verified then fail('style_unverified','Saved style creation was not verified') end
    local settings=preset:getSetting()
    if type(settings)~='table' then fail('style_changed','Native preset settings unavailable') end
    if not equal(m.nativeSettings,settings) then fail('style_changed','Native preset differs from saved manifest') end
    for _,p in ipairs(photos) do
        local raw=p:getDevelopSettings()
        if raw.ProcessVersion~=m.processVersion then fail('incompatible_style','Style requires matching source process version') end
        for key,value in pairs(m.settings) do
            if key~='WhiteBalance' and type(raw[key])~=type(value) then fail('incompatible_style','Unavailable setting or incompatible units: '..key) end
        end
        if m.settings.Temperature~=nil and raw.IncrementalTemperature~=nil or
           m.settings.Tint~=nil and raw.IncrementalTint~=nil then fail('incompatible_style','RAW white balance cannot be applied to rendered units') end
    end
    return m
end
function Styles.matches(manifest,raw)
    for key,value in pairs(manifest.settings) do if not equal(value,raw[key]) then return false end end
    return true
end
-- Verify known unselected invariants independently of the selected-field match.
-- As Shot/Auto numeric WB values can be unresolved/recomputed by Lightroom;
-- preserve their mode while requiring exact numeric preservation for Custom WB.
function Styles.protectedChanges(manifest,before,after)
    local changed={}
    for key in string.gmatch('ProcessVersion WhiteBalance Temperature Tint IncrementalTemperature IncrementalTint Exposure Exposure2012 CropTop CropBottom CropLeft CropRight CropAngle HasCrop orientation ConvertToGrayscale CameraProfile CameraProfileDigest Look','%S+') do
        local derivedWB=(key=='Temperature' or key=='Tint' or key=='IncrementalTemperature' or key=='IncrementalTint') and
            (before.WhiteBalance=='As Shot' or before.WhiteBalance=='Auto') and manifest.settings.WhiteBalance==nil
        if manifest.settings[key]==nil and not derivedWB and not equal(before[key],after[key]) then changed[#changed+1]=key end
    end
    return changed
end

function Styles.save(req)
    if type(req.name)~='string' or not req.name:match('%S') or req.name:find('[%z\1-\31\127]') then fail('invalid_arguments','Invalid style name') end
    if type(App.addDevelopPresetForPlugin)~='function' then fail('unsupported_api','Plugin preset creation unavailable') end
    local c=Library.context(req)
    local sourceReq={expectedPhotoId=req.expectedPhotoId,expectedCatalogPath=req.expectedCatalogPath}
    if req.sourcePhotoId then sourceReq.photoIds={req.sourcePhotoId} end
    local source=Library.targets(c,sourceReq)[1]
    local names,seen={},{}
    local function add(name)
        if type(name)~='string' then fail('invalid_arguments','Parameter names must be strings') end
        local key=name:lower();if not seen[key] then names[#names+1]=name;seen[key]=true end
    end
    if req.parameters~=nil then
        if type(req.parameters)~='table' or #req.parameters<1 or #req.parameters>150 then fail('invalid_arguments','Invalid parameters') end
        for _,name in ipairs(req.parameters) do
            if type(name)~='string' or seen[name:lower()] then fail('invalid_arguments','Duplicate or invalid parameter') end
            add(name)
        end
    end
    local curve=false;local seenGroups={}
    if req.groups~=nil then
        if type(req.groups)~='table' or #req.groups<1 then fail('invalid_arguments','Invalid groups') end
        for _,group in ipairs(req.groups) do
            if seenGroups[group] then fail('invalid_arguments','Duplicate group') end;seenGroups[group]=true
            if group=='pointCurve' then curve=true
            elseif groups[group] then for _,name in ipairs(groups[group]) do add(name) end
            else fail('invalid_arguments','Unknown style group') end
        end
    end
    if #names==0 and not curve then fail('invalid_arguments','Select parameters or groups') end
    local sourceRaw=source:getDevelopSettings()
    local settings,version=Develop.captureStyle(source,names,curve)
    for _,p in ipairs(owned()) do if p:getName():lower()==req.name:lower() then fail('style_exists','Choose a new name; existing styles are not overwritten') end end
    Library.check(c)
    if c.catalog:findPhotoByUuid(source:getRawMetadata('uuid'))~=source then fail('photo_not_found','Source disappeared') end
    local preset=App.addDevelopPresetForPlugin(_PLUGIN,req.name,settings)
    if not preset then fail('style_save_unverified','Native preset was not returned; inspect before retrying') end
    local id=preset:getUuid()
    if type(id)~='string' or id=='' then fail('style_save_unverified','Preset ID unavailable; inspect before retrying') end
    local preferences=Prefs.prefsForPlugin()
    local saved=Library.clone(preferences.savedStyles or {})
    local manifest={settings=Library.clone(settings),processVersion=version,name=req.name,verified=false}
    saved[id]=manifest;preferences.savedStyles=saved
    local found
    for _,p in ipairs(owned()) do if p:getUuid()==id and p:getName()==req.name then found=p end end
    local native=found and found:getSetting()
    local unexpected=false
    if type(native)=='table' then
        for key,value in pairs(native) do
            if settings[key]==nil and sourceRaw[key]~=nil and not (key=='ProcessVersion' and value==version) then unexpected=true end
        end
    end
    if type(native)~='table' or unexpected or not Styles.matches(manifest,native) then
        fail('style_save_unverified','Preset exists but selected settings could not be verified; do not retry blindly',{presetId=id,outcomeUnknown=true})
    end
    Library.check(c)
    manifest.nativeSettings=Library.clone(native);manifest.verified=true;saved[id]=manifest;preferences.savedStyles=Library.clone(saved)
    return {success=true,data={presetId=id,name=req.name,pluginOwned=true,settings=settings,
        sourcePhotoId=source:getRawMetadata('uuid'),processVersion=version,
        verification='native_preset_settings_readback',persistent=true}}
end
return Styles
