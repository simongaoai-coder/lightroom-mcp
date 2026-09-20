local oldImport=import
local function cp(v)if type(v)~='table'then return v end;local r={};for k,x in pairs(v)do r[k]=cp(x)end;return r end
state.filter={filtersActive=false,searchStringActive=false,columnBrowserActive=false,minRating=0,ratingOp='>=',searchString='',searchTarget='all',searchOp='all'}
function catalog:getCurrentViewFilter()return cp(state.filter),state.filterName end
function catalog:setViewFilter(v)
 if state.noop then return false end
 if type(v)=='string'then if v~='off'then return nil end;state.filterName='Filters Off';state.filter.filtersActive=false
 else state.filter=cp(v);state.filterName=nil end
 return true
end
local f={}
function f:getPath()return '/photos'end
function f:getName()return 'photos'end
function f:getParent()return nil end
function f:getChildren()return {}end
function f:getPhotos(children)state.includeChildren=children;return {photos.a,photos.b}end
function f:type()return 'LrFolder'end
function catalog:getFolderByPath(path)if path=='/photos'then return f end end
function catalog:getFolders()return {f}end
state.sources={'all'}
local app=oldImport('LrApplication')
function app.viewFilterPresets()return {['Filters Off']='off'}end
local view=oldImport('LrApplicationView')
function view.showView(name)if not state.noop then state.module=name:match('^develop') and 'develop' or 'library';state.view=name end end
selection={}
function selection.nextPhoto()if not state.noop then state.selected='b';state.selection={photos.b}end end
function selection.previousPhoto()if not state.noop then state.selected='a';state.selection={photos.a}end end
selection.selectFirstPhoto=selection.previousPhoto;selection.selectLastPhoto=selection.nextPhoto
function selection.selectAll()state.selection={photos.a,photos.b}end
function selection.selectInverse()state.selected='b';state.selection={photos.b}end
for _,p in pairs(photos)do
 p.meta.orientation='AB';p.meta.dimensions={width=6000,height=4000};p.meta.croppedDimensions={width=6000,height=4000}
 p.raw={CropTop=0,CropBottom=1,CropLeft=0,CropRight=1,CropAngle=0,HasCrop=false,Exposure2012=1,PerspectiveVertical=12,PerspectiveScale=110,MaskGroupBasedCorrections={{CorrectionID='mask1'}},RedEyeInfo={{id='eye1'}}}
 function p:getDevelopSettings()return cp(self.raw)end
 function p:applyDevelopSettings(values)if not state.noop then for k,v in pairs(values)do self.raw[k]=cp(v)end end end
 local function rotate(photo,right)
  if state.noop then return end
  local map=right and {A='B',B='C',C='D',D='A'}or {A='D',B='A',C='B',D='C'}
  local o=photo.meta.orientation;photo.meta.orientation=map[o:sub(1,1)]..map[o:sub(2,2)]
 end
 function p:rotateRight()rotate(self,true)end
 function p:rotateLeft()rotate(self,false)end
 function p:quickDevelopCropAspect(value)
  if state.noop then return end
  local ratio=type(value)=='table'and value.w/value.h or 1.5
  self.meta.croppedDimensions={width=4000*ratio,height=4000};self.raw.HasCrop=true
 end
end
controller={}
function controller.getValue(name)if name=='Exposure'then return photos[state.selected].raw.Exposure2012 end end
function controller.resetToDefault(name)assert(name=='Exposure');if not state.noop then photos[state.selected].raw.Exposure2012=0 end end
function controller.resetCrop()if not state.noop then photos[state.selected].raw.HasCrop=false;photos[state.selected].raw.CropAngle=0 end end
function controller.resetTransforms()if not state.noop then local s=photos[state.selected].raw;s.PerspectiveVertical=0;s.PerspectiveScale=100 end end
function controller.resetMasking()if not state.noop then photos[state.selected].raw.MaskGroupBasedCorrections={}end end
function controller.resetRedeye()if not state.noop then photos[state.selected].raw.RedEyeInfo={}end end
function import(name)
 if name=='LrSelection'then return selection end
 if name=='LrDevelopController'then return controller end
 return oldImport(name)
end
function require(name)
 if name=='Develop'then return {capabilities=function()return {capabilities={numericParameters={'Exposure'}}}end}end
 assert(name=='Masking');return {}
end
