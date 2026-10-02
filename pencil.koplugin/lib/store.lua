--[[--
The plugin's stroke store (`pencil_strokes.lua`): versions, stable group ids,
and the upgrade from older files. Pure functions.

Version 4 (this fork):
- group ids come from the group's first stroke (its time and first point),
  so they never change when groups are rebuilt after an erase or undo;
- each stroke may carry an `anchor` (see lib/anchor), recorded when drawn;
- a group's `xpointer` comes from its strokes' anchors.

@module pencil.lib.store
--]]--

local Store = {}

Store.VERSION = 4

--- The earliest stroke of a group (by time, then by index), or nil.
function Store.firstStroke(group, strokes)
    local best, best_idx
    for _, idx in ipairs(group.stroke_indices or {}) do
        local s = strokes[idx]
        if s and (not best
                or (s.datetime or 0) < (best.datetime or 0)
                or ((s.datetime or 0) == (best.datetime or 0) and idx < best_idx)) then
            best, best_idx = s, idx
        end
    end
    return best
end

--- A group id that depends only on the stroke it starts with.
function Store.groupId(stroke)
    local p = stroke and stroke.points and stroke.points[1]
    local when = os.date("!%Y%m%d%H%M%S", stroke and stroke.datetime or 0)
    if not p then
        return "pencil_" .. when
    end
    return string.format("pencil_%s_%d_%d", when, math.floor(p.x), math.floor(p.y))
end

--- The XPointer that places a group: the anchor of its earliest anchored
-- stroke, or nil.
function Store.groupXPointer(group, strokes)
    local best
    for _, idx in ipairs(group.stroke_indices or {}) do
        local s = strokes[idx]
        if s and s.anchor and s.anchor.xpointer
                and (not best or (s.datetime or 0) < (best.datetime or 0)) then
            best = s
        end
    end
    return best and best.anchor.xpointer
end

--- Upgrades a loaded file (any version) to the current one, in place:
-- groups get stable ids (their old id kept as `legacy_id`). Strokes from
-- older versions have no anchors; they get one when their page is shown
-- again in the layout they were drawn in. Returns the data.
function Store.upgrade(data)
    local from = data.version or 1
    if from >= Store.VERSION then
        return data
    end
    for _, group in ipairs(data.annotation_groups or {}) do
        local first = Store.firstStroke(group, data.strokes or {})
        if first then
            local id = Store.groupId(first)
            if group.id ~= id then
                group.legacy_id = group.legacy_id or group.id
                group.id = id
            end
        end
    end
    data.upgraded_from = from
    data.version = Store.VERSION
    return data
end

--- Whether a rebuilt group is the same as an old one (so its saved image is
-- still right): same id, same number of strokes, same box.
function Store.sameGroup(old, new)
    if not old or not new or old.id ~= new.id then return false end
    if #(old.stroke_indices or {}) ~= #(new.stroke_indices or {}) then return false end
    local a, b = old.bbox, new.bbox
    return a and b and a.x0 == b.x0 and a.y0 == b.y0 and a.x1 == b.x1 and a.y1 == b.y1 or false
end

return Store
