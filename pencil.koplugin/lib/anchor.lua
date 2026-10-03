--[[--
Anchors: where a stroke sits relative to the text, so it can be found again
whatever the layout.

An anchor names the word nearest the stroke (its XPointer) and the offset of
the stroke's centre from that word's box, measured in the word's line
heights, so it scales with the font. Pure functions; the caller asks the
document for the word.

@module pencil.lib.anchor
--]]--

local Anchor = {}

--- The anchor for a stroke whose box is `bbox` ({x0, y0, x1, y1}), given the
-- nearest word: `xpointer` and its box `word` ({x, y, w, h}). nil without a
-- usable word. With the text `column` ({x0, x1}, the page's left and right
-- text edges), a stroke wholly in a margin also records which (`margin`,
-- "left" or "right") and how far its centre is from the text (`gap`, in
-- pixels), so it can stay in that margin on another layout.
function Anchor.fromWord(bbox, xpointer, word, column)
    if not bbox or not xpointer or not word or not word.h or word.h <= 0 then
        return nil
    end
    local cx = (bbox.x0 + bbox.x1) / 2
    local cy = (bbox.y0 + bbox.y1) / 2
    local line = word.h
    -- Rounded, so saved files stay readable and stable across saves.
    local function round(v) return math.floor(v * 1000 + 0.5) / 1000 end
    local anchor = {
        xpointer = xpointer,
        dx = round((cx - word.x) / line),
        dy = round((cy - word.y) / line),
    }
    if column and bbox.x1 <= column.x0 then
        anchor.margin, anchor.gap = "left", math.floor(column.x0 - cx + 0.5)
    elseif column and bbox.x0 >= column.x1 then
        anchor.margin, anchor.gap = "right", math.floor(cx - column.x1 + 0.5)
    end
    return anchor
end

--- Where the stroke's centre goes on a layout where the anchor word's box is
-- `word` ({x, y, w, h}): the inverse of fromWord. A margin stroke goes in the
-- same margin of the text `column` ({x0, x1}), as far from the text, level
-- with the word.
function Anchor.place(anchor, word, column)
    if not anchor or not word or not word.h then return nil end
    local y = word.y + anchor.dy * word.h
    if column and anchor.margin == "left" then
        return column.x0 - anchor.gap, y
    elseif column and anchor.margin == "right" then
        return column.x1 + anchor.gap, y
    end
    return word.x + anchor.dx * word.h, y
end

return Anchor
