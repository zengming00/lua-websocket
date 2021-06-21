--[[
lua-copas	    2.0.2-1
lua-coxpcall	1.17.0-1
luabitop	    1.0.2-1
luasocket	    2019-04-21-733af884-1
lua	            5.1.5-8
--]] --
local copas = require('copas')
local socket = require('socket')
local bit = require('bit')
local sha = require('sha2')

local rshift, lshift, band = bit.rshift, bit.lshift, bit.band
local bxor, bor = bit.bxor, bit.bor
local b = string.byte

local function binToUint16Le(s) return b(s, 1) + lshift(b(s, 2), 8) end
local function binToUint16Be(s) return lshift(b(s, 1), 8) + b(s, 2) end

local function tabToStr(list)
    local tmp = {}
    for index, value in ipairs(list) do tmp[#tmp + 1] = string.char(value) end
    return table.concat(tmp)
end

local function strToTab(s)
    local tmp = {}
    for i = 1, #s, 1 do tmp[#tmp + 1] = s:byte(i) end
    return tmp
end

local function hexdump(s)
    local t = strToTab(s)
    local str = {
        '1', '2', '3', '4', '5', '6', '7', '8', '9', --
        'A', 'B', 'C', 'D', 'E', 'F'
    }
    str[0] = '0'
    for i, v in ipairs(t) do t[i] = str[rshift(v, 4)] .. str[band(v, 0xF)] end
    print(table.concat(t, ','))
end

local function readWebSocketMessageHeader(c)
    local v = assert(c:receive(2)) -- v的大小为两个字节
    v = binToUint16Le(v)
    return {
        opcode = band(v, 0xF), -- 4 bit
        rsv = band(rshift(v, 4), 0x7), -- 3 bit
        fin = band(rshift(v, 7), 0x1), -- 1 bit
        payloadLength = band(rshift(v, 8), 0x7f), -- 7 bit
        mask = band(rshift(v, 15), 0x1) -- 1 bit
    }
end

local function writeWebSocketMessageHeader(c, header)
    local opcode = band(header.opcode, 0xF) -- 4 bit
    local rsv = lshift(band(header.rsv, 0x7), 4) -- 3 bit
    local fin = lshift(band(header.fin, 0x1), 7) -- 1 bit

    local payloadLength = band(header.payloadLength, 0x7f) -- 7 bit
    local mask = lshift(band(header.mask, 0x1), 7) -- 1 bit
    local data = tabToStr {bor(opcode, rsv, fin), bor(payloadLength, mask)}
    assert(c:send(data))
end

function WebSocketMessageUnmaskPayload(payload, mask)
    local t1 = strToTab(payload)
    local t2 = strToTab(mask)
    for i = 1, #t1 do t1[i] = bxor(t1[i], t2[(i - 1) % 4 + 1]) end
    return tabToStr(t1)
end

local function readWebSocketMessage(c, header)
    local num = 2 -- 消息的总大小
    local payloadLength = header.payloadLength
    if payloadLength == 127 then
        -- local v = assert(c:receive(8)) -- uint64
        -- num = num + 8 + ntoh64(v)
        -- 暂不支持过大的消息(超过65535字节)
        return nil, 'header.payloadLength == 127'

    elseif payloadLength == 126 then
        local v = assert(c:receive(2)) -- uint16
        payloadLength = binToUint16Be(v)
        print('header.payloadLength == 126: ', payloadLength)
        num = num + 2 + payloadLength
    else
        num = num + payloadLength
    end

    local mask
    if header.mask == 1 then
        num = num + 4
        print("mask payload")
        mask = assert(c:receive(4))
    end
    local payload = assert(c:receive(payloadLength))
    if header.mask == 1 then
        payload = WebSocketMessageUnmaskPayload(payload, mask)
        print(payload)
    end
    return {num = num, payload = payload, payloadLength = payloadLength}
end

function SendWebSocketMessage(c, data)
    local header = {
        opcode = 0x02, -- 4 bit
        rsv = 0, -- 3 bit
        fin = 1, -- 1 bit
        payloadLength = 0, -- 7 bit
        mask = 0 -- 1 bit
    }
    local payloadLength = #data
    if payloadLength < 126 then
        print("---126")
        header.payloadLength = payloadLength
        writeWebSocketMessageHeader(c, header)
        assert(c:send(data))

    elseif payloadLength <= 65535 then
        print("---65535", payloadLength)
        header.payloadLength = 126
        writeWebSocketMessageHeader(c, header)
        local t = {rshift(payloadLength, 8), band(payloadLength, 0xff)}
        -- local t = {band(payloadLength, 0xff), rshift(payloadLength, 8)}
        assert(c:send(tabToStr(t)))
        assert(c:send(data))

    elseif payloadLength > 65535 then
        print("send message too long, max message length is 65535")
        return nil
    end
end

local function handler(host, port)
    local skt = socket.connect(host, port)
    skt:settimeout(0) -- important: make it non-blocking

    local c = copas.wrap(skt)
    local key = 'FUlPm8DgS00JN1dxsQapFg==' -- 16 byte
    local header = {
        'GET /t HTTP/1.1\r\n', --
        'Host: ' .. host .. ':' .. port .. '\r\n', --
        'Connection: Upgrade\r\n', --
        'Upgrade:websocket\r\n', --
        'Sec-WebSocket-Key: ' .. key .. '\r\n', --
        'Sec-WebSocket-Version: 13\r\n', --
        '\r\n'
    }
    assert(c:send(table.concat(header)))

    local line = assert(c:receive("*l"))
    while line ~= "" do
        print('"' .. line .. '"')
        line = assert(c:receive("*l"))
    end

    SendWebSocketMessage(c, "hello")
    
    while true do
        local header = readWebSocketMessageHeader(c)
        local m = assert(readWebSocketMessage(c, header))
        print(m.num, m.payloadLength)

        if header.opcode == 0x02 then -- binary frame
            print("[opcode]binary frame")
            hexdump(m.payload)
            SendWebSocketMessage(c, m.payload)

        elseif header.opcode == 0x01 then -- text frame
            print("[opcode]text frame", m.payload)
            SendWebSocketMessage(c, m.payload)

        elseif header.opcode == 0x08 then -- connection close
            print("[opcode]connection close")
        elseif header.opcode == 0x09 then -- ping
            print("[opcode]ping")
        elseif header.opcode == 0x0A then -- pong
            print("[opcode]pong")
        elseif header.opcode == 0x00 then -- continuation frame
            print("[opcode]continuation frame")
        else -- reserved
            print("[opcode]reserved: " .. header.opcode)
        end
        print('---------------------------')
    end
end

local host = "192.168.11.1"
local port = 8888
copas.addthread(handler, host, port)
copas.loop()

