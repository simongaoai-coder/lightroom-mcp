-- Deterministic SDK double. The tests execute the production Lua module under Lua 5.1.
state = {now=0, module="library", panel="loupe", selected="B", tool="B1", writes=0,
    masks={
        {ID="A", Name="天空", Hidden=false, Tools={{ID="A1", Type="aiSelection", Subtype="sky"}, {ID="A2", Type="brush"}}},
        {ID="B", Name="Subject", Tools={{ID="B1", Type="aiSelection", Subtype="subject"}}},
    }, values={A={local_Exposure=0,local_Highlights=0},B={local_Exposure=0,local_Highlights=0}}}
local photo = {getRawMetadata=function() return "photo-1" end,
    getDevelopSettings=function()
        local corrections = {}
        for _, mask in ipairs(state.masks) do corrections[#corrections+1] = {CorrectionID=mask.ID} end
        return {MaskGroupBasedCorrections=corrections}
    end}
local other = {getRawMetadata=function() return "photo-2" end}
state.photo = photo
local catalog = {getTargetPhoto=function() return state.photo end,
    withReadAccessDo=function(self, f) f() end}
controller = {}
function controller.getAllMasks()
    if (state.emptyReads or 0) > 0 then
        state.emptyReads = state.emptyReads - 1
        return {}
    end
    if (state.pendingReads or 0) > 0 then
        state.pendingReads = state.pendingReads - 1
        return state.pendingValue
    end
    return state.badSummary and {{unexpected=true}} or state.masks
end
function controller.getSelectedMask() return state.selected end
function controller.getSelectedMaskTool() return state.tool end
function controller.getSelectedTool() return state.panel end
function controller.goToMasking() state.panel = "masking" end
function controller.selectMask(maskId)
    if state.selectionError then error("SDK selection error") end
    if not state.selectionNoop then
        state.selected = maskId
        for _, mask in ipairs(state.masks) do if mask.ID == maskId then state.tool = mask.Tools[1] and mask.Tools[1].ID end end
    end
end
function controller.selectMaskTool(toolId) if not state.toolNoop then state.tool = toolId end end
function controller.getRange(key)
    if key == "local_ColorNoise" then error("unsupported slider") end
    if key == "local_Exposure" then return -5,5 end
    return -100,100
end
function controller.setValue(key, value)
    if state.writeError then error("SDK slider error") end
    state.writes = state.writes + 1
    if not state.writeNoop then state.values[state.selected][key] = value end
end
function controller.getValue(key) return state.values[state.selected][key] or 0 end
function controller.deleteMask(maskId)
    state.pendingReads = state.deletePendingReads
    if state.deleteNoop then return end
    for i, mask in ipairs(state.masks) do if mask.ID == maskId then table.remove(state.masks,i);break end end
    state.selected, state.tool = nil,nil
end
function controller.deleteMaskTool(toolId)
    if state.deleteNoop then return end
    for _, mask in ipairs(state.masks) do
        if mask.ID == state.selected then
            for i, tool in ipairs(mask.Tools) do if tool.ID == toolId then table.remove(mask.Tools,i);break end end
            if #mask.Tools == 0 then controller.deleteMask(mask.ID) else state.tool = mask.Tools[1].ID end
            break
        end
    end
end
function controller.createNewMask(kind, subtype)
    state.creations = (state.creations or 0) + 1
    state.pendingReads = state.createPendingReads
    if state.createNoop or kind ~= "aiSelection" then return end
    local maskId = "new-" .. state.creations
    state.masks[#state.masks+1] = {ID=maskId,Name=subtype,Tools={{ID=maskId.."-tool",Type=kind,Subtype=subtype}}}
    state.values[maskId] = {}
    state.selected, state.tool = maskId, maskId.."-tool"
end
local tasks = {pcall=pcall, sleep=function(t)
    state.now = state.now + t
    if state.switchPhoto then state.photo = other end
    if state.switchSelection then state.selected = "B" end
end}
local modules = {
    LrDevelopController=controller, LrTasks=tasks,
    LrApplication={activeCatalog=function() return catalog end},
    LrApplicationView={getCurrentModuleName=function() return state.module end,
        switchToModule=function(name) state.module=name end},
    LrDate={currentTime=function() return state.now end},
}
function import(name) return assert(modules[name], name) end
