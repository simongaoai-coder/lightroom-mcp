local originalImport=import
state.spots={{id='s1',x=.4},{id='s2',x=.7}};state.spotIndex=1
state.params={size=.03,Opacity=1,Feather=.5};state.kind='heal';state.gen=false
state.prefs={newSpotType='heal',brushSize=10,brushFeather=50,useGenerativeAI=false,detectObjects=false,toolOverlay='auto',visualizeSpots=false,visualizationThreshold=50}
local function clone(v) if type(v)~='table' then return v end;local out={};for k,x in pairs(v) do out[k]=clone(x) end;return out end
controller={}
function controller.goToRemove(kind)state.tool='dust';if kind then state.prefs.newSpotType=kind end end
function controller.getSelectedTool()return state.tool end
function controller.countAllSpots()return state.countOverride or #state.spots end
function controller.getAllSpots()if state.listNil then return nil end;return clone(state.spots)end
function controller.getSelectedSpotIndex()return state.spotIndex end
function controller.setSelectedSpotIndex(i)if not state.noop then state.spotIndex=i end;return true end
function controller.getSelectedSpotParams()return clone(state.params)end
function controller.getSelectedSpotType()return state.kind,state.gen end
function controller.setSelectedSpotParams(p)assert(not state.inWrite);if not state.noop then state.params=clone(p) end end
function controller.setSelectedSpotType(k,g)assert(not state.inWrite);if not state.noop then state.kind=k;state.gen=g end end
function controller.moveSelectedSpot(h,v,hu,vu,source)state.move={h=h,v=v,hu=hu,vu=vu,source=source};if not state.noop then state.spots[state.spotIndex].x=state.spots[state.spotIndex].x+.01 end end
function controller.refreshSelectedSpot()state.refreshed=true end
function controller.gotoNextVariation()state.variation='next' end
function controller.gotoPreviousVariation()state.variation='previous' end
function controller.deleteSelectedSpot()if not state.noop then table.remove(state.spots,state.spotIndex);state.spotIndex=nil end end
function controller.resetHealing()if not state.noop then state.spots={};state.spotIndex=nil end end
function controller.getRemovePanelPreferences()return clone(state.prefs)end
function controller.setRemovePanelPreferences(p)if not state.noop then for k,v in pairs(p) do state.prefs[k]=v end end;return true end
function catalog:withWriteAccessDo(label,fn)
 if state.lockTimeout then return 'aborted' end
 state.inWrite=true;local ok,result=pcall(fn);state.inWrite=false;if not ok then error(result) end;return result
end
for _,p in pairs(photos) do
 p.settings={MaskGroupBasedCorrections={{CorrectionID='empty',empty=true},{CorrectionID='keep'}}}
 function p:getDevelopSettings()return clone(self.settings)end
 function p:updateAISettings()
  assert(state.inWrite,'AI update needs write gate')
  if self.id==state.failPhoto then error('injected AI failure')end
  state.aiCalls=(state.aiCalls or 0)+1
 end
end
function catalog:deleteAllEmptyMasks(ps)
 assert(state.inWrite and type(ps)=='table' and #ps==1,'explicit photo/write gate required')
 for _,p in ipairs(ps)do local out={};for _,m in ipairs(p.settings.MaskGroupBasedCorrections)do if not m.empty then out[#out+1]=m end end;p.settings.MaskGroupBasedCorrections=out end
end
function import(name)
 if name=='LrDevelopController' then return controller end
 if name=='LrMD5' then return {digest=function(s)return pyDigest(s)end} end
 return originalImport(name)
end
local taskModule=originalImport('LrTasks')
local oldSleep=taskModule.sleep
function taskModule.sleep(t)oldSleep(t);if state.onSleep then state.onSleep()end end
