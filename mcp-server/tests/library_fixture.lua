state={now=0,writes=0,selected='a',module='library',path='/test/catalog.lrcat',nextKeyword=1,nextCollection=10,async={}}
photos={};keywords={};collections={}
local function copy(v) if type(v)~='table' then return v end;local t={};for k,x in pairs(v) do t[k]=copy(x) end;return t end
for _,id in ipairs({'a','b'}) do
    local p={id=id,meta={uuid=id,path='/photos/'..id..'.ARW',rating=id=='a' and 4 or 1,pickStatus=0,colorNameForLabel='none',title='Original '..id,caption='',fileFormat='RAW',dateTimeOriginal='2026-09-18',keywords={}}}
    function p:getRawMetadata(k)
        local formatted={title=true,caption=true,label=true,creator=true,copyright=true,rightsUsageTerms=true,headline=true,
            location=true,city=true,stateProvince=true,country=true,isoCountryCode=true,cameraMake=true,cameraModel=true,lens=true,copyName=true}
        if formatted[k] then error('Unknown raw key: '..k) end
        return self.meta[k]
    end
    function p:getFormattedMetadata(k) if k=='fileName' then return self.id..'.ARW' end;return self.meta[k] end
    function p:setRawMetadata(k,v)
        state.writes=state.writes+1
        if state.failPhoto==self.id then error('injected metadata failure') end
        if not state.noop then self.meta[k]=copy(v) end
    end
    function p:addKeyword(kw)
        if state.noop then return end
        for _,k in ipairs(self.meta.keywords) do if k==kw then return end end
        self.meta.keywords[#self.meta.keywords+1]=kw
    end
    function p:removeKeyword(kw) if not state.noop then for i,k in ipairs(self.meta.keywords) do if k==kw then table.remove(self.meta.keywords,i);return end end end end
    function p:checkPhotoAvailability() return not self.offline end
    photos[id]=p
end
state.selection={photos.a}
catalog={kAllPhotos='all'}
function catalog:getPath() return state.path end
function catalog:getTargetPhoto() return photos[state.selected] end
function catalog:getTargetPhotos() return state.selection end
function catalog:findPhotoByUuid(id) return photos[id] end
function catalog:getAllPhotos() return {photos.a,photos.b} end
function catalog:setSelectedPhotos(active,selected) if not state.selectionNoop then state.selected=active.id;state.selection=selected end end
function catalog:getActiveSources() return state.sources or {'folder'} end
function catalog:setActiveSources(sources)
    state.sourceWrites=(state.sourceWrites or 0)+1
    if state.deferSources then state.pendingSources=sources else state.sources=sources end
end
function catalog:withWriteAccessDo(label,fn)
    if state.lockTimeout then return 'aborted' end
    if state.switchBeforeWrite then state.selected='b' end
    return fn()
end
function catalog:findPhotos(args)
    state.search=args.searchDesc
    local out={}
    for _,p in ipairs(self:getAllPhotos()) do
        local matches=true
        for _,f in ipairs(args.searchDesc) do
            local v=({rating=p.meta.rating,pick=p.meta.pickStatus,filename=p.id..'.ARW',fileFormat=p.meta.fileFormat,captureTime=p.meta.dateTimeOriginal})[f.criteria]
            if f.criteria=='labelColor' then v=({red=1,yellow=2,green=3,blue=4,purple=5,none='none'})[p.meta.colorNameForLabel] end
            if f.criteria=='keywords' then v='';for _,kw in ipairs(p.meta.keywords) do v=v..kw.name..' ' end end
            if f.criteria=='all' then v=p.id..' '..(p.meta.title or '') end
            if f.operation=='==' then matches=matches and v==f.value
            elseif f.operation=='>=' then matches=matches and v>=f.value
            elseif f.operation=='<=' then matches=matches and v<=f.value
            elseif f.operation=='>' then matches=matches and v>f.value
            elseif f.operation=='<' then matches=matches and v<f.value
            else matches=matches and tostring(v):lower():find(f.value:lower(),1,true)~=nil end
        end
        if matches then out[#out+1]=p end
    end
    return out
end
local function childKeywords(parent)
    local out={};for _,kw in pairs(keywords) do if kw.parent==parent then out[#out+1]=kw end end;return out
end
function catalog:getKeywords() return childKeywords(nil) end
function catalog:createKeyword(name,synonyms,include,parent,existing)
    for _,kw in pairs(keywords) do if kw.name==name and kw.parent==parent then return existing and kw or false end end
    local kw={localIdentifier=state.nextKeyword,name=name,synonyms=synonyms,include=include,parent=parent};state.nextKeyword=state.nextKeyword+1
    function kw:getName() return self.name end
    function kw:getParent() return self.parent end
    function kw:getChildren() return childKeywords(self) end
    function kw:getSynonyms() return self.synonyms end
    function kw:getAttributes() return {keywordName=self.name,includeOnExport=self.include} end
    function kw:setAttributes(a)
        if state.noop then return true end
        if a.keywordName then self.name=a.keywordName end
        if a.synonyms then self.synonyms=a.synonyms end
        if a.includeOnExport~=nil then self.include=a.includeOnExport end
        return true
    end
    keywords[kw.localIdentifier]=kw;return kw
end
local function children(parent,sets)
    local out={};for _,node in pairs(collections) do if node.parent==parent and (node.kind=='set')==sets then out[#out+1]=node end end;return out
end
function catalog:getChildCollectionSets() return children(nil,true) end
function catalog:getChildCollections() return children(nil,false) end
function catalog:getCollectionByLocalIdentifier(id) return collections[id] end
local function create(name,parent,kind,desc)
    local node={localIdentifier=state.nextCollection,name=name,parent=parent,kind=kind,desc=desc,members={}};state.nextCollection=state.nextCollection+1
    function node:type() return self.kind=='set' and 'LrCollectionSet' or 'LrCollection' end
    function node:isSmartCollection() return self.kind=='smart' end
    function node:getName() return self.name end
    function node:getParent() return self.parent end
    function node:getChildCollectionSets() return children(self,true) end
    function node:getChildCollections() return children(self,false) end
    function node:getPhotos() if self.kind=='smart' then return catalog:findPhotos({searchDesc=self.desc}) end;return self.members end
    function node:getSearchDescription() return self.desc end
    function node:setSearchDescription(desc) if not state.noop then self.desc=copy(desc) end end
    function node:setName(name) if not state.noop then self.name=name end end
    function node:addPhotos(ps)
        if state.noop then return end
        for _,p in ipairs(ps) do local seen=false;for _,m in ipairs(self.members) do if m==p then seen=true end end;if not seen then self.members[#self.members+1]=p end end
    end
    function node:removePhotos(ps)
        if state.noop then return end
        for _,p in ipairs(ps) do for i,m in ipairs(self.members) do if m==p then table.remove(self.members,i);break end end end
    end
    function node:delete() if not state.noop then collections[self.localIdentifier]=nil end end
    collections[node.localIdentifier]=node;return node
end
function catalog:createCollection(name,parent) return create(name,parent,'collection') end
function catalog:createCollectionSet(name,parent) return create(name,parent,'set') end
function catalog:createSmartCollection(name,desc,parent) return create(name,parent,'smart',desc) end
local modules={
    LrApplication={activeCatalog=function() return catalog end},
    LrTasks={pcall=pcall,sleep=function(t)
        state.now=state.now+t
        if state.pendingSources then
            state.sources=state.pendingSources;state.pendingSources=nil
            state.selected='a';state.selection={photos.a}
        end
    end,startAsyncTask=function(fn)state.async[#state.async+1]=fn end},
    LrApplicationView={getCurrentModuleName=function()return state.module end,switchToModule=function(name)state.module=name end},
    LrDate={currentTime=function()return state.now end},
}
function import(name) return assert(modules[name],name) end
function runAsync() local queue=state.async;state.async={};for _,fn in ipairs(queue) do fn() end end
