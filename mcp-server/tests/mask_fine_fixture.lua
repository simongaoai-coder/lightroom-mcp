for _,m in ipairs(state.masks) do
    if m.Hidden==nil then m.Hidden=false end
    for _,t in ipairs(m.Tools) do t.Hidden=false;t.Inverted=false end
end
local function mask(id) for _,m in ipairs(state.masks) do if m.ID==id then return m end end end
local function tool(id) for _,t in ipairs(mask(state.selected).Tools) do if t.ID==id then return t end end end
function controller.toggleHideMask(id) if not state.toggleNoop then mask(id).Hidden=not mask(id).Hidden end end
function controller.toggleHideMaskTool(id) if not state.toggleNoop then tool(id).Hidden=not tool(id).Hidden end end
function controller.toggleInvertMaskTool(id) if not state.toggleNoop then tool(id).Inverted=not tool(id).Inverted end end
function controller.invertMask(id)
    if state.invertFail then return false end
    for _,t in ipairs(mask(id).Tools) do t.Inverted=not t.Inverted end
    return true
end
function controller.duplicateAndInvertMask(id)
    if state.invertFail then return false end
    if state.duplicateNoop then return true end
    local source=mask(id)
    state.masks[#state.masks+1]={ID='duplicate',Name=source.Name,Hidden=false,Tools={{ID='duplicate-tool',Type='brush',Hidden=false,Inverted=true}}}
    state.values.duplicate={};state.selected='duplicate';return true
end
local function combine(op,kind,subtype)
    state.lastOperation=op
    if state.combineNoop or kind~='aiSelection' then return end
    local m=mask(state.selected)
    m.Tools[#m.Tools+1]={ID='component-'..#m.Tools,Type=kind,Subtype=subtype,Hidden=false,Inverted=op~='add'}
end
function controller.addToCurrentMask(k,s) combine('add',k,s) end
function controller.subtractFromCurrentMask(k,s) combine('subtract',k,s) end
function controller.intersectWithCurrentMask(k,s) combine('intersect',k,s) end
