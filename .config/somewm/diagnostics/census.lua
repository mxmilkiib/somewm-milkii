-- Walks everything reachable from the registry; reports the largest tables by entry count with a path.
local seen, queue, qh = {}, {}, 1
local counts = { table = 0, ["function"] = 0, userdata = 0, thread = 0, string = 0 }
local big = {}
local function push(v, path)
    local t = type(v)
    if t == "table" or t == "function" or t == "userdata" or t == "thread" then
        if not seen[v] then
            seen[v] = true
            queue[#queue + 1] = { v, path }
        end
    end
end
push(debug.getregistry(), "REG")
push(_G, "_G")
local function short(k)
    local s = tostring(k)
    if #s > 40 then s = s:sub(1, 40) end
    return s
end
while qh <= #queue do
    local item = queue[qh]; queue[qh] = false; qh = qh + 1
    local v, path = item[1], item[2]
    local t = type(v)
    counts[t] = counts[t] + 1
    if #path > 160 then path = path:sub(1, 160) end
    if t == "table" then
        local n = 0
        local mt = getmetatable(v)
        local weakk, weakv = false, false
        if type(mt) == "table" then
            local m = rawget(mt, "__mode")
            if m then weakk = m:find("k") ~= nil; weakv = m:find("v") ~= nil end
            push(mt, path .. ".<mt>")
        end
        for k, x in next, v do
            n = n + 1
            if not weakk then push(k, path .. ".<key>") end
            if not weakv then push(x, path .. "." .. short(k)) end
        end
        if n > 2000 then big[#big + 1] = { n, path } end
    elseif t == "function" then
        local i = 1
        while true do
            local name, val = debug.getupvalue(v, i)
            if not name then break end
            push(val, path .. "^" .. name)
            i = i + 1
        end
        push(debug.getfenv and debug.getfenv(v) or nil, path .. ".<env>")
    elseif t == "userdata" then
        local mt = getmetatable(v)
        if type(mt) == "table" then push(mt, path .. ".<mt>") end
        if debug.getfenv then local e = debug.getfenv(v); if e then push(e, path .. ".<uenv>") end end
    elseif t == "thread" then
        for lvl = 0, 30 do
            local info = debug.getinfo(v, lvl, "f")
            if not info then break end
            push(info.func, path .. ".<co" .. lvl .. ">")
        end
    end
end
table.sort(big, function(a, b) return a[1] > b[1] end)
local out = { string.format("tables=%d functions=%d userdata=%d threads=%d  lua_kb=%.0f", counts.table, counts["function"], counts.userdata, counts.thread, collectgarbage("count")) }
for i = 1, math.min(25, #big) do out[#out + 1] = string.format("%8d  %s", big[i][1], big[i][2]) end
local f = io.open(os.getenv("HOME") .. "/.local/share/somewm-diag/census.log", "a")
f:write(os.date("== %Y-%m-%d %H:%M:%S\n"), table.concat(out, "\n"), "\n")
f:close()
return "done"
