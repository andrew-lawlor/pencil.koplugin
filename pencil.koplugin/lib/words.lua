--[[--
The words on screen, with their boxes and positions: what lets a reader of
the markup export (lib/export) tell which words a stroke underlines or
circles without reading the page's pixels.

Takes the visible text's first and last positions from the document (the
screen, not a page number: the two can disagree), then steps through it a
word at a time. Works with any object that has crengine's text functions,
so it can be tested with a fake.

@module pencil.lib.words
--]]--

local Words = {}

-- The text node an XPointer is in (the path without its offset).
local function nodeOf(xp)
    return xp and (xp:match("^(.*)%.%d+$") or xp)
end

--- Every word on a `width` × `height` screen of `doc`, in reading order:
-- { text, after, boxes = { {x0, y0, x1, y1}, ... } (one per line the word is
-- on), pos0, pos1 }. `after` is what's printed between it and the next word
-- (a space, ", ", "-", "’"), so a passage can be put back together exactly:
-- the word walk splits "Nestor’s" and "ocean-side" in two. Also returns the
-- first and last positions on screen.
function Words.onScreen(doc, width, height)
    local visible = doc:getTextFromPositions({ x = 0, y = 0 }, { x = width, y = height }, true)
    local first, last = visible and visible.pos0, visible and visible.pos1
    local words = {}
    if not first then return words end
    -- The screen may start inside a word: step back one character so the
    -- first word is found whole.
    local ws = doc:getNextVisibleWordStart(doc:getPrevVisibleChar(first) or first)
    local guard = 0
    while ws and guard < 5000 do
        guard = guard + 1
        if last and doc:compareXPointers(ws, last) == -1 then break end
        local we = doc:getNextVisibleWordEnd(ws)
        if not we then break end
        local text = doc:getTextFromXPointers(ws, we)
        local raw = doc._document:getWordBoxesFromPositions(ws, we, true) or {}
        local boxes = {}
        for _, b in ipairs(raw) do
            table.insert(boxes, { b.x0, b.y0, b.x1, b.y1 })
        end
        local nxt = doc:getNextVisibleWordStart(we)
        if text and text ~= "" and #boxes > 0 then
            local after = nxt and doc:getTextFromXPointers(we, nxt) or ""
            -- Words in different text nodes (another line of verse, another
            -- paragraph) are apart even with nothing printed between them.
            if nxt and not after:find("%s") and nodeOf(we) ~= nodeOf(nxt) then
                after = after .. " "
            end
            table.insert(words, { text = text, after = after, boxes = boxes, pos0 = ws, pos1 = we })
        end
        if not nxt or nxt == ws then break end
        ws = nxt
    end
    return words, first, last
end

--- The word nearest the point (x, y): the one whose box (any of its line
-- boxes) is closest, 0 when the point is inside it. Returns the word and
-- that box as {x, y, w, h}, or nil for no words. A plain loop: a page has a
-- few hundred words, so this costs far less than asking the document.
function Words.nearest(words, x, y)
    local best, best_box, best_d
    for _, w in ipairs(words or {}) do
        for _, b in ipairs(w.boxes or {}) do
            local dx = math.max(b[1] - x, 0, x - b[3])
            local dy = math.max(b[2] - y, 0, y - b[4])
            -- Vertical distance counts double: a margin note belongs with the
            -- line beside it more than with the line above or below.
            local d = dx * dx + 4 * dy * dy
            if not best_d or d < best_d then
                best, best_d = w, d
                best_box = { x = b[1], y = b[2], w = b[3] - b[1], h = b[4] - b[2] }
            end
        end
    end
    return best, best_box
end

return Words
