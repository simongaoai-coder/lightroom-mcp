local previousImport=import
function catalog:getPath()return state.path or '/test/catalog'end
function catalog:findPhotoByUuid(id)return photos[id]end
state.clipboard=nil;state.copyCalls=0;state.pasteCalls=0;state.undoStack={};state.redoStack={}
local function clone(v)if type(v)~='table'then return v end;local r={};for k,x in pairs(v)do r[k]=clone(x)end;return r end
for _,photo in pairs(photos)do
 function photo:copySettings()
  assert(not state.inWrite);state.copyCalls=state.copyCalls+1
  if state.copyFail then return false end
  state.clipboard={Exposure2012=self.raw.Exposure2012};return true
 end
 function photo:pasteSettings(ai)
  assert(not state.inWrite and ai==false);state.pasteCalls=state.pasteCalls+1
  if state.pasteFail then return false end
  state.undoStack[#state.undoStack+1]={id=self.id,raw=clone(self.raw)};state.redoStack={}
  if not state.pasteNoop then for k,v in pairs(state.clipboard)do self.raw[k]=v end end
  return true
 end
end
undo={}
function undo.canUndo()return #state.undoStack>0 end
function undo.canRedo()return #state.redoStack>0 end
function undo.undo()
 state.undoCalls=(state.undoCalls or 0)+1;if state.undoError then error('injected undo failure')end
 local e=table.remove(state.undoStack);if e then state.redoStack[#state.redoStack+1]={id=e.id,raw=clone(photos[e.id].raw)};photos[e.id].raw=clone(e.raw)end
end
function undo.redo()
 local e=table.remove(state.redoStack);if e then state.undoStack[#state.undoStack+1]={id=e.id,raw=clone(photos[e.id].raw)};photos[e.id].raw=clone(e.raw)end
end
function import(name)if name=='LrUndo'then return undo end;return previousImport(name)end
function require(name)assert(name=='Develop');return developModule end
