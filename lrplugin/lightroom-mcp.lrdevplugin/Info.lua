return {
    LrSdkVersion = 11.0,
    LrSdkMinimumVersion = 11.0,
    LrToolkitIdentifier = "dev.varunkumar.lightroom.mcp",
    LrPluginName = "Lightroom MCP Bridge",
    LrPluginInfoUrl = "https://github.com/varunkumar/lighroom-mcp",

    VERSION = { major = 2, minor = 7, revision = 0 },

    LrExportMenuItems = {
        {
            title = "Start MCP Bridge Server",
            file = "StartServer.lua",
        },
        {
            title = "Stop MCP Bridge Server",
            file = "StopServer.lua",
        },
    },

    LrInitPlugin = "InitPlugin.lua",
}
