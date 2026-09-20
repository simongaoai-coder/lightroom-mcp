local oldImport=import
for _,p in pairs(photos) do
 p.meta.cameraMake='Sony';p.meta.cameraModel='Test Camera'
 p.raw={CameraProfile='Adobe Standard',Look={Name='Adobe Color',UUID='color',Parameters={CameraProfile='Adobe Standard'}},ConvertToGrayscale=false,
  WhiteBalance='Custom',Temperature=5000,Tint=5,Exposure2012=.6,ToneCurvePV2012={0,0,255,255}}
 function p:getDevelopSettings()return copyForAppearance(self.raw)end
 function p:applyDevelopSettings(values)
  assert(state.inWrite,'catalog settings need gate');state.writes=state.writes+1
  if state.noop then return end
  for k,v in pairs(values)do self.raw[k]=copyForAppearance(v)end
 end
 function p:quickDevelopSetTreatment(t)
  assert(not state.inWrite);state.writes=state.writes+1;if state.noop then return end
  self.raw.ConvertToGrayscale=t=='grayscale'
 end
 function p:quickDevelopSetWhiteBalance(mode)
  assert(not state.inWrite);state.writes=state.writes+1;if state.noop then return end
  self.raw.WhiteBalance=mode;self.raw.Temperature=6100;self.raw.Tint=7
 end
end
function copyForAppearance(v)if type(v)~='table'then return v end;local r={};for k,x in pairs(v)do r[k]=copyForAppearance(x)end;return r end
function catalog:withWriteAccessDo(label,fn)
 if state.lockTimeout then return 'aborted' end
 if state.switchBeforeWrite then state.selected='b' end
 state.inWrite=true;local ok,r=pcall(fn);state.inWrite=false;if not ok then error(r)end;return r
end
preset={settings={CameraProfile='Adobe Standard',Look={Name='Adobe Neutral',UUID='neutral'},ConvertToGrayscale=false,Exposure2012=4}}
function preset:getUuid()return 'preset1'end
function preset:getName()return 'Neutral + Exposure'end
function preset:getSetting()if state.presetError then error('unavailable')end;return copyForAppearance(self.settings)end
local application=oldImport('LrApplication')
function application.developPresetFolders()return {{getDevelopPresets=function()return {preset}end}}end
function import(name)
 if name=='LrDevelopController'then return {}end
 return oldImport(name)
end
function require(name)assert(name=='Masking');return {}end
