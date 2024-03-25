local component = require("component")
local computer = require("computer")
local devinfo = computer.getDeviceInfo()

local screenutil = {}
screenutil.screens = {}
screenutil.gpus = {}
screenutil.failedBind = false
screenutil.screenOverload = false

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

local function center(text, gpu)
    local w, h = gpu.getResolution()
    local len = string.len(text)
    return math.abs((len / 2) - (w / 2))
end

local function getMaxRes(capacity)
    if capacity == "8000" then
        return 160, 50
    elseif capacity == "2000" then
        return 80, 25
    else
        return 50, 16
    end
end

-- Get screens, gpus, and bind them as best you can
function screenutil.fetchScreenData()
    devinfo = computer.getDeviceInfo()
    local anyFailedBind = false

    screenutil.screens = {}
    for address, name in component.list("screen", false) do
        table.insert(screenutil.screens, component.proxy(address))
    end

    screenutil.gpus = {}
    for address, name in component.list("gpu", false) do
        table.insert(screenutil.gpus, component.proxy(address))
    end

    if #screenutil.gpus == 0 then
        print("No GPU found")
        os.exit()
    end

    table.sort(screenutil.screens, compare)
    table.sort(screenutil.gpus, compare)

    component.setPrimary("gpu", screenutil.gpus[1].address)
    if #screenutil.screens ~= 0 then
      component.setPrimary("screen", screenutil.screens[1].address)
    end

    screenutil.screenOverload = #screenutil.screens > #screenutil.gpus

    for index, igpu in pairs(screenutil.gpus) do
        if index > #screenutil.screens then
            break
        end
        if not igpu.bind(screenutil.screens[index].address) then
            anyFailedBind = true
        else
            local screenMaxWidth, screenMaxHeight = getMaxRes(devinfo[screenutil.screens[index].address].capacity)
            local gpuMaxWidth, gpuMaxHeight = igpu.maxResolution()
            local blocksW, blocksH = screenutil.screens[index].getAspectRatio()

            local width = math.min(screenMaxWidth, gpuMaxWidth)
            local height = math.min(screenMaxHeight, gpuMaxHeight)

            -- figure this shit out
            if width >= 160 then
                igpu.setResolution(60, 19)
            elseif width >= 80 then
                igpu.setResolution(60, 19)
            else
                igpu.setResolution(width, height)
            end

            igpu.colorCapable = height >= 150
            if igpu.colorCapable then
                igpu.setBackground(0x1f1f29)
            end
        end
    end

    -- Try not to change failedBind too rapidly between update cycles
    screenutil.failedBind = anyFailedBind
end

function screenutil.drawScreens(DisplayData)

    for index, gpu in pairs(screenutil.gpus) do
        if index > #screenutil.screens then
            break
        end

        local title = "Power Monitor V1.1"
        local w, h = gpu.getResolution()

        gpu.fill(1, 1, w, h, " ")
        gpu.set(center(title, gpu), 1, title)

        gpu.set(1, 3, DisplayData.stored)
        gpu.set(1, 4, DisplayData.percent)
        gpu.set(1, 5, DisplayData.input)
        gpu.set(1, 6, DisplayData.output)

        gpu.set(1, 7, DisplayData.avgInput)
        gpu.set(1, 8, DisplayData.avgOutput)

        for index, warning in ipairs(DisplayData.warnings) do
            gpu.set(1, index + 9, warning)
        end

        gpu.set(1, h-1, DisplayData.connectedBatteries)
        gpu.set(1, h, DisplayData.ramUse)

    end
end

function screenutil.resetBindings()
    local w, h = component.gpu.getResolution()
    component.gpu.fill(1, 1, w, h, " ")
    component.gpu.bind(component.screen.address)
end


return screenutil