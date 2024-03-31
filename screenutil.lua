local component = require("component")
local computer = require("computer")
local devinfo = computer.getDeviceInfo()

local screenutil = {}
screenutil.screens = {}
screenutil.failedBind = false
screenutil.screenOverload = false

local screenProxies = {}

local color = {}
color["red"] = 0xE74C3C
color["yellow"] = 0xF4D03F
color["green"] = 0x58D68D
color["blue"] = 0x3498DB
color["white"] = 0xFFFFFF

-- Compare two components by tier, ex: 3 > 2, so 3 comes first
local function compare(comp1, comp2)
    return tonumber(devinfo[comp1.address].capacity) > tonumber(devinfo[comp2.address].capacity)
end

local function center(text, screen)
    local len = string.len(text)
    return math.abs((len / 2) - (screen.getWidth() / 2))
end

local function drawPowerMonitor(DisplayData, screen)
    screen.setResolution(60, 19)

    local title = "Power Monitor V1.1"
    screen.drawText(center(title, screen), 1, color["white"], title, 0)

    screen.drawText(1, 3, color["white"], DisplayData.stored, 0)
    screen.drawText(1, 4, color["white"], DisplayData.percent, 0)
    screen.drawText(1, 5, color["white"], DisplayData.input, 0)
    screen.drawText(1, 6, color["white"], DisplayData.output, 0)

    screen.drawText(1, 7, color["white"], DisplayData.avgInput, 0)
    screen.drawText(1, 8, color["white"], DisplayData.avgOutput, 0)
    screen.drawText(1, 9, color["white"], DisplayData.timeUntilGeneric, 0)

    for index, warning in ipairs(DisplayData.warnings) do
        screen.drawText(1, index + 10, color["white"], warning, 0)
    end

    screen.drawText(1, screen.getHeight()-1, color["white"], DisplayData.connectedBatteries, 0)
    screen.drawText(1, screen.getHeight(), color["white"], DisplayData.ramUse, 0)

    screen.update()
end

-- Get screens, gpus, and bind them as best you can
function screenutil.fetchScreenData()
    devinfo = computer.getDeviceInfo()
    local anyFailedBind = false

    screensProxies = {}
    for address, name in component.list("screen", false) do
        table.insert(screensProxies, component.proxy(address))
    end

    screenutil.gpus = {}
    for address, name in component.list("gpu", false) do
        table.insert(screenutil.gpus, component.proxy(address))
    end

    if #screenutil.gpus == 0 then
        print("No GPU found")
        os.exit()
    end

    table.sort(screensProxies, compare)
    table.sort(screenutil.gpus, compare)

    component.setPrimary("gpu", screenutil.gpus[1].address)
    if #screensProxies ~= 0 then
      component.setPrimary("screen", screensProxies[1].address)
    end

    screenutil.screenOverload = #screensProxies > #screenutil.gpus

    for index, igpu in pairs(screenutil.gpus) do
        if index > #screensProxies then
            break
        end
        local screenInstance = dofile("/home/evan/external/Screen.lua")
        screenInstance.setGPUAddress(igpu.address)
        screenInstance.setScreenAddress(screensProxies[index].address, true)
        screenInstance.clear()
        screenInstance.update()
        table.insert(screenutil.screens, screenInstance)
    end

    -- Try not to change failedBind too rapidly between update cycles
    screenutil.failedBind = anyFailedBind
end

function screenutil.drawScreens(DisplayData)

    for index, screen in pairs(screenutil.screens) do
        if index > #screensProxies then
            break
        end
        -- Insert switch for other screens
        drawPowerMonitor(DisplayData, screen)
    end
end

function screenutil.resetBindings()
    for index, screen in pairs(screenutil.screens) do
        screen.setGPUAddress(component.gpu.address)
        screen.setScreenAddress(component.screen.address, true)
    end
end


return screenutil