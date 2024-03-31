local component = require("component")
local computer = require("computer")
local deviceInfo = computer.getDeviceInfo()
local adminScreen = "62c0ba71-8443-407f-89f9-58b10fedc372"

local ScreenUtil = {}

local gpus = {}
local screens = {}
local displays = {} -- Screen/GPU pairs

ScreenUtil.failedBind = false
ScreenUtil.screenOverload = false

local color = {
    red=0xE74C3C,
    yellow=0xF4D03F,
    green=0x58D68D,
    blue=0x3498DB,
    white=0xFFFFFF
}

-- Compare two components by tier, ex: 3 > 2, so 3 comes first
local function compare(comp1, comp2)
    return tonumber(deviceInfo[comp1.address].capacity) > tonumber(deviceInfo[comp2.address].capacity)
end

local function center(text, display)
    local len = string.len(text)
    return math.abs((len / 2) - (display.getWidth() / 2))
end

local function drawPowerMonitor(DisplayData, display)
    display.setResolution(60, 19)
    display.clear()

    local title = "Power Monitor V1.2"
    display.drawText(center(title, display), 1, color["white"], title, 0)

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

    display.update()
end

-- Get screens, gpus, and bind them as best you can
function ScreenUtil.fetchScreenData()

    gpus = {}
    for address, name in component.list("gpu", false) do
        table.insert(gpus, component.proxy(address))
    end
    table.sort(gpus, compare)

    -- TODO Make screens dynamic
    screens = {}
    for address, name in component.list("screen", false) do
        table.insert(screens, component.proxy(address))
    end

    displays = {}
    for index, gpu in pairs(gpus) do
        if index > #screens then
            break
        end
        local display = dofile("external/Screen.lua")
        display.setGPUAddress(gpu.address)
        display.setScreenAddress(screens[index].address, true)
        table.insert(displays, display)
    end
end

function ScreenUtil.drawScreens(DisplayData)

    for index, display in pairs(displays) do
        -- TODO Insert switch for other displays
        drawPowerMonitor(DisplayData, display)
    end
end

-- Return to a good GPU/Screen state
function ScreenUtil.resetScreens()
    for index, display in pairs(displays) do
        display.setResolution(display.getMaxResolution())
        display.clear()

        -- Secondary displays are notified, as they cannot access the terminal
        if display.getScreenAddress() ~= adminScreen then
            display.drawText(1, 4, color["white"], "The power monitor is off.", 0)
            display.drawText(1, 5, color["white"], "Reboot the server to re-enable.", 0)
        end

        display.update()
    end

    -- Admin terminal gets the gpu
    component.gpu.bind(adminScreen, false)
end

function ScreenUtil.screenOverload()
    return #screens > #gpus
end

return ScreenUtil