local component = require("component")
local computer = require("computer")
local Logger = require("Logger")
local deviceInfo = computer.getDeviceInfo()
local adminTerminal = "62c0ba71-8443-407f-89f9-58b10fedc372"
local adminKeyboard = "b462c75a-3756-4f83-8f56-29b931a6986a"
local secondaryTerminals = {
    "c9b69273-fd13-4ff0-8f43-3ae3b0c5abfe"
}

local gpus = {}
local screens = {}
local displays = {} -- Screen/GPU pairs
local buttons = {}

local color = {
    red=0xE74C3C,
    yellow=0xF4D03F,
    green=0x58D68D,
    blue=0x3498DB,
    white=0xFFFFFF,
    orange=0xDB5704
}

-- Compare two components by tier, ex: 3 > 2, so 3 comes first
local function compare(comp1, comp2)
    if comp1.address == adminTerminal or comp2.address == adminTerminal then
        return comp1.address == adminTerminal
    end
    return tonumber(deviceInfo[comp1.address].capacity) > tonumber(deviceInfo[comp2.address].capacity)
end

local function drawNewPowerMonitor(DisplayData, display)
    display.setResolution(160, 50)
    display.clear()

    local title = "Power Monitor V1.2"
    display.drawText(display.center(title), 1, color["white"], title, 0)

    local sidebarText = DisplayData.ramUse .. " " .. DisplayData.connectedBatteries
    display.drawText(display.getWidth() - string.len(sidebarText), 1, color["white"], sidebarText, 0)

    display.drawText(1, 3, color["white"], DisplayData.stored, 0)
    display.drawText(1, 4, color["white"], DisplayData.percent, 0)
    display.drawText(1, 5, color["white"], DisplayData.input, 0)
    display.drawText(1, 6, color["white"], DisplayData.output, 0)

    display.drawText(1, 7, color["white"], DisplayData.avgInput, 0)
    display.drawText(1, 8, color["white"], DisplayData.avgOutput, 0)
    display.drawText(1, 9, color["white"], DisplayData.timeUntilGeneric, 0)

    for index, warning in ipairs(DisplayData.warnings) do
        display.drawText(1, index + 10, color["white"], warning, 0)
    end

    local buttonHeight = 4
    display.makeButton(1, (display.getHeight() * 2) - buttonHeight, 20, buttonHeight, color["orange"], color["white"], "OLD SCREEN", "buttonbar1", "oldMonitor")

    display.update()
end

local function drawPowerMonitor(DisplayData, display)
    display.setResolution(60, 19)
    display.clear()

    local title = "Power Monitor V1.2"
    display.drawText(display.center(title), 1, color["white"], title, 0)

    local sidebarText = DisplayData.ramUse .. " " .. DisplayData.connectedBatteries
    display.drawText(display.getWidth() - string.len(sidebarText), 1, color["white"], sidebarText, 0)

    display.drawText(1, 3, color["white"], DisplayData.stored, 0)
    display.drawText(1, 4, color["white"], DisplayData.percent, 0)
    display.drawText(1, 5, color["white"], DisplayData.input, 0)
    display.drawText(1, 6, color["white"], DisplayData.output, 0)

    display.drawText(1, 7, color["white"], DisplayData.avgInput, 0)
    display.drawText(1, 8, color["white"], DisplayData.avgOutput, 0)
    display.drawText(1, 9, color["white"], DisplayData.timeUntilGeneric, 0)

    for index, warning in ipairs(DisplayData.warnings) do
        display.drawText(1, index + 10, color["white"], warning, 0)
    end

    local buttonHeight = 2
    display.makeButton(1, (display.getHeight() * 2) - buttonHeight + 1, 12, buttonHeight, color["orange"], color["white"], "NEW SCREEN", "buttonbar1Alt", "newMonitor")

    display.update()
end

-- Get screens, gpus, and bind them as best you can
local function fetchScreenData()
    Logger.log("Fetching screen data")

    gpus = {}
    for address, name in component.list("gpu", false) do
        Logger.log("Discovered GPU: " .. address)
        table.insert(gpus, component.proxy(address))
    end
    table.sort(gpus, compare)

    -- TODO Make screens dynamic
    screens = {}
    for address, name in component.list("screen", false) do
        Logger.log("Discovered Screen: " .. address)
        table.insert(screens, component.proxy(address))
    end
    table.sort(screens, compare)

    component.setPrimary("screen", adminTerminal)
    component.setPrimary("gpu", gpus[1].address)

    displays = {}
    for index, gpu in pairs(gpus) do
        if index > #screens then
            Logger.log("More GPUs than screens, exiting bind loop")
            break
        end
        local display = dofile("external/Screen.lua")
        Logger.log("Creating new display. GPU: " .. gpu.address .. " linked to Screen: " .. screens[index].address)
        local gpuSuccess, gpuErr = pcall(display.setGPUAddress, gpu.address)
        local screenSuccess, screenErr = pcall(display.setScreenAddress, screens[index].address, true)
        table.insert(displays, display)
        
        if not gpuSuccess or not screenSuccess then
            Logger.log("WARNING: " .. ((not gpuSuccess) and ("Error setting GPU: " .. gpuErr) or ("Error setting Screen address: " .. screenErr)))
        end
    end
    Logger.log("Finished fetching screen data")
end

local function drawScreens(DisplayData)
    for index, display in pairs(displays) do
        if display.getSelectedTab() == "oldMonitor" then
            drawPowerMonitor(DisplayData, display)
        elseif display.getSelectedTab() == "newMonitor" then
            drawNewPowerMonitor(DisplayData, display)
        end
    end
end

-- Return to a good GPU/Screen state
local function resetScreens()
    for index, display in pairs(displays) do
        Logger.log("Resetting display. " .. display.getScreenAddress() .. " linked to GPU " .. display.getGPUAddress())
        display.setResolution(display.getMaxResolution())
        display.clear()

        -- Secondary displays are notified, as they cannot access the terminal
        if display.getScreenAddress() ~= adminTerminal then
            display.drawText(1, 1, color["white"], "The power monitor is off.", 0)
            display.drawText(1, 2, color["white"], "Reboot the server to re-enable.", 0)
        end

        display.update()
    end

    -- Admin terminal gets the gpu
    Logger.log("Resetting primary devices to prioritize admin terminal")
    component.screen.setPrimary(adminTerminal)
    component.keyboard.setPrimary(adminKeyboard)
    component.gpu.setPrimary(gpus[1])
    component.gpu.bind(adminTerminal, true)
end

local function screenOverload()
    return #screens > #gpus
end

local function processTouch(address, x, y)
    for index, display in pairs(displays) do
        if display.getScreenAddress() == address then
            Logger.log("Processing touch (" .. x .. ", " .. y .. "): ".. address)
            display.processTouch(x, y)
        end
    end
end

return {
    fetchScreenData = fetchScreenData,
    drawScreens = drawScreens,
    resetScreens = resetScreens,
    screenOverload = screenOverload,
    processTouch = processTouch,
}