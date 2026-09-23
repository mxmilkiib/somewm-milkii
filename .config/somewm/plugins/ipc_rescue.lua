---------------------------------------------------------------------------
-- ipc_rescue.lua — Lua-side IPC listener fallback
--
-- The C listener binds $XDG_RUNTIME_DIR/somewm-socket once at startup
-- (ipc.c:ipc_init). If a nested test instance is launched without
-- SOMEWM_SOCKET, its ipc_init unlinks and rebinds that path, orphaning the
-- compositor's listener: the socket file vanishes but the compositor keeps
-- running. A bound unix socket cannot be relinked from outside, so this
-- module re-creates the listener in Lua via ffi: socket + bind + listen,
-- polled accept/read on a gears.timer, dispatching through awful.ipc.
--
-- Self-disabling: a connect probe runs first. On cold boot a connectable
-- path means a live listener owns it (this instance's own C listener binds
-- in setup() before rc.lua runs), so the module does nothing. On hot reload
-- the loop is already running, so a ping confirms the owner still answers:
-- a rescue listener left by the previous Lua state accepts but never
-- responds, and gets replaced.
---------------------------------------------------------------------------

local ok_ffi, ffi = pcall(require, "ffi")
if not ok_ffi then return end

local gears = require("gears")

ffi.cdef[[
typedef uint16_t sa_family_t;
typedef uint32_t socklen_t;
typedef long ssize_t;
struct sockaddr_un { sa_family_t sun_family; char sun_path[108]; };
int socket(int domain, int type, int protocol);
int connect(int fd, const void *addr, socklen_t len);
int bind(int fd, const void *addr, socklen_t len);
int listen(int fd, int backlog);
int accept4(int fd, void *addr, socklen_t *len, int flags);
int fcntl(int fd, int cmd, int arg);  /* non-variadic: vararg numbers don't reach va_arg */
ssize_t read(int fd, void *buf, size_t n);
ssize_t write(int fd, const void *buf, size_t n);
int close(int fd);
int unlink(const char *path);
]]

local AF_UNIX, SOCK_STREAM = 1, 1
local NONBLOCK, CLOEXEC = 0x800, 0x80000
local EAGAIN, EINTR = 11, 4
local F_SETFL, O_NONBLOCK = 4, 0x800
local MAX_LINE = 1048576

local path = os.getenv("SOMEWM_SOCKET")
    or ((os.getenv("XDG_RUNTIME_DIR") or "/run/user/1000") .. "/somewm-socket")
local fd_state = path .. ".rescue-fd"

local listener
local clients = {}  -- fd -> partial line
local subs = {}     -- fd -> true for --subscribe connections

local function sockaddr()
    local a = ffi.new("struct sockaddr_un")
    a.sun_family = AF_UNIX
    ffi.copy(a.sun_path, path)
    return a, ffi.sizeof(a)
end

local function drop(fd)
    clients[fd] = nil
    subs[fd] = nil
    ffi.C.close(fd)
end

local function pump()
    while true do
        local cfd = tonumber(ffi.C.accept4(listener, nil, nil, NONBLOCK + CLOEXEC))
        if cfd < 0 then break end
        clients[cfd] = ""
    end
    local rbuf = ffi.new("char[?]", 8192)
    for fd in pairs(clients) do
        local n = tonumber(ffi.C.read(fd, rbuf, 8192))
        local err = n < 0 and ffi.errno() or 0
        if n == 0 or (n < 0 and err ~= EAGAIN and err ~= EINTR) then
            drop(fd)
        elseif n > 0 then
            local data = clients[fd] .. ffi.string(rbuf, n)
            local pos = 1
            while true do
                local nl = data:find("\n", pos, true)
                if not nl then break end
                local cmd = data:sub(pos, nl - 1)
                pos = nl + 1
                if #cmd > 0 then
                    local resp = require("awful.ipc").dispatch(cmd, fd)
                    if resp then
                        ffi.C.write(fd, resp, #resp)
                        if resp:sub(-2) ~= "\n\n" then ffi.C.write(fd, "\n", 1) end
                    end
                end
            end
            local rest = data:sub(pos)
            if #rest > MAX_LINE then
                local msg = "ERROR Command too long\n\n"
                ffi.C.write(fd, msg, #msg)
                drop(fd)
            else
                clients[fd] = rest
            end
        end
    end
end

local function install()
    if listener then return true end
    local fd = tonumber(ffi.C.socket(AF_UNIX, SOCK_STREAM + NONBLOCK + CLOEXEC, 0))
    if fd < 0 then return false end
    ffi.C.unlink(path)
    local addr, alen = sockaddr()
    if ffi.C.bind(fd, addr, alen) ~= 0 or ffi.C.listen(fd, 10) ~= 0 then
        ffi.C.close(fd)
        return false
    end
    listener = fd

    -- close a rescue listener leaked by a previous Lua state (hot reload)
    local sf = io.open(fd_state)
    if sf then
        local stale = tonumber(sf:read("*a"))
        sf:close()
        if stale then ffi.C.close(stale) end
    end
    local wf = io.open(fd_state, "w")
    if wf then wf:write(tostring(fd)); wf:close() end

    -- subscribe/broadcast plumbing: the C hooks only know fds from the C
    -- listener, so rescue fds are tracked here alongside them
    local c_subscribe, c_broadcast, c_has = _G._ipc_subscribe, _G._ipc_broadcast, _G._ipc_has_subscribers
    _G._ipc_subscribe = function(cfd)
        subs[cfd] = true
        if c_subscribe then c_subscribe(cfd) end
    end
    _G._ipc_has_subscribers = function()
        return next(subs) ~= nil or (c_has_subs and c_has_subs()) or false
    end
    _G._ipc_broadcast = function(msg)
        if c_broadcast then c_broadcast(msg) end
        for cfd in pairs(subs) do
            if ffi.C.write(cfd, msg, #msg) < 0 then subs[cfd] = nil end
        end
    end

    gears.timer { timeout = 0.05, autostart = true, callback = pump }
    return true
end

-- probe the existing socket; install only if the path has no live owner
local fd = tonumber(ffi.C.socket(AF_UNIX, SOCK_STREAM + CLOEXEC, 0))
local addr, alen = sockaddr()
if fd >= 0 and ffi.C.connect(fd, addr, alen) == 0 then
    if not awesome.somewm_ready then
        -- Cold boot: the event loop isn't running yet, so nobody could answer
        -- a ping -- connect() succeeding is proof enough of a live owner.
        -- (awesome.startup also reports true during hot reload, so it cannot
        -- distinguish the two cases.)
        ffi.C.close(fd)
    else
        -- Hot reload: the loop runs, so a ping distinguishes a healthy C
        -- listener from a zombie rescue listener of the previous Lua state.
        ffi.C.write(fd, "ping\n", 5)
        ffi.C.fcntl(fd, F_SETFL, O_NONBLOCK)
        gears.timer {
            timeout = 0.3, autostart = true, single_shot = true,
            callback = function()
                local b = ffi.new("char[?]", 256)
                local n = tonumber(ffi.C.read(fd, b, 256))
                ffi.C.close(fd)
                if not (n > 0 and ffi.string(b, n):find("PONG", 1, true)) then
                    install()
                end
            end,
        }
    end
else
    if fd >= 0 then ffi.C.close(fd) end
    install()
end
