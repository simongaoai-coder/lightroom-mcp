-- Catalog operations with explicit identities and bounded photo batches.
local Application=import "LrApplication"
local View=import "LrApplicationView"
local Tasks=import "LrTasks"
local Date=import "LrDate"
local Library={VERSION="2.6.1",commands={get_selection=true,search_photos=true,select_photos=true,
    get_metadata=true,set_metadata=true,list_keywords=true,create_keyword=true,update_keyword=true,
    update_photo_keywords=true,list_collections=true,create_collection=true,update_collection=true,
    update_collection_photos=true,delete_collection=true}}
local function fail(code,message,data) error({success=false,code=code,error=message,data=data},0) end
local function api(object,name) if type(object[name])~="function" then fail("unsupported_api","Lightroom does not provide "..name) end end
local function text(v,label,empty)
    if type(v)~="string" or (not empty and not v:match("%S")) then fail("invalid_arguments",label.." must be a string" ) end
    return v
end
local function number(v,low,high)
    return type(v)=="number" and v==v and math.abs(v)<math.huge and (not low or v>=low) and (not high or v<=high)
end
local function identifier(v)
    if not number(v,1) or v~=math.floor(v) then fail("invalid_arguments","Expected a positive local ID") end
    return v
end
local function uuid(photo) return photo:getRawMetadata("uuid") end
local function clone(v)
    if type(v)~="table" then return v end
    local t={};for k,x in pairs(v) do t[k]=clone(x) end;return t
end
local function equal(a,b)
    if type(a)~=type(b) then return false end
    if type(a)=="number" then return math.abs(a-b)<0.000001 end
    if type(a)~="table" then return a==b end
    for k,v in pairs(a) do if not equal(v,b[k]) then return false end end
    for k in pairs(b) do if a[k]==nil then return false end end
    return true
end
local function context(req)
    local c={catalog=Application.activeCatalog(),expectedPhotoId=req.expectedPhotoId}
    c.path=c.catalog:getPath();c.target=c.catalog:getTargetPhoto()
    if req.expectedCatalogPath and req.expectedCatalogPath~=c.path then fail("catalog_changed","Catalog path does not match expectedCatalogPath") end
    if req.expectedPhotoId and (not c.target or uuid(c.target)~=req.expectedPhotoId) then fail("photo_changed","Active photo does not match expectedPhotoId") end
    return c
end
local function check(c,selectionMayChange)
    if Application.activeCatalog()~=c.catalog or c.catalog:getPath()~=c.path then fail("catalog_changed","Active catalog changed") end
    if not selectionMayChange and (c.expectedPhotoId or c.guardTarget) and c.catalog:getTargetPhoto()~=c.target then fail("photo_changed","Active photo changed") end
end
local function write(c,label,fn)
    local entered,result=false,nil
    c.catalog:withWriteAccessDo(label,function() check(c);entered=true;result=fn() end,{timeout=5})
    if not entered then fail("write_timeout","Catalog write access was not acquired") end
    return result
