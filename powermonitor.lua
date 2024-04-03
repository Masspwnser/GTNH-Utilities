
local os = require("os")
local keyboard = require("keyboard")
local component = require("component")
local computer = require("computer")
local ScreenUtil = require("ScreenUtil")
local Logger = require("Logger")

local tickRate = 0.05 -- Minecraft tickrate in seconds

local logicRate = tickRate -- Frequency to poll power data
local drawRate = 1 -- Arbitrary display update rate in seconds
local dataDecay = 900 -- Data decays after 5 mins to ensure ram isnt filled
local batteries = {}

local logicSuccess = false
local drawSuccess = false

local EnergyData = {
    inputHistory = {},
    outputHistory = {},
    stored = 0,
    max = 0,
    percent = 0,
    input = 0,
    output = 0,
    input60 = 0,
    output60 = 0,
    generatorsMaxCapacity = false, -- generators on (polar), generators max capacity (scaling/backup), always (constant)
    thresholdForGenerators = 0, -- power threshold for when generators turn on
    peakInput = 0,
}

local function secondsToString(seconds)
    local time_days     = math.floor(seconds / 86400)
    local time_hours    = math.floor(math.fmod(seconds, 86400) / 3600)
    local time_minutes  = math.floor(math.fmod(seconds, 3600) / 60)
    local time_seconds  = math.floor(math.fmod(seconds, 60))
    local result = ""
    if (time_hours < 10) then
        time_hours = "0" .. time_hours
    end
    if (time_minutes < 10) then
        time_minutes = "0" .. time_minutes
    end
    if (time_seconds < 10) then
        time_seconds = "0" .. time_seconds
    end
    return time_days .. ":" .. time_hours .. ":" .. time_minutes .. ":" .. time_seconds
end

-- Polls energy history to find average over @time seconds given @history
local function getAverage(time, history)
    local startTime = computer.uptime() - time
    local decayTime = computer.uptime() - dataDecay
    local sum = 0
    local numPolled = 0

    for k, v in pairs(history) do
        if k >= startTime then -- Calculate average
            sum = sum + v
            numPolled = numPolled + 1
        elseif k < decayTime then -- Remove old values
            history[k] = nil
        end
    end

    if numPolled <= 0 then -- Avoid dividing by zero
        return 0
    end

    return sum / numPolled
end

local function fetchBatteries()
    local proxy
    batteries = {}
    for address, name in component.list("gt_machine", true) do
        proxy = component.proxy(address)
        if proxy ~= nil then
            table.insert(batteries, proxy)
        end
    end
end

local function doLogic(uptime)
    local aggStored = 0
    local aggMax = 0
    local aggInput = 0
    local aggOutput = 0

    for index, device in pairs(batteries) do
        aggStored = aggStored + device.getEUStored()
        aggMax = aggMax + device.getEUCapacity()
        aggInput = aggInput + device.getEUInputAverage()
        aggOutput = aggOutput + device.getEUOutputAverage()
    end

    EnergyData.stored = aggStored
    EnergyData.max = aggMax
    EnergyData.inputHistory[uptime] = aggInput
    EnergyData.outputHistory[uptime] = aggOutput

    EnergyData.input = getAverage(drawRate, EnergyData.inputHistory)
    EnergyData.output = getAverage(drawRate, EnergyData.outputHistory)
    EnergyData.input60 = getAverage(60, EnergyData.inputHistory)
    EnergyData.output60 = getAverage(60, EnergyData.outputHistory)

    if EnergyData.peakInput < EnergyData.input60 then
        EnergyData.peakInput = EnergyData.input60
    end
    
    EnergyData.percent = EnergyData.max ~= 0 and (EnergyData.stored / EnergyData.max) * 100 or 0;

    local generatorsOnLastCycle = EnergyData.generatorsMaxCapacity

    -- crap logic, connect to turbines ideally
    EnergyData.generatorsMaxCapacity = EnergyData.input60 > (EnergyData.peakInput * .75)

    local generatorsOnTick = not generatorsOnLastCycle and EnergyData.generatorsMaxCapacity
    -- first cycle, guess the threshold
    if generatorsOnTick and EnergyData.thresholdForGenerators == 0 then
        EnergyData.thresholdForGenerators = EnergyData.max * (.428) -- match to threshold
    elseif generatorsOnTick then
        EnergyData.thresholdForGenerators = EnergyData.stored
    end
end

