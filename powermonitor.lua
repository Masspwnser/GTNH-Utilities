
local os = require("os")
local keyboard = require("keyboard")
local component = require("component")
local computer = require("computer")
local screenutil = require("screenutil")

local tickRate = 0.05 -- Minecraft tickrate in seconds

local logicRate = tickRate -- Frequency to poll power data
local drawRate = 1 -- Arbitrary display update rate in seconds
local dataDecay = 900 -- Data decays after 5 mins to ensure ram isnt filled
local logicSuccess = false

local devices = {}

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

local DisplayData = {
    stored = "",
    percent = "",
    input = "",
    output = "",
    avgInput = "",
    avgOutput = "",
    timeUntilGeneric = "",
    timeUntilEmpty = "",
    connectedBatteries = "",
    ramUse = "",
    warnings = {}
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

local function fetchDevices()
    local proxy
    devices = {}
    for address, name in component.list("gt_machine", true) do
        proxy = component.proxy(address)
        if proxy ~= nil then
            table.insert(devices, proxy)
        end
    end
end

local function doLogic(uptime)
    local aggStored = 0
    local aggMax = 0
    local aggInput = 0
    local aggOutput = 0

    for index, device in pairs(devices) do
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
    
    EnergyData.percent = (EnergyData.stored / EnergyData.max) * 100;

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

local function updateDisplayData()
    local avgInput60 = getAverage(60, EnergyData.inputHistory)
    local avgOutput60 = getAverage(60, EnergyData.outputHistory)

    DisplayData.stored = "Stored: " .. EnergyData.stored .. " / " .. EnergyData.max .. " EU"
    DisplayData.percent = "Percent: " .. string.format("%.3f", EnergyData.percent) .. "%"
    DisplayData.input = "Input: " .. string.format("%.0f", EnergyData.input) .. " EU/t"
    DisplayData.output = "Output: " .. string.format("%.0f", EnergyData.output) .. " EU/t"
    DisplayData.avgInput = "Average Input: " .. string.format("%.0f", avgInput60) .. " EU/t over 1m"
    DisplayData.avgOutput = "Average Output: " .. string.format("%.0f", avgOutput60) .. " EU/t over 1m"

    DisplayData.connectedBatteries = string.format("%d", #devices) .. " batter" .. (#devices > 1 and "ies" or "y") .. " connected"
    DisplayData.ramUse = "Ram Use: " .. computer.totalMemory() - computer.freeMemory() .. "/" .. computer.totalMemory()

    local powerAbs = math.abs(EnergyData.input60 - EnergyData.output60) * 20
    if EnergyData.input60 == EnergyData.output60 then
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

    if avgOutput60 > avgInput60 and EnergyData.generatorsMaxCapacity then
        table.insert(DisplayData.warnings, "WARNING: Output exceeds input")
    end

    if EnergyData.percent < 5 then
        table.insert(DisplayData.warnings, "WARNING: Low Power")
    end

    if computer.freeMemory() < 20000 then
        table.insert(DisplayData.warnings, "WARNING: Low RAM")
    end

    if screenutil.failedBind then
        table.insert(DisplayData.warnings, "Warning: Failed to bind a screen to a gpu. Not sure what this means, tell evan if you see this.")
    end

    if screenutil.screenOverload then
        table.insert(DisplayData.warnings, "WARNING: More screens present than GPUs.")
    end

    if not logicSuccess then
        table.insert(DisplayData.warnings, "WARNING: Failed to obtain battery data.")
    end
end

local function main()
    screenutil.fetchScreenData()
    local lastDrawTime = 0

    while true do
        local uptime = computer.uptime()

        fetchDevices()
        if #devices ~= 0 then
            logicSuccess = pcall(doLogic, uptime)
        end

        if uptime - lastDrawTime >= drawRate then
            updateDisplayData()
            screenutil.drawScreens(DisplayData)
            lastDrawTime = uptime
        end

        if keyboard.isShiftDown() then
            return
        end

        os.sleep(logicRate)
    end
end

local success, err = pcall(main)

screenutil.resetBindings()

if not success then
    print("Encountered an error, consult Evan\n" .. os.date() .. "\n" .. err)
end