--[[--
Power-button rescue: hold the power button for 3 seconds to stop whatever
KOReader started (apps, audio) and, if KOReader itself is frozen, restart it.
The power-off hold moves from 2 to 6 seconds.

A frozen main loop cannot see its own key presses, so the actual watching is
done by powerwatch.sh, a small shell daemon reading the power key from evdev.
This plugin starts that daemon and stamps a heartbeat file whenever KOReader
handles a power press, so the daemon can tell a frozen KOReader from a
working one.
--]]

local Device = require("device")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local _ = require("gettext")

local HEARTBEAT = "/tmp/powerwatch.heartbeat"
-- Left by powerwatch.sh when it had to restart a frozen KOReader.
local RESCUED = "/tmp/powerwatch.rescued"
local PIDFILE = "/tmp/powerwatch.pid"
local LOG = "/tmp/powerwatch.log"

local PowerWatch = WidgetContainer:extend{
    name = "powerwatch",
    is_doc_only = false,
}

local function stamp()
    local f = io.open(HEARTBEAT, "w")
    if f then
        f:write(os.time(), "\n")
        f:close()
    end
end

local function daemonRunning()
    local f = io.open(PIDFILE, "r")
    if not f then return false end
    local pid = tonumber(f:read("*l"))
    f:close()
    if not pid then return false end
    local cmd = io.open("/proc/" .. pid .. "/cmdline", "r")
    if not cmd then return false end
    local line = cmd:read("*a") or ""
    cmd:close()
    return line:find("powerwatch.sh", 1, true) ~= nil
end

local HOLD_SECS = 3
-- KOReader powers off on a 2 s hold; move that past the rescue hold.
local POWEROFF_SECS = 6

local pressed_at

-- Leave the book for the library.
local function returnToMenu()
    local ReaderUI = require("apps/reader/readerui")
    if ReaderUI.instance then
        ReaderUI.instance:onHome()
    end
end

local function rescue()
    local InfoMessage = require("ui/widget/infomessage")
    returnToMenu()
    UIManager:show(InfoMessage:new{
        text = _("Power-button rescue: stopped running tasks."),
        timeout = 3,
    })
end

local function wrapHandlers()
    local press = UIManager.event_handlers.PowerPress
    local release = UIManager.event_handlers.PowerRelease
    if not press or not release or UIManager._powerwatch_wrapped then return end
    UIManager._powerwatch_wrapped = true
    UIManager.event_handlers.PowerPress = function(...)
        stamp()
        pressed_at = os.time()
        local ret = press(...)
        UIManager:unschedule(UIManager.poweroff_action)
        UIManager:scheduleIn(POWEROFF_SECS, UIManager.poweroff_action)
        return ret
    end
    UIManager.event_handlers.PowerRelease = function(...)
        stamp()
        local held = pressed_at and os.time() - pressed_at or 0
        pressed_at = nil
        if held >= HOLD_SECS and not UIManager._entered_poweroff_stage then
            -- A rescue hold: the watchdog handles it, so don't also go to sleep.
            UIManager:unschedule(UIManager.poweroff_action)
            logger.info("PowerWatch: rescue hold, returning to the menu")
            rescue()
            return
        end
        return release(...)
    end
end

function PowerWatch:init()
    if not Device:isKobo() then return end
    -- The handlers are installed by the device before plugins load.
    wrapHandlers()
    stamp()
    if os.remove(RESCUED) and self.ui.document then
        -- KOReader was restarted by the watchdog and reopened the last book.
        UIManager:nextTick(rescue)
    end
    if G_reader_settings:nilOrTrue("powerwatch_enabled") then
        self:startDaemon()
    end
    self.ui.menu:registerToMainMenu(self)
end

function PowerWatch:startDaemon()
    if daemonRunning() then return end
    local script = self.path .. "/powerwatch.sh"
    os.execute(string.format("setsid sh '%s' >/dev/null 2>&1 </dev/null &", script))
    logger.info("PowerWatch: started", script)
end

function PowerWatch:stopDaemon()
    local f = io.open(PIDFILE, "r")
    if not f then return end
    local pid = tonumber(f:read("*l"))
    f:close()
    if pid and daemonRunning() then
        -- setsid made it a group leader: kill it with its dd/od pipeline.
        os.execute("kill -- -" .. pid)
    end
    os.remove(PIDFILE)
end

function PowerWatch:onResume()
    stamp()
end

function PowerWatch:addToMainMenu(menu_items)
    menu_items.powerwatch = {
        text = _("Power-button rescue"),
        sorting_hint = "device",
        sub_item_table = {
            {
                text = _("Hold power 3 s to stop a frozen task"),
                checked_func = function()
                    return G_reader_settings:nilOrTrue("powerwatch_enabled")
                end,
                callback = function()
                    local on = not G_reader_settings:nilOrTrue("powerwatch_enabled")
                    G_reader_settings:saveSetting("powerwatch_enabled", on)
                    if on then self:startDaemon() else self:stopDaemon() end
                end,
            },
            {
                text = _("Watchdog status"),
                keep_menu_open = true,
                callback = function()
                    local InfoMessage = require("ui/widget/infomessage")
                    local tail = ""
                    local p = io.popen("tail -n 5 " .. LOG .. " 2>/dev/null")
                    if p then tail = p:read("*a") or ""; p:close() end
                    UIManager:show(InfoMessage:new{
                        text = (daemonRunning() and _("Watchdog is running.") or _("Watchdog is not running."))
                            .. (tail ~= "" and ("\n\n" .. tail) or ""),
                    })
                end,
            },
        },
    }
end

return PowerWatch
