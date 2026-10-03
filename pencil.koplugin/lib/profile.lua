--[[--
Profiling for trials on a device: times the plugin's functions and logs
what could hold up the pen. Off unless a build turns it on.

Per stroke it logs the number of points, the longest gap between two
points (the pen reports every few milliseconds, so a long gap means
KOReader was busy and the ink fell behind), and the time spent drawing
points and finishing the stroke. Any other wrapped function slower than
THRESHOLD_MS is logged with its time.

@module pencil.lib.profile
--]]--

local logger = require("logger")
local time = require("ui/time")

local Profile = {}

local THRESHOLD_MS = 15
-- For this long after a book opens, everything is traced: every screen
-- update, repaint request, slow timer run and input gesture.
local TRACE_S = 120

-- Functions timed on their own (if the plugin has them).
local SLOW = {
    "paintTo", "saveStrokes", "captureGroupImage", "capturePage", "syncMarkups",
    "backfillGroupXPointers", "backfillMissingImages", "rebuildAnnotationGroups",
    "assignStrokeToGroup", "flushDeferredWork", "onPageUpdate", "attachPageCapture",
    "renderStroke",
}

function Profile.install(class, label)
    label = label or "Pencil"
    local stroke = nil
    local function ms(t) return time.to_ms(time.now() - t) end
    -- The trace window starts when a book is ready.
    local opened = nil
    local function tracing()
        return opened and time.to_s(time.now() - opened) < TRACE_S
    end
    local function stamp()
        return opened and string.format("+%.3fs", time.to_s(time.now() - opened)) or "+?"
    end
    local ready = class.onReaderReady
    if ready then
        class.onReaderReady = function(self, ...)
            opened = time.now()
            logger.info(string.format("%s trace: book ready, tracing %d s", label, TRACE_S))
            return ready(self, ...)
        end
    end
    local function where(fn)
        local info = type(fn) == "function" and debug.getinfo(fn, "S")
        return info and string.format("%s:%d", info.short_src:match("[^/]*/?[^/]*$") or info.short_src, info.linedefined) or "?"
    end

    local start = class.startRawStroke
    if start then
        class.startRawStroke = function(self, ...)
            stroke = { points = 0, draw_ms = 0, max_draw = 0, worst_at = 0, last = time.now(), max_gap = 0, t0 = time.now() }
            return start(self, ...)
        end
    end
    local add = class.addRawPoint
    if add then
        class.addRawPoint = function(self, ...)
            local t = time.now()
            if stroke then
                local gap = time.to_ms(t - stroke.last)
                if stroke.points > 0 and gap > stroke.max_gap then stroke.max_gap = gap end
            end
            local r = add(self, ...)
            if stroke then
                local d = ms(t)
                stroke.points = stroke.points + 1
                stroke.draw_ms = stroke.draw_ms + d
                if d > stroke.max_draw then stroke.max_draw = d; stroke.worst_at = stroke.points end
                stroke.last = time.now()
            end
            return r
        end
    end
    local finish = class.endRawStroke
    if finish then
        class.endRawStroke = function(self, ...)
            local t = time.now()
            local r = finish(self, ...)
            if stroke then
                logger.info(string.format(
                    "%s timing: stroke %d points over %d ms, longest gap %d ms, drawing %d ms (worst point %d ms, point %d), finishing %d ms",
                    label, stroke.points, time.to_ms(t - stroke.t0), stroke.max_gap,
                    stroke.draw_ms, stroke.max_draw, stroke.worst_at, ms(t)))
            end
            stroke = nil
            return r
        end
    end
    -- Screen refreshes: an e-ink update can block until an earlier one ends.
    local Screen = require("device").screen
    for _, name in ipairs({ "refreshUI", "refreshFast", "refreshPartial", "refreshFull", "refreshFlash" }) do
        local f = Screen[name]
        if type(f) == "function" then
            Screen[name] = function(scr, x, y, w, h, ...)
                local t = time.now()
                local a, b = f(scr, x, y, w, h, ...)
                local d = ms(t)
                local tiny = (tonumber(w) or 9999) <= 64 and (tonumber(h) or 9999) <= 64
                if d >= 10 or (tracing() and not (stroke and tiny)) then
                    logger.info(string.format("%s timing: %s Screen:%s %sx%s at %s,%s took %d ms%s", label, stamp(), name,
                        tostring(w), tostring(h), tostring(x), tostring(y), d,
                        stroke and string.format(" (during a stroke, point %d)", stroke.points) or ""))
                end
                return a, b
            end
        end
    end
    -- Anything asking for a repaint while the pen is down, and from where.
    local UIManager = require("ui/uimanager")
    local set_dirty = UIManager.setDirty
    UIManager.setDirty = function(um, widget, refreshtype, region, ...)
        if stroke or tracing() then
            local info = debug.getinfo(2, "Sl")
            local mode = type(refreshtype) == "function" and "deferred" or tostring(refreshtype)
            logger.info(string.format("%s timing: %s repaint requested%s, mode %s, region %s, widget %s, from %s:%s",
                label, stamp(), stroke and string.format(" during a stroke (point %d)", stroke.points) or "",
                mode, region and string.format("%dx%d", region.w or 0, region.h or 0) or "whole",
                widget and (widget.name or widget.id or "?") or "nil",
                info and info.short_src or "?", info and info.currentline or "?"))
        end
        return set_dirty(um, widget, refreshtype, region, ...)
    end
    -- Timers: which ran, and how long the loop took, when it took long.
    local check = UIManager._checkTasks
    UIManager._checkTasks = function(um, ...)
        local due = {}
        if tracing() then
            local now = time.now()
            for _, task in ipairs(um._task_queue or {}) do
                if task.time <= now then table.insert(due, where(task.action)) end
            end
        end
        local t = time.now()
        local a, b = check(um, ...)
        local d = ms(t)
        if #due > 0 and d >= 5 then
            logger.info(string.format("%s timing: %s timers took %d ms%s: %s", label, stamp(), d,
                stroke and " (during a stroke)" or "", table.concat(due, ", ")))
        end
        return a, b
    end
    -- Input: every gesture KOReader recognises while tracing (palm or pen).
    local handle = UIManager.handleInputEvent
    UIManager.handleInputEvent = function(um, ev, ...)
        if tracing() and type(ev) == "table" and ev.handler == "onGesture" then
            local ges = ev.args and ev.args[1]
            logger.info(string.format("%s timing: %s gesture %s%s", label, stamp(),
                ges and tostring(ges.ges) or "?", stroke and " (during a stroke)" or ""))
        end
        return handle(um, ev, ...)
    end
    for _, name in ipairs(SLOW) do
        local f = class[name]
        if type(f) == "function" then
            class[name] = function(...)
                local t = time.now()
                local a, b, c = f(...)
                local d = ms(t)
                if d >= THRESHOLD_MS then
                    logger.info(string.format("%s timing: %s took %d ms%s", label, name, d,
                        stroke and " (during a stroke)" or ""))
                end
                return a, b, c
            end
        end
    end
end

return Profile
