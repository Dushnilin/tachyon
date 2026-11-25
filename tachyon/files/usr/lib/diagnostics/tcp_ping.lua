#!/usr/bin/env lua
local ok_s, socket = pcall(require, "socket")
local ok_j, json = pcall(require, "luci.jsonc")
if not ok_s or not ok_j then
    print('{"error":"missing socket or luci.jsonc dependencies"}')
    return
end

local mode = arg[1]

if mode == "single" then
    local host = arg[2]
    local port = tonumber(arg[3])
    local timeout_ms = tonumber(arg[4]) or 2000
    if not host or not port then
        print(json.stringify({ error = "host and port required" }))
        return
    end
    local s = socket.tcp()
    s:settimeout(timeout_ms / 1000.0)
    local t0 = socket.gettime()
    local ok, err = s:connect(host, port)
    local dt = math.floor((socket.gettime() - t0) * 1000)
    s:close()
    if ok then
        print(json.stringify({ delay = dt }))
    else
        print(json.stringify({ error = err or "timeout" }))
    end
    return
end

if mode == "batch" then
    local input_path = arg[2]
    local timeout_ms = tonumber(arg[3]) or 2000
    local content = nil
    if input_path then
        local f = io.open(input_path, "r")
        if f then
            content = f:read("*all")
            f:close()
        end
    end
    if not content or content == "" then
        print(json.stringify({ results = {} }))
        return
    end
    local targets = json.parse(content)
    if not targets or type(targets) ~= "table" then
        print(json.stringify({ results = {} }))
        return
    end

    local timeout_sec = timeout_ms / 1000.0
    local t_start = socket.gettime()
    local conns = {}
    for _, tgt in ipairs(targets) do
        if tgt.server and tgt.port and tgt.tag then
            local s = socket.tcp()
            s:settimeout(0)
            local t0 = socket.gettime()
            s:connect(tgt.server, tonumber(tgt.port))
            table.insert(conns, { s = s, t0 = t0, tag = tgt.tag, done = false })
        end
    end

    local remaining = #conns
    while remaining > 0 and (socket.gettime() - t_start) < timeout_sec do
        local write_set = {}
        for _, c in ipairs(conns) do
            if not c.done then table.insert(write_set, c.s) end
        end
        if #write_set == 0 then break end
        local _, ready = socket.select(nil, write_set, 0.03)
        if ready then
            for _, s in ipairs(ready) do
                for _, c in ipairs(conns) do
                    if c.s == s and not c.done then
                        local peer = s:getpeername()
                        local dt = math.floor((socket.gettime() - c.t0) * 1000)
                        c.done = true
                        remaining = remaining - 1
                        if peer then
                            c.delay = dt
                        end
                    end
                end
            end
        end
    end

    local results = {}
    for _, c in ipairs(conns) do
        c.s:close()
        if c.delay and c.delay > 0 then
            results[c.tag] = c.delay
        end
    end

    print(json.stringify({ results = results }))
    return
end

print(json.stringify({ error = "usage: tcp_ping.lua <single|batch> ..." }))