end
local function targets(c,req)
    local photos={}
    if req.photoIds~=nil then
        if req.scope~=nil then fail("invalid_arguments","Use photoIds or scope, not both") end
        if type(req.photoIds)~="table" or #req.photoIds==0 or #req.photoIds>200 then fail("invalid_arguments","photoIds must contain 1-200 UUIDs") end
        api(c.catalog,"findPhotoByUuid")
        local seen={}
        for _,id in ipairs(req.photoIds) do
            text(id,"photoId")
            if seen[id] then fail("invalid_arguments","Duplicate photo UUID") end
            seen[id]=true
            local photo=c.catalog:findPhotoByUuid(id)
            if not photo or uuid(photo)~=id then fail("photo_not_found","Photo UUID is not in this catalog: "..id) end
            photos[#photos+1]=photo
        end
    else
        if req.scope~=nil and req.scope~="current" and req.scope~="selected" then fail("invalid_arguments","Unknown scope") end
        if not c.target then fail("no_photo","No photo selected") end
        c.guardTarget=true
        photos=req.scope=="selected" and c.catalog:getTargetPhotos() or {c.target}
        if not photos or #photos==0 then fail("no_photo","No photos selected") end
        if #photos>200 then fail("batch_too_large","Select at most 200 photos or supply explicit photoIds") end
    end
    check(c)
    return photos
end
local function colorName(value)
    if value==nil or value=="gray" or value=="grey" then return "none" end
    return value
end
local function summary(photo)
    return {photoId=uuid(photo),filename=photo:getFormattedMetadata("fileName"),path=photo:getRawMetadata("path"),
        rating=photo:getRawMetadata("rating") or 0,pickStatus=photo:getRawMetadata("pickStatus") or 0,
        colorNameForLabel=colorName(photo:getRawMetadata("colorNameForLabel")),
        isVirtualCopy=photo:getRawMetadata("isVirtualCopy")==true,copyName=photo:getFormattedMetadata("copyName") or ""}
end
local function page(items,req,mapper)
    local offset,limit=req.offset or 0,req.limit or 50
    if not number(offset,0) or offset~=math.floor(offset) or not number(limit,1,200) or limit~=math.floor(limit) then fail("invalid_arguments","Invalid pagination") end
    local out={}
    for i=offset+1,math.min(offset+limit,#items) do out[#out+1]=mapper and mapper(items[i]) or items[i] end
    return {items=out,total=#items,offset=offset,hasMore=offset+#out<#items}
end
local function dated(v)
    text(v,"date")
    local y,m,d=v:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
    y,m,d=tonumber(y),tonumber(m),tonumber(d)
    local days={31,28,31,30,31,30,31,31,30,31,30,31}
    if not y or y<1 or not m or m<1 or m>12 then fail("invalid_arguments","Date must be YYYY-MM-DD") end
    if y%4==0 and (y%100~=0 or y%400==0) then days[2]=29 end
    if not d or d<1 or d>days[m] then fail("invalid_arguments","Invalid calendar date") end
end
local colors={red=1,yellow=2,green=3,blue=4,purple=5,none="none"}
local function searchDesc(filters,required)
    if filters~=nil and type(filters)~="table" then fail("invalid_arguments","filters must be an object") end
    filters=filters or {}
    local desc={combine="intersect"}
    local strings={query="all",filename="filename",keyword="keywords"}
    for k,v in pairs(filters) do
        local entry
        if strings[k] then
            text(v,k,true)
            if v~="" then entry={criteria=strings[k],operation="any",value=v} end
        elseif k=="minRating" or k=="maxRating" then
            if not number(v,0,5) or v~=math.floor(v) then fail("invalid_arguments","Rating must be 0-5") end
            entry={criteria="rating",operation=k=="minRating" and ">=" or "<=",value=v}
        elseif k=="pickStatus" then
            if v~=-1 and v~=0 and v~=1 then fail("invalid_arguments","Invalid pickStatus") end
            entry={criteria="pick",operation="==",value=v}
        elseif k=="colorLabel" then
            if not colors[v] then fail("invalid_arguments","Invalid color label") end
            entry={criteria="labelColor",operation="==",value=colors[v]}
        elseif k=="fileFormat" then
            if not ({RAW=true,DNG=true,JPG=true,TIFF=true,PSD=true})[v] then fail("invalid_arguments","Invalid format") end
            entry={criteria="fileFormat",operation="==",value=v}
        elseif k=="captureAfter" or k=="captureBefore" then
            dated(v);entry={criteria="captureTime",operation=k=="captureAfter" and ">" or "<",value=v}
        else fail("invalid_arguments","Unsupported filter: "..tostring(k)) end
        if entry then desc[#desc+1]=entry end
    end
    if filters.minRating and filters.maxRating and filters.minRating>filters.maxRating then fail("invalid_arguments","minRating exceeds maxRating") end
    if filters.captureAfter and filters.captureBefore and filters.captureAfter>=filters.captureBefore then fail("invalid_arguments","Date bounds are reversed") end
    table.sort(desc,function(a,b) return a.criteria..a.operation < b.criteria..b.operation end)
    if #desc==0 then if required then fail("invalid_arguments","Smart collections require non-empty filters") end;return nil end
    return desc
end
local function collection(c,id)
    identifier(id);api(c.catalog,"getCollectionByLocalIdentifier")
    local node=c.catalog:getCollectionByLocalIdentifier(id)
    if not node then fail("collection_not_found","Collection ID is not in this catalog") end
    local kind=node:type()
    if kind~="LrCollection" and kind~="LrCollectionSet" then fail("unsupported_collection","Unsupported collection type") end
    return node,kind=="LrCollectionSet" and "set" or (node:isSmartCollection() and "smart" or "collection")
end
local function collectionRows(c,counts)
    local rows,objects,seen={},{},{}
    local function walk(parent,path)
        for _,set in ipairs(parent:getChildCollectionSets()) do
            local id=set.localIdentifier
            if seen[id] then fail("invalid_hierarchy","Repeated collection ID") end
            seen[id]=true;objects[id]=set
            local name=set:getName();local p=set:getParent()
            rows[#rows+1]={collectionId=id,name=name,path=path..name,kind="set",parentId=p and p.localIdentifier}
            walk(set,path..name.."/")
        end
        for _,node in ipairs(parent:getChildCollections()) do
            local id=node.localIdentifier
            if seen[id] then fail("invalid_hierarchy","Repeated collection ID") end
            seen[id]=true;objects[id]=node
            local p=node:getParent()
            rows[#rows+1]={collectionId=id,name=node:getName(),path=path..node:getName(),kind=node:isSmartCollection() and "smart" or "collection",
                parentId=p and p.localIdentifier,photoCount=counts and #node:getPhotos() or nil}
        end
    end
    walk(c.catalog,"")
    table.sort(rows,function(a,b) if a.path==b.path then return a.collectionId<b.collectionId end;return a.path<b.path end)
    return rows,objects
end
local function keywordRows(c)
    local rows,objects,seen={},{},{}
    local function walk(items,path,parent)
        for _,kw in ipairs(items) do
            local id=kw.localIdentifier
            if seen[id] then fail("invalid_hierarchy","Repeated keyword ID") end
            seen[id]=true;objects[id]=kw
            local name=kw:getName()
            rows[#rows+1]={keywordId=id,name=name,path=path..name,parentId=parent,synonyms=kw:getSynonyms(),includeOnExport=kw:getAttributes().includeOnExport}
            walk(kw:getChildren(),path..name.."/",id)
        end
    end
    walk(c.catalog:getKeywords(),"",nil)
    table.sort(rows,function(a,b) if a.path==b.path then return a.keywordId<b.keywordId end;return a.path<b.path end)
    return rows,objects
end
local function filtered(rows,query)
    query=query or "";text(query,"query",true)
    local out={}
    for _,row in ipairs(rows) do if row.path:lower():find(query:lower(),1,true) then out[#out+1]=row end end
    return out
end
local stringFields={}
for k in string.gmatch("title caption creator copyright rightsUsageTerms headline location city stateProvince country isoCountryCode label","%S+") do stringFields[k]=true end
local writable={rating=true,pickStatus=true,colorNameForLabel=true,gps=true,gpsAltitude=true}
for k in pairs(stringFields) do writable[k]=true end
local readable=clone(writable)
for k in string.gmatch("fileFormat cameraMake cameraModel lens dateTimeOriginal isVirtualCopy copyName","%S+") do readable[k]=true end
-- IPTC text is exposed by getFormattedMetadata, even though its writer is
-- setRawMetadata. Raw getters only support the documented numeric/structural keys.
local formattedFields={cameraMake=true,cameraModel=true,lens=true,copyName=true}
local function readMetadata(photo,key)
    if stringFields[key] or formattedFields[key] then return photo:getFormattedMetadata(key) end
    local value=photo:getRawMetadata(key)
    if key=="colorNameForLabel" then return colorName(value) end
    return value
end
local function normalize(key,value)
    if stringFields[key] then return value or "" end
    if key=="rating" or key=="pickStatus" then return value or 0 end
    if key=="colorNameForLabel" then return colorName(value) end
    return value
end
local function metadata(photo,fields)
    fields=fields or {"rating","pickStatus","colorNameForLabel","title","caption","creator","copyright"}
    if type(fields)~="table" or #fields==0 then fail("invalid_arguments","fields must be a non-empty array") end
    local values,missing=setmetatable({}, {__jsontype="object"}),{}
    for _,key in ipairs(fields) do
        if not readable[key] then fail("invalid_arguments","Unsupported metadata field: "..tostring(key)) end
        local value=readMetadata(photo,key)
        if value==nil then missing[#missing+1]=key else values[key]=value end
    end
    local keywords={}
    for _,kw in ipairs(photo:getRawMetadata("keywords") or {}) do keywords[#keywords+1]={keywordId=kw.localIdentifier,name=kw:getName()} end
    local row=summary(photo);row.metadata=values;row.missingFields=missing;row.keywords=keywords
    return row
end
local function metadataPlan(req)
    local plan,seen={},{}
    if req.values~=nil and type(req.values)~="table" then fail("invalid_arguments","values must be an object") end
    for key,value in pairs(req.values or {}) do
        if not writable[key] then fail("invalid_arguments","Unsupported metadata field") end
        if stringFields[key] then text(value,key,true)
        elseif key=="rating" then if not number(value,0,5) or value~=math.floor(value) then fail("invalid_arguments","Invalid rating") end
        elseif key=="pickStatus" then if value~=-1 and value~=0 and value~=1 then fail("invalid_arguments","Invalid flag") end
        elseif key=="colorNameForLabel" then if not colors[value] then fail("invalid_arguments","Invalid color label") end
        elseif key=="gpsAltitude" then if not number(value) then fail("invalid_arguments","Invalid altitude") end
        elseif key=="gps" then
            if type(value)~="table" or not number(value.latitude,-90,90) or not number(value.longitude,-180,180) then fail("invalid_arguments","Invalid GPS coordinates") end
            for k in pairs(value) do if k~="latitude" and k~="longitude" then fail("invalid_arguments","Unknown GPS field") end end
        end
        seen[key]=true;plan[#plan+1]={key=key,value=value}
    end
    if req.clearFields~=nil and type(req.clearFields)~="table" then fail("invalid_arguments","clearFields must be an array") end
    for _,key in ipairs(req.clearFields or {}) do
        if not writable[key] or seen[key] then fail("invalid_arguments","Invalid, duplicate or conflicting clearFields") end
        seen[key]=true;plan[#plan+1]={key=key,value=normalize(key,nil)}
    end
    if #plan==0 then fail("invalid_arguments","Provide values or clearFields") end
    if seen.label and seen.colorNameForLabel then fail("invalid_arguments","Use label or colorNameForLabel, not both") end
    table.sort(plan,function(a,b)return a.key<b.key end)
    return plan
end
local function batch(c,photos,fn)
    local results,completed={},0
    for _,photo in ipairs(photos) do
        local row={photoId=uuid(photo),success=false};results[#results+1]=row
        local ok,err=Tasks.pcall(function() check(c);fn(photo,row);row.success=true end)
        if not ok then
            row.code=type(err)=="table" and err.code or "sdk_error";row.error=type(err)=="table" and err.error or tostring(err)
            row.outcomeUnknown=true;break
        end
        completed=completed+1
    end
    return {success=completed==#photos,code=completed<#photos and "partial_failure" or nil,
        error=completed<#photos and "Stopped after a failed photo; prior changes are not rolled back" or nil,
        applied=completed,failed=completed<#photos and 1 or 0,notAttempted=#photos-#results,data={results=results}}
end
local navigationCommands={get_navigation=true,list_folders=true,list_folder_photos=true,set_sources=true,show_view=true,navigate_photos=true,set_view_filter=true}
for name in pairs(navigationCommands)do Library.commands[name]=true end
local function sourceRows(c)
    local out={}
    for _,source in ipairs(c.catalog:getActiveSources() or {})do
        if type(source)=='string' then out[#out+1]={kind='catalog',id=source}
        else
            local kind=source:type()
            if kind=='LrFolder' then out[#out+1]={kind='folder',path=source:getPath(),name=source:getName()}
            elseif kind=='LrCollection' or kind=='LrCollectionSet' then out[#out+1]={kind=kind,collectionId=source.localIdentifier,name=source:getName()}
            else fail('unsupported_source','Unknown active source type')end
        end
    end
    table.sort(out,function(a,b)return (a.path or a.id or tostring(a.collectionId))<(b.path or b.id or tostring(b.collectionId))end)
    return out
end
local function viewFilter(c)
    api(c.catalog,'getCurrentViewFilter');local values,name=c.catalog:getCurrentViewFilter()
    if type(values)~='table'then fail('filter_unavailable','View filter is not available')end
    return clone(values),name
end
local function filterPresets()
    api(Application,'viewFilterPresets');local rows={}
    for name,id in pairs(Application.viewFilterPresets() or {})do
        if type(name)~='string' or type(id)~='string'then fail('unsupported_filter_presets','Unknown preset layout')end
        rows[#rows+1]={name=name,presetId=id}
    end
    table.sort(rows,function(a,b)return a.name<b.name end);return rows
end
local function navigationState(c,req)
    local active=c.catalog:getTargetPhoto();local photos=active and c.catalog:getTargetPhotos() or {}
    local d=page(photos,req,summary);d.photos=d.items;d.items=nil;d.activePhotoId=active and uuid(active)
    d.module=View.getCurrentModuleName();d.sources=sourceRows(c);d.viewFilter,d.filterPresetName=viewFilter(c)
    d.mainViewReadbackAvailable=false;return d
end
local function navigation(req,c)
    local cmd=req.command
    local function poll(fn)
        local deadline=Date.currentTime()+5
        repeat check(c,true);if fn()then return true end;Tasks.sleep(.05)until Date.currentTime()>=deadline
        check(c,true);return fn()
    end
    local function folder(path)
        text(path,'folderPath');api(c.catalog,'getFolderByPath')
        local f=c.catalog:getFolderByPath(path)
        if not f or f:getPath()~=path then fail('folder_not_found','Use an exact catalog folder path from list_folders')end
        return f
    end
    if cmd=='get_navigation'then local d=navigationState(c,req);d.filterPresets=filterPresets();return {success=true,data=d}
    elseif cmd=='list_folders'then
        api(c.catalog,'getFolders');local rows,seen={},{}
        local function walk(f)
            check(c);local path=f:getPath();if seen[path]then return end;seen[path]=true
            local parent=f:getParent();rows[#rows+1]={path=path,name=f:getName(),parentPath=parent and parent:getPath()}
            for _,child in ipairs(f:getChildren() or {})do walk(child)end
        end
        for _,f in ipairs(c.catalog:getFolders() or {})do walk(f)end
        table.sort(rows,function(a,b)return a.path<b.path end)
        if req.query~=nil then text(req.query,'query',true);local keep={};for _,r in ipairs(rows)do if (r.path..' '..r.name):lower():find(req.query:lower(),1,true)then keep[#keep+1]=r end end;rows=keep end
        local d=page(rows,req);d.folders=d.items;d.items=nil;return {success=true,data=d}
    elseif cmd=='list_folder_photos'then
        if req.includeChildren~=nil and type(req.includeChildren)~='boolean'then fail('invalid_arguments','includeChildren must be boolean')end
        local f=folder(req.folderPath);local photos=f:getPhotos(req.includeChildren==true);local entries={}
        for _,photo in ipairs(photos)do entries[#entries+1]={id=uuid(photo),photo=photo}end
        table.sort(entries,function(a,b)return a.id<b.id end)
        local d=page(entries,req,function(e)return summary(e.photo)end);d.photos=d.items;d.items=nil;d.folderPath=f:getPath();return {success=true,data=d}
    elseif cmd=='set_sources'then
        local count=(req.allPhotos~=nil and 1 or 0)+(req.folderPaths~=nil and 1 or 0)+(req.collectionIds~=nil and 1 or 0)
        if count~=1 then fail('invalid_arguments','Provide exactly one source category')end
        local sources={};local seen={}
        if req.allPhotos~=nil then if req.allPhotos~=true then fail('invalid_arguments','allPhotos must be true')end;sources={c.catalog.kAllPhotos}
        else
            local ids=req.folderPaths or req.collectionIds
            if type(ids)~='table' or #ids<1 or #ids>50 then fail('invalid_arguments','Provide 1-50 sources')end
            for _,id in ipairs(ids)do
                if seen[id]then fail('invalid_arguments','Duplicate source')end;seen[id]=true
                if req.folderPaths then sources[#sources+1]=folder(id)else sources[#sources+1]=collection(c,id)end
            end
        end
        check(c);if View.getCurrentModuleName()~='library'then View.switchToModule('library')end
        api(c.catalog,'setActiveSources')
        local accepted=c.catalog:setActiveSources(sources);if accepted==false then fail('source_rejected','Source switch rejected')end
        if not poll(function()
            local actual=c.catalog:getActiveSources();if #actual~=#sources then return false end
            for _,wanted in ipairs(sources)do local found=false;for _,a in ipairs(actual)do if a==wanted then found=true end end;if not found then return false end end
            return true
        end)then fail('source_unverified','Active sources did not match')end
        Tasks.sleep(.2);check(c,true);local d=navigationState(c,req);d.verification='active_sources_readback';return {success=true,data=d}
    elseif cmd=='show_view'then
        local views={grid='library',loupe='library',compare='library',survey='library',people='library',develop_loupe='develop',develop_before='develop',develop_before_after_horiz='develop',develop_before_after_vert='develop',develop_reference_horiz='develop',develop_reference_vert='develop'}
        local module=views[req.view];if not module then fail('invalid_arguments','Unknown view')end
        if module=='develop' and not c.target then fail('no_photo','Select a photo before opening Develop')end
        api(View,'showView');check(c);View.showView(req.view)
        if not poll(function()return View.getCurrentModuleName()==module end)then fail('view_unverified','Expected module was not observed')end
        local d=navigationState(c,req);d.requestedView=req.view;d.verification='module_only';return {success=true,data=d}
    elseif cmd=='navigate_photos'then
        local method=({next='nextPhoto',previous='previousPhoto',first='selectFirstPhoto',last='selectLastPhoto',all='selectAll',inverse='selectInverse'})[req.action]
        if not method then fail('invalid_arguments','Unknown navigation action')end
        local Selection=import 'LrSelection';api(Selection,method)
        local before=navigationState(c,req)
        check(c);Selection[method]();Tasks.sleep(.2);check(c,true)
        local d=navigationState(c,req);d.action=req.action;d.previousPhotoId=before.activePhotoId
        d.status=(d.activePhotoId~=before.activePhotoId or not equal(d.photos,before.photos) or d.total~=before.total) and 'selection_changed' or 'unchanged_or_boundary'
        d.verification='selection_observed';return {success=true,data=d}
    elseif cmd=='set_view_filter'then
        if (req.changes~=nil)==(req.presetId~=nil)then fail('invalid_arguments','Provide changes OR presetId')end
        local before=viewFilter(c)
        if req.expectedFilter and not equal(before,req.expectedFilter)then fail('filter_changed','View filter changed; read navigation state again')end
        local value,wantedName
        if req.presetId then
            for _,p in ipairs(filterPresets())do if p.presetId==req.presetId then wantedName=p.name end end
            if not wantedName then fail('preset_not_found','Unknown view filter preset ID')end;value=req.presetId
        else
            if type(req.changes)~='table' or next(req.changes)==nil then fail('invalid_arguments','Nonempty changes required')end
            local bools={columnBrowserActive=true,filtersActive=true,searchStringActive=true,label1=true,label2=true,label3=true,label4=true,label5=true,customLabel=true,noLabel=true}
            local enums={ratingOp={['>=']=true,['<=']=true,['==']=true},searchOp={all=true,words=true,noneof=true,beginwith=true,endswith=true},searchTarget={all=true,filename=true,copyname=true,title=true,caption=true,keyword=true,metadata=true,iptc=true,exif=true,allPluginMetadata=true}}
            value=clone(before)
            for k,v in pairs(req.changes)do
                if bools[k]then if type(v)~='boolean'then fail('invalid_arguments','Invalid boolean filter')end
                elseif enums[k]then if not enums[k][v]then fail('invalid_arguments','Invalid filter choice')end
                elseif k=='minRating'then if not number(v,0,5) or v~=math.floor(v)then fail('invalid_arguments','Invalid rating')end
                elseif k=='searchString'then text(v,k,true)
                else fail('invalid_arguments','Unsupported filter field')end
                value[k]=v
            end
        end
        check(c);api(c.catalog,'setViewFilter');local result=c.catalog:setViewFilter(value)
        if result==nil then fail('filter_rejected','SDK did not accept filter')end
        if not poll(function()
            local actual,name=viewFilter(c)
            if wantedName then return name==wantedName end
            for k,v in pairs(req.changes)do if not equal(actual[k],v)then return false end end;return true
        end)then fail('filter_unverified','View filter readback did not match')end
        local d=navigationState(c,req);d.verification='filter_readback';return {success=true,data=d}
    end
end

local function handle(req,c)
    if navigationCommands[req.command] then return navigation(req,c) end
    local cmd=req.command
    if cmd=="get_selection" then
        local data=page(c.target and c.catalog:getTargetPhotos() or {},req,summary);data.photos=data.items;data.items=nil
        data.activePhotoId=c.target and uuid(c.target);return {success=true,data=data}
    elseif cmd=="search_photos" then
        local desc=searchDesc(req.filters)
        local photos
        local inCollection
        if req.collectionId then
            local node,kind=collection(c,req.collectionId)
            if kind=="set" then fail("unsupported_collection","Collection sets are not photo sources") end
            photos=node:getPhotos();inCollection={};for _,p in ipairs(photos) do inCollection[uuid(p)]=true end
        end
        if desc then api(c.catalog,"findPhotos");photos=c.catalog:findPhotos({searchDesc=desc})
        elseif not photos then photos=c.catalog:getAllPhotos() end
        local entries={}
        for _,photo in ipairs(photos) do local id=uuid(photo);if not inCollection or inCollection[id] then entries[#entries+1]={id=id,photo=photo} end end
        table.sort(entries,function(a,b)return a.id<b.id end)
        local data=page(entries,req,function(e)return summary(e.photo)end);data.photos=data.items;data.items=nil
        return {success=true,data=data}
    elseif cmd=="select_photos" then
        if not req.photoIds then fail("invalid_arguments","photoIds required") end
        local photos=targets(c,req);local active=photos[1]
        if req.activePhotoId then
            active=nil;for _,p in ipairs(photos) do if uuid(p)==req.activePhotoId then active=p end end
            if not active then fail("invalid_arguments","activePhotoId must be in photoIds") end
        end
        check(c)
        if req.reveal~=false then
            local changed=false
            if View.getCurrentModuleName()~="library" then View.switchToModule("library");changed=true end
            local sources=c.catalog:getActiveSources()
            if #sources~=1 or sources[1]~=c.catalog.kAllPhotos then
                c.catalog:setActiveSources({c.catalog.kAllPhotos});changed=true
            end
            -- A source switch can asynchronously restore the old selection.
            -- Yield for the source transition before setting the requested UUIDs.
            if changed then Tasks.sleep(0.2);check(c,true) end
        end
        c.catalog:setSelectedPhotos(active,photos)
        Tasks.sleep(0.05)
        local wanted={};for _,p in ipairs(photos) do wanted[uuid(p)]=true end
        local deadline=Date.currentTime()+5;local verified=false
        repeat
            check(c,true)
            local actual=c.catalog:getTargetPhotos();local selected=c.catalog:getTargetPhoto()
            verified=selected and uuid(selected)==uuid(active) and #actual==#photos
            if verified then for _,p in ipairs(actual) do if not wanted[uuid(p)] then verified=false end end end
            if verified then break end;Tasks.sleep(.05)
        until Date.currentTime()>=deadline
        if not verified then fail("selection_failed","Selection was not retained; current view filters may hide target photos") end
        local data={activePhotoId=uuid(active),photos={}}
        for _,p in ipairs(photos) do data.photos[#data.photos+1]=summary(p) end
        return {success=true,data=data}
    elseif cmd=="get_metadata" then
        local data={photos={}}
        for _,p in ipairs(targets(c,req)) do data.photos[#data.photos+1]=metadata(p,req.fields) end
        return {success=true,data=data}
    elseif cmd=="set_metadata" then
        local plan=metadataPlan(req);local photos=targets(c,req)
        for _,p in ipairs(photos) do api(p,"setRawMetadata") end
        return batch(c,photos,function(photo,row)
            write(c,"MCP Metadata",function()for _,op in ipairs(plan) do photo:setRawMetadata(op.key,op.value) end end)
            row.values=setmetatable({}, {__jsontype="object"});row.clearedFields={}
            for _,op in ipairs(plan) do
                local value=readMetadata(photo,op.key)
                if value==nil then row.clearedFields[#row.clearedFields+1]=op.key else row.values[op.key]=value end
                if not equal(normalize(op.key,value),normalize(op.key,op.value)) then fail("readback_failed","Metadata not retained: "..op.key) end
            end
        end)
    elseif cmd=="list_keywords" then
        local rows=keywordRows(c);local data=page(filtered(rows,req.query),req);data.keywords=data.items;data.items=nil
        return {success=true,data=data}
    elseif cmd=="create_keyword" or cmd=="update_keyword" then
        local rows,objects=keywordRows(c);local parent,node
        if req.parentId then parent=objects[identifier(req.parentId)];if not parent then fail("keyword_not_found","Parent keyword not found") end end
        if cmd=="update_keyword" then node=objects[identifier(req.keywordId)];if not node then fail("keyword_not_found","Keyword not found") end end
        if req.name~=nil then text(req.name,"name") end
        if cmd=="create_keyword" and not req.name then fail("invalid_arguments","name required") end
        if req.synonyms~=nil then
            if type(req.synonyms)~="table" then fail("invalid_arguments","synonyms must be an array") end
            for _,v in ipairs(req.synonyms) do text(v,"synonym") end
        end
        if req.includeOnExport~=nil and type(req.includeOnExport)~="boolean" then fail("invalid_arguments","includeOnExport must be boolean") end
        local existing=false
        if cmd=="create_keyword" then
            for _,r in ipairs(rows) do if r.name==req.name and r.parentId==req.parentId then node=objects[r.keywordId];existing=true end end
            if not node then node=write(c,"MCP Create Keyword",function()return c.catalog:createKeyword(req.name,req.synonyms or {},req.includeOnExport~=false,parent,true)end) end
            if not node then fail("creation_failed","Keyword was not created") end
        else
            if req.name==nil and req.synonyms==nil and req.includeOnExport==nil then fail("invalid_arguments","No keyword changes provided") end
            local ok=write(c,"MCP Update Keyword",function()return node:setAttributes({keywordName=req.name,synonyms=req.synonyms,includeOnExport=req.includeOnExport})end)
            if ok==false then fail("keyword_exists","Keyword update conflicts with an existing sibling") end
        end
        local latest=keywordRows(c);local result
        for _,r in ipairs(latest) do if r.keywordId==node.localIdentifier then result=r end end
        if not result then fail("readback_failed","Keyword not found after write") end
        if not existing then
            if req.name and result.name~=req.name then fail("readback_failed","Keyword name did not persist") end
            if req.includeOnExport~=nil and result.includeOnExport~=req.includeOnExport then fail("readback_failed","Keyword export flag did not persist") end
            if req.synonyms then local a,b=clone(req.synonyms),clone(result.synonyms);table.sort(a);table.sort(b);if not equal(a,b) then fail("readback_failed","Keyword synonyms did not persist") end end
        end
        result.status=existing and "existing" or (cmd=="create_keyword" and "created_or_existing" or "updated")
        return {success=true,data=result}
    elseif cmd=="update_photo_keywords" then
        if req.operation~="add" and req.operation~="remove" then fail("invalid_arguments","Invalid operation") end
        local _,objects=keywordRows(c);local keywords={}
        if type(req.keywordIds)~="table" or #req.keywordIds==0 then fail("invalid_arguments","keywordIds required") end
        for _,id in ipairs(req.keywordIds) do local kw=objects[identifier(id)];if not kw then fail("keyword_not_found","Keyword ID not found") end;keywords[#keywords+1]=kw end
        local photos=targets(c,req);local method=req.operation=="add" and "addKeyword" or "removeKeyword"
        for _,p in ipairs(photos) do api(p,method) end
        return batch(c,photos,function(photo,row)
            write(c,"MCP Photo Keywords",function()for _,kw in ipairs(keywords) do photo[method](photo,kw) end end)
            local found={};row.keywordIds={}
            for _,kw in ipairs(photo:getRawMetadata("keywords") or {}) do found[kw.localIdentifier]=true;row.keywordIds[#row.keywordIds+1]=kw.localIdentifier end
            for _,kw in ipairs(keywords) do if (found[kw.localIdentifier]==true)~=(req.operation=="add") then fail("readback_failed","Keyword association was not retained") end end
        end)
    elseif cmd=="list_collections" then
        local rows=collectionRows(c,req.includeCounts);local data=page(filtered(rows,req.query),req);data.collections=data.items;data.items=nil
        return {success=true,data=data}
    elseif cmd=="create_collection" or cmd=="update_collection" then
        local node,kind,parent
        local desc=req.filters and searchDesc(req.filters,true)
        if cmd=="create_collection" then
            text(req.name,"name");kind=req.kind or "collection"
            if kind~="collection" and kind~="set" and kind~="smart" then fail("invalid_arguments","Unknown collection kind") end
            if kind=="smart" and not desc then fail("invalid_arguments","Smart collection requires filters") end
            if kind~="smart" and desc then fail("invalid_arguments","Only smart collections accept filters") end
            if req.parentId then local pk;parent,pk=collection(c,req.parentId);if pk~="set" then fail("invalid_parent","Parent must be a collection set") end end
            local rows=collectionRows(c,false)
            for _,r in ipairs(rows) do if r.name==req.name and r.parentId==req.parentId then fail("collection_exists","A sibling collection already has this name",{collectionId=r.collectionId}) end end
            node=write(c,"MCP Create Collection",function()
                if kind=="set" then return c.catalog:createCollectionSet(req.name,parent,false)
                elseif kind=="smart" then return c.catalog:createSmartCollection(req.name,desc,parent,false)
                else return c.catalog:createCollection(req.name,parent,false) end
            end)
            if not node then fail("creation_failed","Collection was not created") end
        else
            node,kind=collection(c,req.collectionId)
            if req.name==nil and not desc then fail("invalid_arguments","No collection changes provided") end
            if req.name~=nil then text(req.name,"name") end
            if desc and kind~="smart" then fail("invalid_arguments","Only smart collections accept filters") end
            write(c,"MCP Update Collection",function()if req.name then node:setName(req.name) end;if desc then node:setSearchDescription(desc) end end)
        end
        if req.name and node:getName()~=req.name then fail("readback_failed","Collection name was not retained") end
        if desc and not equal(node:getSearchDescription(),desc) then fail("readback_failed","Smart collection search description differs after write",{collectionId=node.localIdentifier,actual=node:getSearchDescription()}) end
        return {success=true,data={collectionId=node.localIdentifier,name=node:getName(),kind=kind,status=cmd=="create_collection" and "created" or "updated"}}
    elseif cmd=="update_collection_photos" then
        if req.operation~="add" and req.operation~="remove" then fail("invalid_arguments","Invalid operation") end
        local node,kind=collection(c,req.collectionId)
        if kind~="collection" then fail("unsupported_collection","Only standard collections accept manual members") end
        local photos=targets(c,req)
        write(c,"MCP Collection Members",function()if req.operation=="add" then node:addPhotos(photos) else node:removePhotos(photos) end end)
        local members={};for _,p in ipairs(node:getPhotos()) do members[uuid(p)]=true end
        for _,p in ipairs(photos) do if (members[uuid(p)]==true)~=(req.operation=="add") then fail("readback_failed","Collection membership was not retained") end end
        return {success=true,data={collectionId=req.collectionId,operation=req.operation,verifiedPhotoCount=#photos}}
    elseif cmd=="delete_collection" then
        local node,kind=collection(c,req.collectionId)
        if kind=="set" then
            if #node:getChildCollections()>0 or #node:getChildCollectionSets()>0 then fail("collection_not_empty","Collection set still has children") end
        elseif req.requireEmpty~=false and #node:getPhotos()>0 then fail("collection_not_empty","Collection still contains photos") end
        write(c,"MCP Delete Collection",function()node:delete()end)
        if c.catalog:getCollectionByLocalIdentifier(req.collectionId) then fail("deletion_failed","Collection still exists") end
        return {success=true,data={collectionId=req.collectionId,status="deleted"}}
    end
    fail("unknown_command","Unknown library command")
end
function Library.handle(req)
    local ok,result=Tasks.pcall(function()
        local c=context(req);local result=handle(req,c)
        check(c,req.command=="select_photos" or req.command=="set_sources" or req.command=="show_view" or req.command=="navigate_photos" or req.command=="set_view_filter")
        result.data=result.data or {};result.data.catalogPath=c.path
        return result
    end)
    if ok then return result end
    return type(result)=="table" and result or {success=false,code="sdk_error",error=tostring(result)}
end
function Library.capabilities()
    local c=Application.activeCatalog();local result={}
    for _,name in ipairs({"findPhotos","findPhotoByUuid","setSelectedPhotos","getKeywords","createKeyword","createCollection","createCollectionSet","createSmartCollection","getFolders","getFolderByPath","getCurrentViewFilter","setViewFilter","getActiveSources","setActiveSources"}) do result[name]=type(c[name])=="function" end
    return result
end
Library.context=context;Library.check=check;Library.targets=targets;Library.summary=summary
Library.fail=fail;Library.clone=clone
return Library
