-- Typed fine controls. Numeric sliders remain in Develop/Masking.
local Application=import "LrApplication"
local Controller=import "LrDevelopController"
local View=import "LrApplicationView"
local Tasks=import "LrTasks"
local Date=import "LrDate"
local Masking=require "Masking"
local Fine={VERSION="2.8.0",commands={auto_white_balance=true,get_curve=true,set_curve=true,
    list_point_colors=true,add_point_color=true,update_point_color=true,delete_point_color=true}}
local function fail(code,message,data) error({success=false,code=code,error=message,data=data},0) end
local function api(name)
    if type(Controller[name])~="function" then fail("unsupported_api","Lightroom does not provide " .. name) end
end
local function finite(v) return type(v)=="number" and v==v and math.abs(v)<math.huge end
local function clone(v)
    if type(v)~="table" then return v end
    local out={};for k,x in pairs(v) do out[k]=clone(x) end;return out
end
local function equal(a,b)
    if type(a)~=type(b) then return false end
    if type(a)=="number" then return finite(a) and finite(b) and math.abs(a-b)<0.00001 end
    if type(a)~="table" then return a==b end
    for k,v in pairs(a) do if not equal(v,b[k]) then return false end end
    for k in pairs(b) do if a[k]==nil then return false end end
    return true
end
local function subset(actual,wanted)
    if type(wanted)~="table" then return equal(actual,wanted) end
    if type(actual)~="table" then return false end
    for k,v in pairs(wanted) do if not subset(actual[k],v) then return false end end
    return true
end
local function check(photo,req)
    if Application.activeCatalog():getTargetPhoto()~=photo then fail("photo_changed","Selected photo changed") end
    if req.expectedPhotoId and photo:getRawMetadata("uuid")~=req.expectedPhotoId then fail("photo_changed","Photo UUID does not match expectedPhotoId") end
    if req.maskId then Masking.checkTarget(photo,req.maskId) end
end
local function wait(photo,req,fn,seconds)
    local deadline=Date.currentTime()+(seconds or 3)
    repeat
        check(photo,req)
        local result=fn()
        if result then return result end
        Tasks.sleep(0.05)
    until Date.currentTime()>=deadline
    check(photo,req)
    return fn()
end
local function prepare(req)
    local photo=Application.activeCatalog():getTargetPhoto()
    if not photo then fail("no_photo","No photo selected") end
    if req.expectedPhotoId and photo:getRawMetadata("uuid")~=req.expectedPhotoId then fail("photo_changed","Photo UUID does not match expectedPhotoId") end
    if photo:getRawMetadata("isVideo") then fail("unsupported_photo","Fine controls require a photo") end
    if req.maskId then
        local prepared=Masking.prepareTarget(req)
        if prepared~=photo then fail("photo_changed","Photo changed while opening masking") end
    else
        if View.getCurrentModuleName()~="develop" then View.switchToModule("develop") end
        if not wait(photo,req,function() return View.getCurrentModuleName()=="develop" end,5) then fail("context_timeout","Develop is not ready") end
    end
    check(photo,req)
    return photo
end
local function raw(photo)
    local value=photo:getDevelopSettings()
    if type(value)~="table" then fail("settings_unavailable","SDK settings are unavailable") end
    return value
