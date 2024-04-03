local os = require("os")

local Logger = {}
local file

function Logger.enableLogging()
    local fileName = "logging/log.txt"
    file = io.open(fileName, "w")
end

function Logger.log(text)
    if file then
        file:write(string.format("%.9f", os.clock()) .. ":\t" .. text .. "\n")
    end
end

function Logger.read(numLines)
    if file then
        file:seek("end", numLines * -1)
        return(file:read("*a"))
    end
    return("")
end

function Logger.close()
    if file then
        file:close()
    end
end

return Logger