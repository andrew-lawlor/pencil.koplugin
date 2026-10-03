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
                if d >= 10 then
                    logger.info(string.format("%s timing: Screen:%s %sx%s took %d ms%s", label, name,
                        tostring(w), tostring(h), d,
                        stroke and string.format(" (during a stroke, point %d)", stroke.points) or ""))
                end
                return a, b
            end
        end
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
