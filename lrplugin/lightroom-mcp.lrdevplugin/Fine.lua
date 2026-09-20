-- Typed fine controls. Numeric sliders remain in Develop/Masking.
local Application=import "LrApplication"
local Controller=import "LrDevelopController"
local View=import "LrApplicationView"
local Tasks=import "LrTasks"
local Date=import "LrDate"
local Masking=require "Masking"
local Fine={VERSION="2.2.3",commands={auto_white_balance=true,get_curve=true,set_curve=true,
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
local function handle(req)
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
        "addPointColorSwatch","deletePointColorSwatch","selectPointColorSwatch","updateSelectedPointColorSwatch","getSelectedPointColorSwatchIndex"}) do
        result[name]=type(Controller[name])=="function"
    end
    return result
end
function Fine.handle(req)
    local ok,result=Tasks.pcall(function() return handle(req) end)
    if ok then return result end
    return type(result)=="table" and result or {success=false,code="sdk_error",error=tostring(result)}
end
return Fine