end
local function curvePoints(points)
    if type(points)~="table" or #points<2 or #points>32 then fail("invalid_arguments","Curve needs 2-32 [x,y] points") end
    local previous=-1
    for i,p in ipairs(points) do
        if type(p)~="table" or #p~=2 or not finite(p[1]) or not finite(p[2]) or
            p[1]<=previous or p[1]>255 or p[2]<0 or p[2]>255 then fail("invalid_arguments","Invalid curve coordinates or x ordering") end
        previous=p[1]
    end
    if points[1][1]~=0 or points[#points][1]~=255 then fail("invalid_arguments","Curve x endpoints must be 0 and 255") end
    local count=0;for _ in pairs(points) do count=count+1 end
    if count~=#points then fail("invalid_arguments","Curve must be an array") end
end
local function curveKey(photo,req)
    local channel=req.channel or "rgb"
    local suffix={rgb="",red="Red",green="Green",blue="Blue"}
    if suffix[channel]==nil then fail("invalid_arguments","Unknown curve channel") end
    if req.maskId then
        return ({rgb="local_Maincurve",red="local_Redcurve",green="local_Greencurve",blue="local_Bluecurve"})[channel]
    end
    local settings=raw(photo)
    local key="ToneCurvePV2012" .. suffix[channel]
    if channel=="rgb" and settings[key]==nil then key="ToneCurve" end
    return key
end
local function readCurve(photo,req,key)
    local native=req.maskId and Controller.getValue(key) or raw(photo)[key]
    if type(native)~="table" or #native<4 or #native%2~=0 then fail("unsupported_curve","SDK did not expose a supported point-curve array: " .. key) end
    local scale=native[#native-1]
    if native[1]~=0 or (scale~=255 and scale~=1) then fail("unsupported_curve","Unrecognized curve coordinate scale") end
    local points={}
    for i=1,#native,2 do
        if not finite(native[i]) or not finite(native[i+1]) then fail("unsupported_curve","Non-numeric curve data") end
        points[#points+1]={native[i]*255/scale,native[i+1]*255/scale}
    end
    return points,scale
end
local function curves(req,photo)
    api("getValue")
    local key=curveKey(photo,req)
    local points,scale=readCurve(photo,req,key)
    if req.command=="set_curve" then
        local values={}
        for _,p in ipairs(req.points) do values[#values+1]=p[1]*scale/255;values[#values+1]=p[2]*scale/255 end
        check(photo,req)
        if req.maskId then
            api("setValue")
            Controller.setValue(key,values)
        else
            if type(photo.applyDevelopSettings)~="function" then fail("unsupported_api","applyDevelopSettings is unavailable") end
            local entered=false
            Application.activeCatalog():withWriteAccessDo("MCP Point Curve",function()
                check(photo,req);entered=true
                photo:applyDevelopSettings({[key]=values},"MCP Point Curve")
            end,{timeout=5})
            if not entered then fail("write_timeout","Catalog write access was not acquired") end
        end
        if not wait(photo,req,function()
            points=readCurve(photo,req,key)
            return equal(points,req.points)
        end) then fail("readback_failed","Curve values were not retained",{points=points,maskId=req.maskId}) end
    end
    return {success=true,data={photoId=photo:getRawMetadata("uuid"),maskId=req.maskId,channel=req.channel or "rgb",points=points,nativeScale=scale}}
end
local limits={SrcHue={0,6},SrcSat={0,1},SrcLum={0,1},HueShift={-1,1},SatScale={-1,1},LumScale={-1,1},RangeAmount={0,1}}
local spans={HueRange=true,SatRange=true,LumRange=true}
local spanKeys={LowerNone=true,LowerFull=true,UpperFull=true,UpperNone=true}
local function validateSwatch(value,adding)
    if type(value)~="table" or next(value)==nil then fail("invalid_arguments","Swatch/changes must be non-empty") end
    for key,v in pairs(value) do
        if limits[key] then
            if not finite(v) or v<limits[key][1] or v>limits[key][2] then fail("invalid_arguments","Invalid point-color value: " .. key) end
        elseif spans[key] then
            if type(v)~="table" then fail("invalid_arguments","Range must be an object") end
            for k in pairs(v) do if not spanKeys[k] then fail("invalid_arguments","Unknown range field") end end
            for k in pairs(spanKeys) do if not finite(v[k]) or v[k]<0 or v[k]>1 then fail("invalid_arguments","Range requires four values from 0 to 1") end end
        else fail("invalid_arguments","Unknown swatch field: " .. tostring(key)) end
    end
    if adding then for _,k in ipairs({"SrcHue","SrcSat","SrcLum"}) do if value[k]==nil then fail("invalid_arguments","Missing " .. k) end end end
end
local function swatches(req,allowUnavailable)
    local value=Controller.getValue(req.maskId and "local_PointColors" or "PointColors")
    if value==nil and allowUnavailable then return nil end
    if type(value)~="table" then fail("unsupported_parameter","Point colors are unavailable on this photo/process version") end
    local count=0
    for k,v in pairs(value) do
        if type(k)~="number" or k<1 or k~=math.floor(k) or type(v)~="table" then fail("unsupported_point_color_data","Unknown point-color list layout") end
        count=count+1
    end
    if count~=#value then fail("unsupported_point_color_data","Sparse point-color list") end
    return clone(value)
end
local function selected(req)
    local index=Controller.getSelectedPointColorSwatchIndex(req.maskId~=nil)
    return type(index)=="number" and index>=1 and index==math.floor(index) and index or nil
end
local function localPointState(photo,req)
    local settings=raw(photo)
    if type(settings.MaskGroupBasedCorrections)~="table" then return nil,false end
    for _,correction in pairs(settings.MaskGroupBasedCorrections) do
        if correction.CorrectionID==req.maskId then return correction.LocalPointColors,true end
    end
    return nil,false
end
local function pointColors(req,photo)
    api("getValue");api("getSelectedPointColorSwatchIndex")
    local localMode=req.maskId~=nil
    api("selectTool")
    check(photo,req)
    Controller.selectTool(localMode and "local_point_color" or "point_color")
    check(photo,req)
    local before=swatches(req,true)
    local beforeKnown=before~=nil
    local data={photoId=photo:getRawMetadata("uuid"),maskId=req.maskId}
    local cmd=req.command
    local verifiedList
    if cmd=="list_point_colors" then
        data.swatches=before or {};data.selectedIndex=selected(req)
        data.readState=beforeKnown and "available" or "unavailable_or_uninitialized"
        check(photo,req)
        return {success=true,data=data}
    end
    if cmd=="add_point_color" then
        before=before or {}
        api("addPointColorSwatch")
        check(photo,req)
        local ok,message=Controller.addPointColorSwatch(clone(req.swatch),localMode)
        if ok==false and message then fail("point_color_failed",tostring(message)) end
        local actual,index
        if not wait(photo,req,function()
            local list=swatches(req,true)
            if not list then return false end
            index=selected(req);actual=index and list[index]
            return actual and subset(actual,{SrcHue=req.swatch.SrcHue,SrcSat=req.swatch.SrcSat,SrcLum=req.swatch.SrcLum})
        end) then fail("readback_failed","Added/selected swatch could not be identified; inspect before retrying") end
        local after=swatches(req)
        data.status=not beforeKnown and "added_or_selected" or (#after>#before and "created" or "existing_selected")
        data.index=index;data.swatch=actual
        if data.status=="created" and not subset(actual,req.swatch) then fail("readback_failed","New swatch does not match requested fields",data) end
        if data.status=="added_or_selected" then
            data.requestedValuesMatch=subset(actual,req.swatch)
            data.note="Previous point-color list was unavailable/uninitialized; this identifies the resulting swatch without assuming it was newly created."
        end
        if data.status=="existing_selected" then data.note="Lightroom selected an existing swatch. Requested changes were not assumed applied; use update_point_color." end
    elseif cmd=="update_point_color" or cmd=="delete_point_color" then
        if not beforeKnown then fail("unsupported_parameter","Cannot safely modify a swatch while its list is unavailable") end
        local index=req.index
        if not finite(index) or index<1 or index~=math.floor(index) then fail("invalid_arguments","index must be a positive integer") end
        if type(req.expectedSwatch)~="table" then fail("invalid_arguments","expectedSwatch is required") end
        if not before[index] then fail("swatch_not_found","No swatch at this index") end
        if not equal(before[index],req.expectedSwatch) then fail("swatch_changed","Swatch changed or indices shifted; list point colors again") end
        local method=cmd=="update_point_color" and "updateSelectedPointColorSwatch" or "deletePointColorSwatch"
        api(method);api("selectPointColorSwatch")
        check(photo,req)
        Controller.selectPointColorSwatch(index,localMode)
        if not wait(photo,req,function() return selected(req)==index end) then fail("selection_failed","Swatch was not selected") end
        if not equal(swatches(req),before) then fail("swatch_changed","Point-color list changed before writing") end
        check(photo,req)
        local wanted=clone(before)
        -- The local getter returns nil after deleting the final swatch. Only
        -- accept catalog-empty readback if that exact catalog field was present
        -- with the expected count before deletion on this explicit mask.
        local allowCatalogEmpty=false
        if cmd=="delete_point_color" and localMode and #before==1 then
            local stored,found=localPointState(photo,req)
            allowCatalogEmpty=found and type(stored)=="table" and #stored==#before
        end
        check(photo,req)
        local ok,message
        if cmd=="update_point_color" then
            for k,v in pairs(req.changes) do wanted[index][k]=clone(v) end
            ok,message=Controller.updateSelectedPointColorSwatch(wanted[index],localMode)
        else
            table.remove(wanted,index)
            ok=Controller.deletePointColorSwatch(false,index,localMode)
        end
        if ok==false then fail("point_color_failed",tostring(message or "Lightroom rejected the operation")) end
        local actual
        if not wait(photo,req,function()
            actual=swatches(req,true)
            if actual==nil and allowCatalogEmpty then
                local stored,found=localPointState(photo,req)
                if found and (stored==nil or (type(stored)=="table" and next(stored)==nil)) then
                    actual={};data.verification="sdk_and_catalog_empty";data.readState="catalog_empty"
                end
            end
            return actual~=nil and equal(actual,wanted)
        end) then
            fail("readback_failed","Point-color result did not match requested change",{swatches=actual,index=index,maskId=req.maskId})
        end
        verifiedList=actual
        data.verification=data.verification or "readback"
        data.index=index;data.status=cmd=="update_point_color" and "updated" or "deleted"
    end
    data.swatches=verifiedList or swatches(req);data.selectedIndex=selected(req)
    check(photo,req)
    return {success=true,data=data}
end
-- Appearance controls are kept in this existing module so deployment does not
-- require a full Lightroom restart merely to discover a new Lua file.
local appearanceCommands={get_appearance=true,set_treatment=true,set_white_balance=true,list_profiles=true,set_profile=true}
for name in pairs(appearanceCommands) do Fine.commands[name]=true end
local wbModes={['As Shot']=true,Auto=true,Daylight=true,Cloudy=true,Shade=true,Tungsten=true,Fluorescent=true,Flash=true}
local function profileSettings(settings)
    if type(settings.CameraProfile)~="string" and type(settings.Look)~="table" then return nil end
    local out={}
    for _,key in ipairs({'CameraProfile','CameraProfileDigest','Look','ConvertToGrayscale'}) do
        if settings[key]~=nil then out[key]=clone(settings[key]) end
    end
    if out.ConvertToGrayscale==nil and type(out.Look)=='table' and type(out.Look.Parameters)=='table' and type(out.Look.Parameters.ConvertToGrayscale)=='boolean' then
        out.ConvertToGrayscale=out.Look.Parameters.ConvertToGrayscale
    end
    return out
end
local function appearanceState(photo)
    local s=raw(photo)
    local data={photoId=photo:getRawMetadata('uuid'),whiteBalance=s.WhiteBalance,
        profile=profileSettings(s),fileFormat=photo:getRawMetadata('fileFormat'),
        storedTemperature=s.Temperature or s.IncrementalTemperature,storedTint=s.Tint or s.IncrementalTint,
        whiteBalanceValuesSource='catalog_stored',
        temperatureUnits=(photo:getRawMetadata('fileFormat')=='RAW' or photo:getRawMetadata('fileFormat')=='DNG') and 'kelvin' or 'relative'}
    if s.WhiteBalance~='Auto' and s.WhiteBalance~='As Shot' then
        data.temperature=data.storedTemperature;data.tint=data.storedTint
    else data.whiteBalanceValuesSource='catalog_stored_not_resolved' end
    if type(s.ConvertToGrayscale)=='boolean' then data.treatment=s.ConvertToGrayscale and 'grayscale' or 'color' end
    return data
end
local function rawClass(photo)
    local format=photo:getRawMetadata('fileFormat')
    return format=='RAW' or format=='DNG'
end
local function appearance(req)
    local catalog=Application.activeCatalog();local photo=catalog:getTargetPhoto();local path=catalog:getPath()
    if not photo then fail('no_photo','No photo selected') end
    local function guard()
        if Application.activeCatalog()~=catalog or catalog:getPath()~=path or (req.expectedCatalogPath and req.expectedCatalogPath~=path) then fail('catalog_changed','Catalog changed') end
        check(photo,req)
    end
    guard()
    if photo:getRawMetadata('isVideo') then fail('unsupported_photo','Appearance controls require a photo') end
    local function write(values)
        if type(photo.applyDevelopSettings)~='function' then fail('unsupported_api','applyDevelopSettings unavailable') end
        local entered=false
        catalog:withWriteAccessDo('MCP Appearance',function()guard();entered=true;photo:applyDevelopSettings(values)end,{timeout=5})
        if not entered then fail('write_timeout','Catalog write access was not acquired') end
    end
    local function verify(predicate)
        local deadline=Date.currentTime()+5
        repeat guard();if predicate(raw(photo)) then return end;Tasks.sleep(.05) until Date.currentTime()>=deadline
        fail('readback_failed','Requested appearance was not retained; inspect before retrying',{appearance=appearanceState(photo),outcomeUnknown=true})
    end
    local function sourcePhoto(id)
        if type(id)~='string' or not id:match('%S') then fail('invalid_arguments','Invalid source photo ID') end
        local source=catalog:findPhotoByUuid(id)
        if not source then fail('photo_not_found','Source photo does not exist in this catalog') end
        if source:getRawMetadata('isVideo') then fail('unsupported_photo','Profile source must be a photo') end
        return source
    end
    local function presetObjects()
        if type(Application.developPresetFolders)~='function' then fail('unsupported_api','Preset enumeration unavailable') end
        local out={}
        for _,folder in ipairs(Application.developPresetFolders() or {}) do
            for _,preset in ipairs(folder:getDevelopPresets() or {}) do out[#out+1]=preset end
        end
        return out
    end
    local function entry(id,label,settings)
        local p=profileSettings(settings);if not p then return nil end
        local look=type(p.Look)=='table' and p.Look or {}
        return {profileId=id,name=look.Name or p.CameraProfile or label,sourceName=label,expectedProfile=p}
    end
    local cmd=req.command
    if cmd=='get_appearance' then local d=appearanceState(photo);d.catalogPath=path;guard();return {success=true,data=d} end
    if cmd=='list_profiles' then
        local offset,limit=req.offset or 0,req.limit or 50
        if not finite(offset) or offset<0 or offset~=math.floor(offset) or not finite(limit) or limit<1 or limit>200 or limit~=math.floor(limit) then fail('invalid_arguments','Invalid pagination') end
        if req.includePresets~=nil and type(req.includePresets)~='boolean' then fail('invalid_arguments','includePresets must be boolean') end
        if req.query~=nil and type(req.query)~='string' then fail('invalid_arguments','query must be a string') end
        local ids=req.sourcePhotoIds or {photo:getRawMetadata('uuid')};local rows,errors,seen={},{},{}
        if type(ids)~='table' or #ids<1 or #ids>50 then fail('invalid_arguments','Provide 1-50 source photos') end
        for _,id in ipairs(ids) do
            if seen[id] then fail('invalid_arguments','Duplicate source photo') end;seen[id]=true
            local source=sourcePhoto(id);local e=entry('photo:'..id,source:getFormattedMetadata('fileName'),raw(source))
            if e then rows[#rows+1]=e end
        end
        if req.includePresets~=false then
            for _,preset in ipairs(presetObjects()) do
                guard()
                local id=preset:getUuid()
                local ok,value=Tasks.pcall(function()return entry('preset:'..id,preset:getName(),preset:getSetting())end)
                if ok then if value then rows[#rows+1]=value end
                else errors[#errors+1]={presetId=id,error=tostring(value)} end
            end
        end
        local filtered={};local query=(req.query or ''):lower()
        for _,e in ipairs(rows) do if (e.name..' '..e.sourceName):lower():find(query,1,true) then filtered[#filtered+1]=e end end
        table.sort(filtered,function(a,b)if a.name==b.name then return a.profileId<b.profileId end;return a.name<b.name end)
        local page={};for i=offset+1,math.min(offset+limit,#filtered) do page[#page+1]=filtered[i] end
        guard();return {success=true,data={profiles=page,total=#filtered,offset=offset,hasMore=offset+limit<#filtered,
            catalogPath=path,coverage='observed_photos_and_sdk_presets',completeInstalledList=false,presetErrors=errors}}
    end
    local before=raw(photo)
    if cmd=='set_treatment' then
        if req.treatment~='color' and req.treatment~='grayscale' then fail('invalid_arguments','Invalid treatment') end
        if type(photo.quickDevelopSetTreatment)~='function' then fail('unsupported_api','quickDevelopSetTreatment unavailable') end
        guard();photo:quickDevelopSetTreatment(req.treatment)
        verify(function(s)return s.ConvertToGrayscale==(req.treatment=='grayscale')end)
    elseif cmd=='set_white_balance' then
        if not wbModes[req.mode] then fail('invalid_arguments','Invalid white-balance mode') end
        if req.mode~='As Shot' and req.mode~='Auto' and not rawClass(photo) then fail('unsupported_mode','Lighting white-balance presets require RAW/DNG; rendered files use As Shot or Auto; use numeric adjustments for Custom') end
        if req.mode=='As Shot' then
            write({WhiteBalance=req.mode})
        else
            if type(photo.quickDevelopSetWhiteBalance)~='function' then fail('unsupported_api','quickDevelopSetWhiteBalance unavailable') end
            guard();photo:quickDevelopSetWhiteBalance(req.mode)
        end
        verify(function(s)return s.WhiteBalance==req.mode end)
    elseif cmd=='set_profile' then
        if type(req.profileId)~='string' or type(req.expectedProfile)~='table' or next(req.expectedProfile)==nil then fail('invalid_arguments','profileId and expectedProfile are required') end
        local kind,id=req.profileId:match('^(%a+):(.+)$');local source,settings
        if kind=='photo' then source=sourcePhoto(id);settings=profileSettings(raw(source))
        elseif kind=='preset' then
            for _,p in ipairs(presetObjects()) do if p:getUuid()==id then settings=profileSettings(p:getSetting());break end end
        else fail('invalid_arguments','Use an observed photo:/preset: profile ID') end
        if not settings then fail('profile_not_found','No profile configuration found at this source') end
        if not equal(settings,req.expectedProfile) then fail('profile_changed','Source profile changed; list profiles again') end
        if source then
            if rawClass(source)~=rawClass(photo) then fail('incompatible_profile','Source and target must both be RAW/DNG or both rendered') end
            if rawClass(photo) then
                local a,b=source:getFormattedMetadata('cameraModel'),photo:getFormattedMetadata('cameraModel')
                if not a or a=='' or a~=b or source:getFormattedMetadata('cameraMake')~=photo:getFormattedMetadata('cameraMake') then fail('incompatible_profile','RAW profile reuse requires the same known camera model') end
            end
        elseif settings.CameraProfile and settings.CameraProfile~='Adobe Standard' and settings.CameraProfile~=before.CameraProfile then
            fail('incompatible_profile','Camera-specific preset profile is not validated for this photo; reuse it from a matching-camera photo')
        end
        if not rawClass(photo) and ((settings.CameraProfile and settings.CameraProfile~='Embedded' and settings.CameraProfile~='Color') or (settings.Look and settings.Look.SupportsOutputReferred==false)) then fail('incompatible_profile','RAW-only profile cannot be applied to a rendered photo') end
        -- An absent Look must clear a previous creative profile, not leave it active.
        local patch=clone(settings);if patch.Look==nil then patch.Look={} end
        write(patch)
        verify(function(s)
            for key,value in pairs(settings) do if not subset(s[key],value) then return false end end
            if settings.Look==nil and type(s.Look)=='table' and next(s.Look)~=nil then return false end
            return true
        end)
    else fail('unknown_command','Unknown appearance command') end
    guard();local data=appearanceState(photo);data.catalogPath=path;data.verification='catalog_readback';data.changedKeys={}
    local after=raw(photo)
    for key,value in pairs(before) do if not equal(value,after[key]) then data.changedKeys[#data.changedKeys+1]=key end end
    for key in pairs(after) do if before[key]==nil then data.changedKeys[#data.changedKeys+1]=key end end
    table.sort(data.changedKeys)
    return {success=true,data=data}
end

local geometryCommands={get_geometry=true,rotate_photo=true,set_crop_aspect=true,reset_adjustments=true}
for name in pairs(geometryCommands) do Fine.commands[name]=true end
local function geometry(photo)
    local s=raw(photo);local crop={}
    for _,key in ipairs({'CropTop','CropBottom','CropLeft','CropRight','CropAngle','HasCrop','CropConstrainToWarp'}) do if s[key]~=nil then crop[key]=s[key] end end
    local dims=photo:getRawMetadata('croppedDimensions')
    return {photoId=photo:getRawMetadata('uuid'),orientation=photo:getRawMetadata('orientation'),
        dimensions=clone(photo:getRawMetadata('dimensions')),croppedDimensions=clone(dims),crop=crop,
        effectiveRatio=type(dims)=='table' and finite(dims.width) and finite(dims.height) and dims.height>0 and dims.width/dims.height or nil}
end
local function geometryHandle(req)
    local catalog=Application.activeCatalog();local photo=catalog:getTargetPhoto();local path=catalog:getPath()
    if not photo then fail('no_photo','No photo selected') end
    local function guard()
        if Application.activeCatalog()~=catalog or catalog:getPath()~=path or (req.expectedCatalogPath and path~=req.expectedCatalogPath) then fail('catalog_changed','Catalog changed') end
        check(photo,req)
    end
    guard();if photo:getRawMetadata('isVideo') then fail('unsupported_photo','Geometry controls require a photo') end
    local cmd=req.command;local before=geometry(photo)
    if cmd=='get_geometry' then guard();before.catalogPath=path;return {success=true,data=before} end
    local function poll(fn)
        local deadline=Date.currentTime()+5
        repeat guard();if fn() then return true end;Tasks.sleep(.05) until Date.currentTime()>=deadline
        guard();return fn()
    end
    local verification='observed';local extra={}
    if cmd=='rotate_photo' then
        if req.direction~='left' and req.direction~='right' then fail('invalid_arguments','Invalid rotation direction') end
        local o=before.orientation
        if not ({AB=true,BC=true,CD=true,DA=true,BA=true,AD=true,DC=true,CB=true})[o] then fail('unsupported_orientation','Unrecognized orientation; no rotation attempted') end
        local map=req.direction=='right' and {A='B',B='C',C='D',D='A'} or {A='D',B='A',C='B',D='C'}
        local wanted=map[o:sub(1,1)]..map[o:sub(2,2)]
        local method=req.direction=='right' and 'rotateRight' or 'rotateLeft'
        if type(photo[method])~='function' then fail('unsupported_api',method..' unavailable') end
        guard();photo[method](photo)
        if not poll(function()return photo:getRawMetadata('orientation')==wanted end) then fail('rotation_unverified','Expected orientation not observed; do not retry blindly',{before=o,expected=wanted,actual=photo:getRawMetadata('orientation')}) end
        extra.previousOrientation=o;verification='orientation_readback'
    elseif cmd=='set_crop_aspect' then
        local custom=req.width~=nil or req.height~=nil
        if (req.preset~=nil)==custom then fail('invalid_arguments','Provide preset OR width and height') end
        local value,ratio
        if custom then
            if not finite(req.width) or not finite(req.height) or req.width<=0 or req.height<=0 or req.width>10000 or req.height>10000 then fail('invalid_arguments','Invalid ratio dimensions') end
            value={w=req.width,h=req.height};ratio=req.width/req.height
        else
            if req.preset~='original' and req.preset~='asshot' then fail('invalid_arguments','Invalid crop preset') end
            value=req.preset
            if value=='original' then
                local d=before.dimensions
                if type(d)~='table' or not finite(d.width) or not finite(d.height) or d.width<=0 or d.height<=0 then fail('dimensions_unavailable','Original pixel dimensions unavailable') end
                ratio=d.width/d.height
            end
        end
        if type(photo.quickDevelopCropAspect)~='function' then fail('unsupported_api','quickDevelopCropAspect unavailable') end
        guard();photo:quickDevelopCropAspect(value)
        if ratio then
            if not poll(function()
                local g=geometry(photo);local d=g.croppedDimensions
                if not g.effectiveRatio or not d or d.width<=0 or d.height<=0 then return false end
                return math.abs(d.width-d.height*ratio)<=2 or math.abs(d.height-d.width*ratio)<=2
            end) then fail('crop_unverified','Requested proportions were not observed',{geometry=geometry(photo)}) end
            verification='pixel_dimensions_readback';extra.requestedRatio=ratio
        else
            Tasks.sleep(.1);guard();verification='native_call_and_observation'
            extra.note='As-shot camera crop has no documented independent target ratio; inspect the result.'
        end
    elseif cmd=='reset_adjustments' then
        if (req.parameter~=nil)==(req.group~=nil) then fail('invalid_arguments','Provide one parameter OR group') end
        local parameter,method
        if req.parameter then
            if type(req.parameter)~='string' then fail('invalid_arguments','parameter must be a string') end
            for _,name in ipairs(require('Develop').capabilities().capabilities.numericParameters) do if name:lower()==req.parameter:lower() then parameter=name end end
            if not parameter then fail('unsupported_parameter','Only registered global numeric parameters can be reset') end
            method='resetToDefault';api(method);api('getValue')
        else method=({crop='resetCrop',transforms='resetTransforms',masking='resetMasking',redeye='resetRedeye'})[req.group];if not method then fail('invalid_arguments','Unknown reset group') end;api(method) end
        if View.getCurrentModuleName()~='develop' then View.switchToModule('develop') end
        if not poll(function()return View.getCurrentModuleName()=='develop'end) then fail('context_timeout','Develop unavailable') end
        guard();local previous=raw(photo)
        if parameter then
            local old=Controller.getValue(parameter);if not finite(old) then fail('unsupported_parameter','Parameter unavailable on current photo') end
            Controller.resetToDefault(parameter)
            if not poll(function()return finite(Controller.getValue(parameter))end) then fail('readback_failed','Reset parameter value unavailable') end
            extra.parameter=parameter;extra.previousValue=old;extra.value=Controller.getValue(parameter);extra.defaultValueIndependentlyVerified=false;verification='native_reset_value_observed'
        else
            if req.group=='crop' then
                -- resetCrop returned without clearing native crop bounds in 15.2.
                -- Use the same documented catalog crop fields as lr_crop.
                local entered=false
                catalog:withWriteAccessDo('MCP Reset Crop',function()
                    guard();entered=true
                    photo:applyDevelopSettings({CropTop=0,CropBottom=1,CropLeft=0,CropRight=1,CropAngle=0,HasCrop=false})
                end,{timeout=5})
                if not entered then fail('write_timeout','Catalog write access was not acquired')end
                extra.backend='catalog_crop_fields'
            else Controller[method]() end
            local function cleared()
                local s=raw(photo)
                if req.group=='crop' then return (s.CropLeft==0 and s.CropRight==1 and s.CropTop==0 and s.CropBottom==1 and (s.CropAngle or 0)==0) end
                if req.group=='transforms' then
                    for _,k in ipairs({'PerspectiveVertical','PerspectiveHorizontal','PerspectiveRotate','PerspectiveAspect','PerspectiveX','PerspectiveY','PerspectiveUpright'}) do if s[k]~=nil and s[k]~=0 then return false end end
                    return s.PerspectiveScale==nil or s.PerspectiveScale==100
                end
                local keys=req.group=='masking' and {'MaskGroupBasedCorrections'} or {'RedEyeInfo','RedEyeCorrections'}
                for _,k in ipairs(keys) do if s[k]~=nil and (type(s[k])~='table' or next(s[k])~=nil) then return false end end
                return true
            end
            if not poll(cleared) then fail('reset_unverified','Reset group did not clear; inspect before retrying') end
            extra.group=req.group;verification='group_readback'
        end
        local after=raw(photo);extra.changedKeys={}
        for k,v in pairs(previous) do if not equal(v,after[k]) then extra.changedKeys[#extra.changedKeys+1]=k end end
        for k in pairs(after) do if previous[k]==nil then extra.changedKeys[#extra.changedKeys+1]=k end end
        table.sort(extra.changedKeys)
    end
    guard();local data=geometry(photo);data.catalogPath=path;data.verification=verification
    for k,v in pairs(extra) do data[k]=v end
    return {success=true,data=data}
end

Fine.commands.get_process_version=true
Fine.commands.set_process_version=true
local processVersions={['Version 1']=true,['Version 2']=true,['Version 3']=true,['Version 4']=true,['Version 5']=true,['Version 6']=true}
local function processVersion(req)
    if req.command=='set_process_version' and not processVersions[req.version] then fail('invalid_arguments','Use SDK names Version 1 through Version 6, not raw catalog numbers')end
    if req.expectedVersion~=nil and type(req.expectedVersion)~='string'then fail('invalid_arguments','expectedVersion must be a string')end
    if req.command=='set_process_version' and (type(req.expectedPhotoId)~='string' or not req.expectedPhotoId:match('%S'))then fail('invalid_arguments','expectedPhotoId is required')end
    local catalog=Application.activeCatalog();local path=catalog:getPath();local photo=catalog:getTargetPhoto()
    if not photo then fail('no_photo','Select a photo')end
    local function guard()
        if Application.activeCatalog()~=catalog or catalog:getPath()~=path or (req.expectedCatalogPath and req.expectedCatalogPath~=path)then fail('catalog_changed','Catalog changed')end
        check(photo,req)
        if req.command=='set_process_version' then
            local selected=catalog:getTargetPhotos()
            if #selected~=1 or selected[1]~=photo then fail('multiple_selection','Select only the target photo before changing Process Version')end
        end
    end
    guard();if photo:getRawMetadata('isVideo')then fail('unsupported_photo','Process Version requires a photo')end
    api('getProcessVersion')
    if req.command=='set_process_version'then api('setProcessVersion')end
    if View.getCurrentModuleName()~='develop'then View.switchToModule('develop')end
    local function poll(fn)
        local deadline=Date.currentTime()+5
        repeat guard();if fn()then return true end;Tasks.sleep(.05)until Date.currentTime()>=deadline
        guard();return fn()
    end
    if not poll(function()return View.getCurrentModuleName()=='develop'end)then fail('context_timeout','Develop did not become ready')end
    local function read()
        guard();local version=Controller.getProcessVersion();local settings=raw(photo);guard()
        if type(version)~='string' or version=='' or settings.ProcessVersion==nil then fail('version_unavailable','SDK or catalog process version is unavailable')end
        return {photoId=photo:getRawMetadata('uuid'),catalogPath=path,version=version,rawVersion=settings.ProcessVersion,
            recognized=processVersions[version]==true,renderingVerified=false},settings
    end
    local before,settingsBefore=read()
    if req.command=='get_process_version'then return {success=true,data=before}end
    if req.expectedVersion and req.expectedVersion~=before.version then fail('process_version_changed','Process Version changed; read it again before switching',before)end
    if before.version==req.version then before.status='unchanged';before.verification='sdk_and_catalog_readback';before.changedKeys={};return {success=true,data=before}end
    guard();local accepted=Controller.setProcessVersion(req.version)
    if accepted==false then fail('version_rejected','SDK rejected requested Process Version')end
    local after,settingsAfter
    if not poll(function()
        after,settingsAfter=read()
        return after.version==req.version and after.rawVersion~=before.rawVersion
    end)then fail('process_version_unverified','SDK/catalog did not confirm the requested version; inspect before retrying',{previous=before,observed=after,outcomeUnknown=true})end
    after.previousVersion=before.version;after.previousRawVersion=before.rawVersion;after.status='changed'
    after.verification='sdk_and_catalog_readback';after.changedKeys={}
    for k,v in pairs(settingsBefore)do if not equal(v,settingsAfter[k])then after.changedKeys[#after.changedKeys+1]=k end end
    for k in pairs(settingsAfter)do if settingsBefore[k]==nil then after.changedKeys[#after.changedKeys+1]=k end end
    table.sort(after.changedKeys)
    after.note='Version conversion can change rendering and other settings. Switching back is not a lossless restoration; compare a saved baseline/snapshot.'
    return {success=true,data=after}
end

local function handle(req)
    if req.command=="get_process_version" or req.command=="set_process_version" then return processVersion(req) end
    if geometryCommands[req.command] then return geometryHandle(req) end
    if appearanceCommands[req.command] then return appearance(req) end
    if req.command=="set_curve" then curvePoints(req.points) end
    if req.command=="add_point_color" then validateSwatch(req.swatch,true) end
    if req.command=="update_point_color" then validateSwatch(req.changes,false) end
    local photo=prepare(req)
    if req.command=="auto_white_balance" then
        api("setAutoWhiteBalance");api("getValue")
        Controller.setAutoWhiteBalance()
        local settings,temperature,tint
        if not wait(photo,req,function()
            settings=raw(photo)
            temperature=Controller.getValue("Temperature");tint=Controller.getValue("Tint")
            return settings.WhiteBalance=="Auto" and finite(temperature) and finite(tint)
        end,5) then fail("readback_failed","Auto white-balance mode was not observed") end
        return {success=true,data={photoId=photo:getRawMetadata("uuid"),whiteBalance=settings.WhiteBalance,
            temperature=temperature,tint=tint}}
    elseif req.command=="get_curve" or req.command=="set_curve" then return curves(req,photo)
    else return pointColors(req,photo) end
end
function Fine.capabilities()
    local result={}
    for _,name in ipairs({"setAutoWhiteBalance","addToCurrentMask","subtractFromCurrentMask","intersectWithCurrentMask",
        "invertMask","duplicateAndInvertMask","toggleHideMask","toggleHideMaskTool","toggleInvertMaskTool",
        "addPointColorSwatch","deletePointColorSwatch","selectPointColorSwatch","updateSelectedPointColorSwatch","getSelectedPointColorSwatchIndex","getProcessVersion","setProcessVersion"}) do
        result[name]=type(Controller[name])=="function"
    end
    local photo=Application.activeCatalog():getTargetPhoto()
    result.geometry={}
    for _,name in ipairs({"rotateLeft","rotateRight","quickDevelopCropAspect"})do result.geometry[name]=photo and type(photo[name])=="function" or false end
    for _,name in ipairs({"resetToDefault","resetCrop","resetTransforms","resetMasking","resetRedeye"})do result.geometry[name]=type(Controller[name])=="function" end
    result.appearance={profileEnumeration='observed_photos_and_sdk_presets',
        getDevelopSettings=photo and type(photo.getDevelopSettings)=='function' or false,
        applyDevelopSettings=photo and type(photo.applyDevelopSettings)=='function' or false,
        quickDevelopSetTreatment=photo and type(photo.quickDevelopSetTreatment)=='function' or false,
        quickDevelopSetWhiteBalance=photo and type(photo.quickDevelopSetWhiteBalance)=='function' or false}
    return result
end
function Fine.handle(req)
    local ok,result=Tasks.pcall(function() return handle(req) end)
    if ok then return result end
    return type(result)=="table" and result or {success=false,code="sdk_error",error=tostring(result)}
end
return Fine