local function getDisplayData()
    local avgInput60 = getAverage(60, EnergyData.inputHistory)
    local avgOutput60 = getAverage(60, EnergyData.outputHistory)
    local DisplayData = {}

    DisplayData.stored = "Stored: " .. EnergyData.stored .. " / " .. EnergyData.max .. " EU"
    DisplayData.percent = "Percent: " .. string.format("%.3f", EnergyData.percent) .. "%"
    DisplayData.input = "Input: " .. string.format("%.0f", EnergyData.input) .. " EU/t"
    DisplayData.output = "Output: " .. string.format("%.0f", EnergyData.output) .. " EU/t"
    DisplayData.avgInput = "Average Input: " .. string.format("%.0f", avgInput60) .. " EU/t over 1m"
    DisplayData.avgOutput = "Average Output: " .. string.format("%.0f", avgOutput60) .. " EU/t over 1m"

    DisplayData.connectedBatteries = "BAT: " .. string.format("%d", #batteries)
    DisplayData.ramUse = "RAM: " .. string.format("%2.f", ((computer.totalMemory() - computer.freeMemory()) / computer.totalMemory()) * 100) .. "%"

    local powerAbs = math.abs(EnergyData.input60 - EnergyData.output60) * 20
    if EnergyData.input60 == EnergyData.output60 or #batteries == 0 then
        DisplayData.timeUntilGeneric = ""
    elseif EnergyData.input60 > EnergyData.output60 then
        DisplayData.timeUntilGeneric = "Time until full: " .. secondsToString((EnergyData.max - EnergyData.stored) / powerAbs)
    elseif not EnergyData.generatorsMaxCapacity and EnergyData.thresholdForGenerators < EnergyData.stored then
        DisplayData.timeUntilGeneric = "Time until generators on: " .. secondsToString((EnergyData.stored - EnergyData.thresholdForGenerators) / powerAbs)
    elseif EnergyData.generatorsMaxCapacity and EnergyData.output60 > EnergyData.input60 then
        DisplayData.timeUntilGeneric = "Time until empty: ".. secondsToString(EnergyData.stored / powerAbs)
    else
        DisplayData.timeUntilGeneric = ""
    end

    DisplayData.warnings = {}

    if computer.freeMemory() < 20000 then
        table.insert(DisplayData.warnings, "WARNING: Low RAM")
    end

    if ScreenUtil.screenOverload() then
        table.insert(DisplayData.warnings, "WARNING: More screens than GPUs")
    end

    if not batteries or #batteries == 0 then
        table.insert(DisplayData.warnings, "WARNING: Failed to obtain battery data")
    elseif EnergyData.percent == 0 then
        table.insert(DisplayData.warnings, "WARNING: No Power")
    elseif EnergyData.percent < 5 then
        table.insert(DisplayData.warnings, "WARNING: Low Power")
    end

    if avgOutput60 > avgInput60 and EnergyData.generatorsMaxCapacity then
        table.insert(DisplayData.warnings, "WARNING: Output exceeds input")
    end

    if not logicSuccess then
        table.insert(DisplayData.warnings, "WARNING: Logic error")
    end

    if not drawSuccess then
        table.insert(DisplayData.warnings, "WARNING: Draw error")
    end

    return DisplayData
end

local function processSignal(name, arg1, arg2, arg3)
    if name == "component_added" or name == "component_removed" then
        if arg2 == "gt_machine" then
            fetchBatteries()
        elseif arg2 == "screen" or arg2 == "gpu" then
            ScreenUtil.fetchScreenData()
        end
    elseif name == "touch" then
        ScreenUtil.processTouch(arg1, arg2, arg3)
    end
end

local function main()
    local lastDrawTime = 0

    Logger.enableLogging()
    Logger.log("Starting power monitor")

    while true do
        local uptime = computer.uptime()
        local logicErr, drawErr

        logicSuccess, logicErr = pcall(doLogic, uptime)

        if uptime - lastDrawTime >= drawRate then
            lastDrawTime = uptime
            drawSuccess, drawErr = pcall(ScreenUtil.drawScreens, getDisplayData())
        end

        if not logicSuccess then
            Logger.log("Logic exited with error: " .. logicErr)
        end

        if not drawSuccess then
            Logger.log("Drawing exited with error: " .. drawErr)
        end

        processSignal(computer.pullSignal(logicRate))

        -- TODO add signal detection logic
        if keyboard.isShiftDown() then
            Logger.log("Hit escape sequence, exiting")
            return
        end
    end
end

os.sleep(5)

local success, err = pcall(main)

pcall(ScreenUtil.resetScreens)

Logger.log("Exiting application")
if not success then
    Logger.log("Exited with error: " .. err)
    print("Exited with error: " .. err)
end
-- TODO Print logs to screen
Logger.close()