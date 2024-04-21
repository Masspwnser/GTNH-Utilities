
local os = require("os")
local keyboard = require("keyboard")
local component = require("component")
local computer = require("computer")
local ScreenUtil = require("ScreenUtil")
local Logger = require("Logger")
local Utilities = require("Utilities")

local tickRate = 0.05 -- Minecraft tickrate in seconds

local logicRate = tickRate -- Frequency to poll power data
local drawRate = 1 -- Arbitrary display update rate in seconds
local dataDecay = 3600 -- Data decays after 5 mins to ensure ram isnt filled
local batteries = {}

local EnergyData = {
    inputHistory = {},
    outputHistory = {},
    generatorsOn = false, -- generators on (polar), generators max capacity (scaling/backup), always (constant)
    thresholdForGenerators = 0, -- power threshold for when generators turn on

    stored = 0,
    storedMax = 0,
    storedPercent = 0,

    inputSec = 0,
    inputMin = 0,
    inputHr = 0,

    outputSec = 0,
    outputMin = 0,
    outputHr = 0,

    peakInputSec = 0,
    peakInputMin = 0,
    peakInputHr = 0,
    peakOutputSec = 0,
    peakOutputMin = 0,
    peakOutputHr = 0,
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
    if time > dataDecay then
        Logger.log("Attempted to access data older than we currently can store.")
        return 0
    end
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
    -- TODO only take in actual batteries
    local proxy
    batteries = {}
    for address, name in component.list("gt_machine", true) do
        proxy = component.proxy(address)
        if proxy ~= nil then
            proxy.special = proxy.getEUCapacity()
            table.insert(batteries, proxy)
        end
    end
    table.sort(batteries, Utilities.compareComponents)
end

local function doLogic(uptime)
    if #batteries == 0 then
        return
    end

    local bat = batteries[1] -- Work with multiple tabs here... TODO
    EnergyData.stored = bat.getEUStored()
    EnergyData.storedMax = bat.getEUCapacity()
    EnergyData.inputHistory[uptime] = bat.getEUInputAverage()
    EnergyData.outputHistory[uptime] = bat.getEUOutputAverage()

    -- Avg inputs over 1s, 1m, 1h
    EnergyData.inputSec = getAverage(1, EnergyData.inputHistory)
    EnergyData.inputMin = getAverage(60, EnergyData.inputHistory)
    EnergyData.inputHr = getAverage(3600, EnergyData.inputHistory)

    -- Avg outputs over 1s, 1m, 1h
    EnergyData.outputSec = getAverage(1, EnergyData.outputHistory)
    EnergyData.outputMin = getAverage(60, EnergyData.outputHistory)
    EnergyData.outputHr = getAverage(3600, EnergyData.outputHistory)

    EnergyData.storedPercent = EnergyData.storedMax ~= 0 and (EnergyData.stored / EnergyData.storedMax) or 0;

    -- Input peaks
    if EnergyData.peakInputSec < EnergyData.inputSec then
        EnergyData.peakInputSec = EnergyData.inputSec
    end
    if EnergyData.peakInputMin < EnergyData.inputMin then
        EnergyData.peakInputMin = EnergyData.inputMin
    end
    if EnergyData.peakInputHr < EnergyData.inputHr then
        EnergyData.peakInputHr = EnergyData.inputHr
    end

    -- Output peaks
    if EnergyData.peakOutputSec < EnergyData.outputSec then
        EnergyData.peakOutputSec = EnergyData.outputSec
    end
    if EnergyData.peakOutputMin < EnergyData.outputMin then
        EnergyData.peakOutputtMin = EnergyData.outputMin
    end
    if EnergyData.peakOutputHr < EnergyData.outputHr then
        EnergyData.peakOutputHr = EnergyData.outputHr
    end

    local generatorsWereOff = not EnergyData.generatorsOn

    -- Determine whether main generators are on (ignores passive power)
    -- Currently based on whether input exceeds 75% of max power ever recorded
    EnergyData.generatorsOn = EnergyData.inputMin > (EnergyData.peakInputMin * 0.75)

    local generatorsJustTurnedOn = generatorsWereOff and EnergyData.generatorsOn
    -- First cycle, guess the threshold.
    if generatorsJustTurnedOn and EnergyData.thresholdForGenerators == 0 then
        EnergyData.thresholdForGenerators = EnergyData.storedMax * 0.428 -- Match to analog threshold
    elseif generatorsJustTurnedOn then
        EnergyData.thresholdForGenerators = EnergyData.stored
    end
end

local function getDisplayData()
    local DisplayData = {}

    --------------- Values for new screen ---------------
    -- Batteries
    DisplayData.storedString = EnergyData.stored
    DisplayData.storedPercent = EnergyData.storedPercent
    DisplayData.thresholdPercent = EnergyData.thresholdForGenerators

    -- Inputs
    DisplayData.inputSecString = string.format("%.0f", EnergyData.inputSec) .. " EU/t"
    DisplayData.inputSecPercent = EnergyData.peakInputSec ~= 0 and math.ceil((EnergyData.inputSec / EnergyData.peakInputSec) * 100) or 0;

    DisplayData.inputMinString = string.format("%.0f", EnergyData.inputMin) .. " EU/t"
    DisplayData.inputMinPercent = EnergyData.peakInputMin ~= 0 and math.ceil((EnergyData.inputMin / EnergyData.peakInputMin) * 100) or 0;

    DisplayData.inputHrString = string.format("%.0f", EnergyData.inputHr) .. " EU/t"
    DisplayData.inputHrPercent = EnergyData.peakInputHr ~= 0 and math.ceil((EnergyData.inputHr / EnergyData.peakInputHr) * 100) or 0;

    -- Outputs
    DisplayData.outputSecString = string.format("%.0f", EnergyData.outputSec) .. " EU/t"
    DisplayData.outputSecPercent = EnergyData.peakOutputSec ~= 0 and math.ceil((EnergyData.outputSec / EnergyData.peakOutputSec) * 100) or 0;

    DisplayData.outputMinString = string.format("%.0f", EnergyData.outputMin) .. " EU/t"
    DisplayData.outputMinPercent = EnergyData.peakOutputMin ~= 0 and math.ceil((EnergyData.outputMin / EnergyData.peakOutputMin) * 100) or 0;

    DisplayData.outputHrString = string.format("%.0f", EnergyData.outputHr) .. " EU/t"
    DisplayData.outputHrPercent = EnergyData.peakOutputHr ~= 0 and math.ceil((EnergyData.outputHr / EnergyData.peakOutputHr) * 100) or 0;

    -- Util
    DisplayData.numBatteries = #batteries
    DisplayData.ramPercent = math.ceil(((computer.totalMemory() - computer.freeMemory()) / computer.totalMemory()) * 100)
    --------------------------------

    DisplayData.stored = "Stored: " .. EnergyData.stored .. " / " .. EnergyData.storedMax .. " EU"
    DisplayData.percent = "Percent: " .. string.format("%.3f", (EnergyData.storedPercent * 100)) .. "%"
    DisplayData.inputSec = "Input: " .. string.format("%.0f", EnergyData.inputSec) .. " EU/t"
    DisplayData.outputSec = "Output: " .. string.format("%.0f", EnergyData.outputSec) .. " EU/t"
    DisplayData.avgInput = "Average Input: " .. string.format("%.0f", EnergyData.inputMin) .. " EU/t over 1m"
    DisplayData.avgOutput = "Average Output: " .. string.format("%.0f", EnergyData.outputMin) .. " EU/t over 1m"

    DisplayData.connectedBatteries = "BAT: " .. string.format("%d", #batteries)
    DisplayData.ramUse = "RAM: " .. string.format("%2.f", ((computer.totalMemory() - computer.freeMemory()) / computer.totalMemory()) * 100) .. "%"

    local powerAbs = math.abs(EnergyData.inputMin - EnergyData.outputMin) * 20
    if EnergyData.inputMin == EnergyData.outputMin or #batteries == 0 then
        DisplayData.timeUntilGeneric = ""
    elseif EnergyData.inputMin > EnergyData.outputMin then
        DisplayData.timeUntilGeneric = "Time until full: " .. secondsToString((EnergyData.storedMax - EnergyData.stored) / powerAbs)
    elseif not EnergyData.generatorsOn and EnergyData.thresholdForGenerators < EnergyData.stored then
        DisplayData.timeUntilGeneric = "Time until generators on: " .. secondsToString((EnergyData.stored - EnergyData.thresholdForGenerators) / powerAbs)
    elseif EnergyData.generatorsOn and EnergyData.outputMin > EnergyData.inputMin then
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
    elseif EnergyData.storedPercent == 0 then
        table.insert(DisplayData.warnings, "WARNING: No Power")
    elseif EnergyData.storedPercent < 0.05 then
        table.insert(DisplayData.warnings, "WARNING: Low Power")
    end

    if EnergyData.outputMin > EnergyData.inputMin and EnergyData.generatorsOn then
        table.insert(DisplayData.warnings, "WARNING: Output exceeds input")
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

    fetchBatteries()
    ScreenUtil.fetchScreenData()

    Logger.log("Successfully fetched data.")

    while true do
        local uptime = computer.uptime()

        local logicSuccess, logicErr = pcall(doLogic, uptime)
        local signalSuccess, signalErr = pcall(processSignal, computer.pullSignal(logicRate))

        if uptime - lastDrawTime >= drawRate then
            lastDrawTime = uptime
            local drawSuccess, drawErr = pcall(ScreenUtil.drawScreens, getDisplayData())

            if not drawSuccess then
                Logger.log("Drawing exited with error: " .. drawErr)
            end
        end

        if not logicSuccess then
            Logger.log("Logic exited with error: " .. logicErr)
        end

        if not signalSuccess then
            Logger.log("Signal pull exited with error: " .. signalErr)
        end

        -- TODO add signal detection logic
        if keyboard.isShiftDown() then
            Logger.log("Hit escape sequence, exiting")
            return
        end
    end
end

os.sleep(1)

local success, err = pcall(main)

pcall(ScreenUtil.resetScreens)

Logger.log("Exiting application")
if not success then
    Logger.log("Exited with error: " .. err)
    print("Exited with error: " .. err)
end
-- TODO Print logs to screen
Logger.close()