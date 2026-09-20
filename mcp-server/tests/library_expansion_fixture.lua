local oldImport=import
local app=oldImport('LrApplication');local view=oldImport('LrApplicationView')
function app.metadataPresets()return {['Test Metadata']='meta1'}end
function view.showView(v)state.module='library'end
catalog.kTargetCollection='target'
photos.a.meta.cameraModel='Camera A';photos.b.meta.cameraModel='Camera B'
photos.a.meta.lens='Lens A';photos.b.meta.lens='Lens B'
photos.a.meta.isoSpeedRating=100;photos.b.meta.isoSpeedRating=800
photos.a.meta.hasAdjustments=true;photos.b.meta.hasAdjustments=false
photos.a.meta.gps={latitude=1,longitude=2}
function catalog:findPhotos(args)
 state.search=args.searchDesc
 local function matches(p,d)
  if d.combine then
   local any,all=false,true
   for _,child in ipairs(d)do local m=matches(p,child);any=any or m;all=all and m end
   if d.combine=='union'then return any elseif d.combine=='exclude'then return not any else return all end
  end
  local v=({camera=p.meta.cameraModel,lens=p.meta.lens,isoSpeedRating=p.meta.isoSpeedRating,hasAdjustments=p.meta.hasAdjustments,hasGPSData=p.meta.gps~=nil,
   rating=p.meta.rating,filename=p.id..'.ARW',fileFormat=p.meta.fileFormat})[d.criteria]
  if d.operation=='isTrue'then return v==true elseif d.operation=='isFalse'then return v==false end
  if d.operation=='=='then return v==d.value elseif d.operation=='>='then return v>=d.value elseif d.operation=='<='then return v<=d.value end
  return tostring(v):lower():find(tostring(d.value):lower(),1,true)~=nil
 end
 local out={};for _,p in ipairs(self:getAllPhotos())do if matches(p,args.searchDesc)then out[#out+1]=p end end;return out
end
local oldKeyword=catalog.createKeyword
function catalog:createKeyword(...)
 local kw=oldKeyword(self,...)
 function kw:setParent(p)assert(not state.inWrite,'keyword parent change runs async outside write gate');if not state.noop then self.parent=p end end
 function kw:getPhotos()
  local out={};for _,photo in pairs(photos)do for _,k in ipairs(photo.meta.keywords)do if k==self then out[#out+1]=photo;break end end end;return out
 end
 return kw
end
for _,name in ipairs({'createCollection','createCollectionSet','createSmartCollection'})do
 local original=catalog[name]
 catalog[name]=function(self,...)
  local col=original(self,...)
  function col:setParent(parent)assert(state.inWrite,'collection parent needs write gate');if not state.noop then self.parent=parent end end
  return col
 end
end
function catalog:withWriteAccessDo(label,fn)
 if state.lockTimeout then return 'aborted'end
 state.inWrite=true;local ok,r=pcall(fn);state.inWrite=false;if not ok then error(r)end;return r
end
local targetMembers={}
for _,p in pairs(photos)do
 function p:getContainedCollections()return targetMembers[self.id]and {{localIdentifier=99}}or {}end
 function p:addOrRemoveFromTargetCollection()targetMembers[self.id]=not targetMembers[self.id]end
 function p:applyMetadataPreset(id)assert(state.inWrite and id=='meta1');if self.id==state.failPhoto then error('injected preset failure')end;self.meta.title='preset title'end
end
photos.b.meta.isVirtualCopy=true;photos.b.meta.masterPhoto=photos.a;photos.b.meta.copyName='copy b'
local selection={}
function selection.removeFromCatalog()
 assert(state.module=='library' and #state.selection==1)
 local p=state.selection[1];assert(p.meta.isVirtualCopy)
 state.removeCalls=(state.removeCalls or 0)+1
 if state.removeNoop then return end
 photos[p.id]=nil;state.selected='a';state.selection={photos.a}
end
function import(name)if name=='LrSelection'then return selection end;return oldImport(name)end
