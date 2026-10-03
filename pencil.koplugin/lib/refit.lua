--[[--
Marks that follow their words: an underline or a circle records which words
it marks, so on another layout (a font change) it can be drawn again under
or around those words, wherever they are now, and however they wrap.

Shapes are told apart as Kollate does: an underline is one long, flat
stroke; a circle a stroke around whole words. The mark is drawn again from
the reader's own stroke, stretched to fit, so it still looks hand-drawn.

Pure, so it can be tested without KOReader. Boxes are {x0, y0, x1, y1}.

@module pencil.lib.refit
--]]--

local Refit = {}

local function across(box, left, right)
    local w = math.max(box[3] - box[1], 1)
    return math.max(0, math.min(box[3], right) - math.max(box[1], left)) / w
end

--- What a stroke whose box is `bbox` marks among the page's `words`
-- (lib/words: { text, boxes, pos0, pos1 }), or nil when it isn't a mark:
-- { kind = "underline" | "circle", pos0, pos1 } and how it sits: an
-- underline's distance below the text and a circle's padding around it,
-- in line heights.
function Refit.markOf(bbox, words)
    if not bbox or not words or #words == 0 then return nil end
    local w, h = bbox.x1 - bbox.x0, bbox.y1 - bbox.y0
    local first, last, line_box
    if w >= 150 and h <= 0.12 * w then
        -- The line whose bottom is nearest, among those starting above it.
        local mid = (bbox.y0 + bbox.y1) / 2
        for _, word in ipairs(words) do
            for _, b in ipairs(word.boxes) do
                if b[2] < mid and (not line_box or math.abs(b[4] - mid) < math.abs(line_box[4] - mid)) then
                    line_box = b
                end
            end
        end
        if not line_box then return nil end
        local centre = (line_box[2] + line_box[4]) / 2
        for k, word in ipairs(words) do
            for _, b in ipairs(word.boxes) do
                if b[2] <= centre and centre <= b[4] and across(b, bbox.x0 - 12, bbox.x1 + 12) > 0.5 then
                    first = first or k
                    last = k
                end
            end
        end
        if not first then return nil end
        local line = line_box[4] - line_box[2]
        return {
            kind = "underline",
            pos0 = words[first].pos0, pos1 = words[last].pos1,
            below = math.floor((mid - line_box[4]) / line * 1000 + 0.5) / 1000,
        }
    end
    if w >= 40 and h >= 20 then
        local inside
        for k, word in ipairs(words) do
            for _, b in ipairs(word.boxes) do
                local cy = (b[2] + b[4]) / 2
                if bbox.y0 <= cy and cy <= bbox.y1 and across(b, bbox.x0, bbox.x1) > 0.6 then
                    first = first or k
                    last = k
                    inside = inside and {
                        math.min(inside[1], b[1]), math.min(inside[2], b[2]),
                        math.max(inside[3], b[3]), math.max(inside[4], b[4]),
                    } or { b[1], b[2], b[3], b[4] }
                end
            end
        end
        if not first then return nil end
        local line = inside[4] - inside[2]
        local function r(v) return math.floor(v / line * 1000 + 0.5) / 1000 end
        return {
            kind = "circle",
            pos0 = words[first].pos0, pos1 = words[last].pos1,
            pad = { r(inside[1] - bbox.x0), r(inside[2] - bbox.y0), r(bbox.x1 - inside[3]), r(bbox.y1 - inside[4]) },
        }
    end
    return nil
end

-- `points` ({x, y} pairs) moved from the box `from` to the box `to`,
-- stretched to fit.
local function stretch(points, from, to)
    local sx = (to[3] - to[1]) / math.max(from[3] - from[1], 1)
    local sy = (to[4] - to[2]) / math.max(from[4] - from[2], 1)
    local out = {}
    for i, p in ipairs(points) do
        out[i] = { x = to[1] + (p.x - from[1]) * sx, y = to[2] + (p.y - from[2]) * sy }
    end
    return out
end

--- The mark drawn again on another layout: `points` (the stroke as
-- written, {x, y} pairs, inside `bbox`) fitted to `lines`, the marked
-- words' box on each line they're on now. Returns a list of point lists,
-- one per line: an underline under each, a circle around each.
function Refit.fit(mark, points, bbox, lines)
    local from = { bbox.x0, bbox.y0, bbox.x1, bbox.y1 }
    local out = {}
    for _, l in ipairs(lines) do
        local line = l[4] - l[2]
        local to
        if mark.kind == "underline" then
            local y = l[4] + (mark.below or 0.15) * line
            local half = math.max((bbox.y1 - bbox.y0) / 2, 1)
            to = { l[1], y - half, l[3], y + half }
        else
            local pad = mark.pad or { 0.2, 0.2, 0.2, 0.2 }
            to = { l[1] - pad[1] * line, l[2] - pad[2] * line, l[3] + pad[3] * line, l[4] + pad[4] * line }
        end
        table.insert(out, stretch(points, from, to))
    end
    return out
end

return Refit
