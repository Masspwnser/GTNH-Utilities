
local os = require("os")
local keyboard = require("keyboard")
local component = require("component")
local computer = require("computer")

local gpu = component.gpu
gpu.setResolution(60,18)
local w, h = gpu.getResolution()

local tickRate = 0.05 -- Minecraft tickrate in seconds

local logicRate = tickRate -- Frequency to poll power data
local drawRate = 1 -- Arbitrary display update rate in seconds
local dataDecay = 900 -- Data decays after 5 mins to ensure ram isnt filled

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
    timeUntilGeneric = 0, -- time until blank = "empty", "full", "generators on"
    timeUntilString = "",
    generatorsMaxCapacity = false, -- generators on (polar), generators max capacity (scaling/backup), always (constant)
    thresholdForGenerators = 0, -- power threshold for when generators turn on
    peakInput = 0,
}

local function center(text)
    local len = string.len(text)
    return math.abs((len / 2) - (w / 2))
end

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

    local powerAbs = math.abs(EnergyData.input60 - EnergyData.output60) * 20
    if EnergyData.input60 == EnergyData.output60 then
        EnergyData.timeUntilString = "nil"
        EnergyData.timeUntilGeneric = 0
    elseif EnergyData.input60 > EnergyData.output60 then
        EnergyData.timeUntilString = "Time until full:"
        EnergyData.timeUntilGeneric = (EnergyData.max - EnergyData.stored) / powerAbs
    elseif not EnergyData.generatorsMaxCapacity and EnergyData.thresholdForGenerators < EnergyData.stored then
        EnergyData.timeUntilString = "Time until generators on:"
        EnergyData.timeUntilGeneric = (EnergyData.stored - EnergyData.thresholdForGenerators) / powerAbs
    elseif EnergyData.generatorsMaxCapacity and EnergyData.output60 > EnergyData.input60 then
        EnergyData.timeUntilString = "Time until empty:"
        EnergyData.timeUntilGeneric = EnergyData.stored / powerAbs
    else
        EnergyData.timeUntilString = "bad logic, consult evan"
        EnergyData.timeUntilGeneric = 0
    end
end

local function drawScreen(logicSuccess)
    gpu.fill(1, 2, w, h, " ")

    if not logicSuccess then
        gpu.set(1, 3, "WARNING: Failed to obtain battery data.")
        return
    end

    local avgInput60 = getAverage(60, EnergyData.inputHistory)
    local avgOutput60 = getAverage(60, EnergyData.outputHistory)

    gpu.set(1, 3, "Stored: " .. EnergyData.stored .. " / " .. EnergyData.max .. " EU")
    gpu.set(1, 4, "Percent: " .. string.format("%.3f", EnergyData.percent) .. "%")
    gpu.set(1, 5, "Input: " .. string.format("%.0f", EnergyData.input) .. " EU/t")
    gpu.set(1, 6, "Output: " .. string.format("%.0f", EnergyData.output) .. " EU/t")

    gpu.set(1, 7, "Average Input: " .. string.format("%.0f", avgInput60) .. " EU/t over 1m")
    gpu.set(1, 8, "Average Output: " .. string.format("%.0f", avgOutput60) .. " EU/t over 1m")

    if EnergyData.timeUntilGeneric ~= 0 then
      gpu.set(1, 9, EnergyData.timeUntilString .. " " .. secondsToString(EnergyData.timeUntilGeneric))
    end

    if avgOutput60 > avgInput60 and EnergyData.generatorsMaxCapacity then
        gpu.set(1, 12, "WARNING: Output exceeds input")
    end

    if EnergyData.percent < 5 then
        gpu.set(1, 13, "WARNING: Low Power")
    end

    if computer.freeMemory() < 20000 then
        gpu.set(1, 14, "WARNING: Low RAM")
    end

    gpu.set(1, h-1, string.format("%d", #devices) .. " batter" .. (#devices > 1 and "ies" or "y") .. " connected")
    gpu.set(1, h, "Ram Use: " .. computer.totalMemory() - computer.freeMemory() .. "/" .. computer.totalMemory())
end

local function main()
    local lastDrawTime = 0

    while true do
        local uptime = computer.uptime()
        local logicSuccess = false

        fetchDevices()
        if #devices ~= 0 then
            logicSuccess = pcall(doLogic, uptime)
        end

        if uptime - lastDrawTime >= drawRate then
            drawScreen(logicSuccess)
            lastDrawTime = uptime
        end

        if keyboard.isShiftDown() then
            return
        end

        os.sleep(logicRate)
    end
end

gpu.fill(1, 1, w, h, " ")

local title = "Evan's Power Monitor V1.1"
gpu.set(center(title), 1, title)

local success, err = pcall(main)
gpu.fill(1, 1, w, h, " ")

if not success then
    print("Encountered an error, consult Evan\n" .. os.date() .. "\n\n" .. err)
end