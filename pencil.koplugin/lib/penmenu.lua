--[[--
The pen menu's rows: the tool (pen, highlight, eraser), the pen's colour
and its width, each item marked when it's the current choice. Pure, so the
layout can be tested without KOReader; main.lua draws the rows.

@module pencil.lib.penmenu
--]]--

local PenMenu = {}

--- The tools, in the order shown. `tool` is the plugin's tool name.
PenMenu.TOOLS = {
    { tool = "pen", label = "Pen" },
    { tool = "highlight", label = "Highlight" },
    { tool = "eraser", label = "Eraser" },
}

--- The menu's rows, top to bottom: tools, colours, widths. `colors` is a
-- list of { name, color }, `widths` of { name, width }; `current` holds
-- the current `tool`, `color_name` and `width`. Each item has a `kind`
-- ("tool", "color" or "width"), its value, and `selected`.
function PenMenu.rows(colors, widths, current)
    current = current or {}
    local tools, swatches, bars = {}, {}, {}
    for _, t in ipairs(PenMenu.TOOLS) do
        table.insert(tools, {
            kind = "tool", tool = t.tool, label = t.label,
            selected = t.tool == current.tool,
        })
    end
    for _, c in ipairs(colors or {}) do
        table.insert(swatches, {
            kind = "color", name = c.name, color_value = c.color,
            selected = c.name == current.color_name,
        })
    end
    for _, w in ipairs(widths or {}) do
        table.insert(bars, {
            kind = "width", name = w.name, width_value = w.width,
            selected = w.width == current.width,
        })
    end
    local rows = { tools }
    if #swatches > 0 then table.insert(rows, swatches) end
    if #bars > 0 then table.insert(rows, bars) end
    return rows
end

--- The item at (x, y), given each item's on-screen box as `item.box`
-- ({ x, y, w, h }), or nil.
function PenMenu.hit(rows, x, y)
    for _, row in ipairs(rows) do
        for _, item in ipairs(row) do
            local b = item.box
            if b and x >= b.x and x < b.x + b.w and y >= b.y and y < b.y + b.h then
                return item
            end
        end
    end
    return nil
end

return PenMenu
