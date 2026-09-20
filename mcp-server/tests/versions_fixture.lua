-- Extend the develop fixture with native snapshot/preset/copy behavior.
local baseImport=import
state.module="library";state.selection={photos.a};state.nextSnapshot=0;state.nextCopy=0
local function clone(t)
    if type(t)~="table" then return t end
    local out={};for k,v in pairs(t) do out[k]=clone(v) end;return out
end
local function extend(photo,parent,name)
    photo.snapshots={};photo.copies={};photo.parent=parent;photo.copyName=name or ""
    local oldMeta=photo.getRawMetadata
    function photo:getRawMetadata(key)
        if key=="isVirtualCopy" then return self.parent~=nil end
        if key=="masterPhoto" then return self.parent end
        if key=="virtualCopies" then return self.copies end
        return oldMeta(self,key)
    end
    function photo:getFormattedMetadata(key) if key=="copyName" then return self.copyName end; return self.id .. ".NEF" end
    function photo:getDevelopSnapshots()
        if state.badSnapshots then return false end
        local result={}
        for _,s in ipairs(self.snapshots) do result[#result+1]={snapshotID=s.snapshotID,id_global=s.id_global,name=s.name} end
        return result
    end
    function photo:createDevelopSnapshot(name,update)
        assert(state.inWrite,"snapshot creation needs write gate")
        if state.createNoop then return true end
        for _,s in ipairs(self.snapshots) do
            if s.name==name then if not update then return false end; s.raw=clone(self.raw);state.nextSnapshot=state.nextSnapshot+1;s.snapshotID="local-"..state.nextSnapshot;return true end
        end
        state.nextSnapshot=state.nextSnapshot+1
        self.snapshots[#self.snapshots+1]={snapshotID="local-"..state.nextSnapshot,id_global="global-"..state.nextSnapshot,name=name,raw=clone(self.raw)}
        return true
    end
    function photo:applyDevelopSnapshot(id)
        assert(not state.inWrite and state.module=="develop","snapshot apply is a Develop operation")
        for _,s in ipairs(self.snapshots) do if s.snapshotID==id then self.raw=clone(s.raw);return end end
        error("Wrong apply ID")
    end
    function photo:deleteDevelopSnapshot(id)
        assert(not state.inWrite and state.module=="develop","snapshot delete is a Develop operation")
        if state.deleteNoop then return end
        for i,s in ipairs(self.snapshots) do if s.id_global==id then table.remove(self.snapshots,i);return end end
        error("Wrong deletion ID: requires id_global")
    end
    function photo:updateAISettings() state.lastAI=true end
    function photo:applyDevelopPreset(preset,plugin,amount,updateAI)
        assert(state.inWrite,"preset needs write gate")
        if state.failPreset==self.id then error("injected preset failure") end
        state.presetCalls=(state.presetCalls or 0)+1
        state.lastAmount=amount;state.lastAI=updateAI;state.lastPlugin=plugin
        for k,v in pairs(preset.settings) do self.raw[k]=v end
    end
end
extend(photos.a);extend(photos.b)
function catalog:getTargetPhotos() return state.selection end
function catalog:setSelectedPhotos(photo,selection)
    if state.selectionNoop then return end
    state.selected=photo.id;state.selection=selection
end
function catalog:withWriteAccessDo(name,fn)
    if state.lockTimeout then return "aborted" end
    if state.switchBeforeWrite then state.selected="b" end
    state.inWrite=true
    local ok,value=pcall(fn)
    state.inWrite=false
    if not ok then error(value,0) end
    return value
end
function catalog:createVirtualCopies(name)
    assert(not state.inWrite,"copy creation must not hold a write gate")
    if state.copyNoop then return {} end
    local result={}
    for _,source in ipairs(state.selection) do
        state.nextCopy=state.nextCopy+1
        local id="copy-"..state.nextCopy
        local copy={id=id,raw=clone(source.raw),getRawMetadata=photos.a.getRawMetadata,getDevelopSettings=photos.a.getDevelopSettings}
        extend(copy,source.parent or source,name)
        photos[id]=copy;table.insert(copy.parent.copies,copy);result[#result+1]=copy
    end
    catalog:setSelectedPhotos(result[1],result)
    return result
end
presets={}
local function preset(id,name,settings)
    local p={id=id,name=name,settings=settings}
    function p:getUuid() return self.id end
    function p:getName() return self.name end
    return p
end
presets[1]=preset("p-a","同名风格",{Exposure2012=1.2})
presets[2]=preset("p-b","同名风格",{Exposure2012=-.8})
presets[3]=preset("p-owned","Plugin style",{RedHue=12})
_PLUGIN={id="test.plugin",path="/test/plugin"}
function import(name)
    if name=="LrApplicationView" then return {
        getCurrentModuleName=function() return state.module end,
        switchToModule=function(module) if not state.moduleNoop then state.module=module end end,
    } end
    if name=="LrApplication" then
        local app=baseImport(name)
        app.developPresetFolders=function() return {{getName=function() return "User Presets" end,getDevelopPresets=function() return {presets[1],presets[2]} end}} end
        app.getDevelopPresetsForPlugin=function() return {presets[3]} end
        return app
    end
    return baseImport(name)
end
