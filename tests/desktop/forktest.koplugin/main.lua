-- Drives the Pencil plugin in KOReader's desktop build and checks what it
-- does (tests/desktop/run.sh). Does nothing unless one of these is set to the
-- file to write its results to (JSON: a list of named checks):
--   FORKTEST_EXPORT     the markup export: markups per page visit, files, words
--   FORKTEST_HIGHLIGHT  the pen menu and the Highlight tool
--   FORKTEST_FONT       a note after a font change
--   FORKTEST_MARKS      an underline and a circle after a font change
--                       (FORKTEST_GROW: how many sizes bigger; 14 by default)
--   FORKTEST_RENAME     renaming and copying a book (open a.epub)
--   FORKTEST_ROTATE     a note and an underline after turning the screen
-- The positions drawn at suit tests/desktop/odyssey.epub at 1053×1400.
local Event = require("ui/event")
local JSON = require("json")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local lfs = require("libs/libkoreader-lfs")
local Test = WidgetContainer:extend{ name = "forktest", is_doc_only = true }
local OUT = os.getenv("FORKTEST_EXPORT")

local function write(data)
    local f = assert(io.open(OUT, "wb")); f:write(data); f:close()
end
local function draw(p, points)
    p:startRawStroke()
    for _, pt in ipairs(points) do p:addRawPoint(pt[1], pt[2]) end
    p:endRawStroke()
end
local function folders(dir)
    local out = {}
    if lfs.attributes(dir, "mode") ~= "directory" then return out end
    for e in lfs.dir(dir) do if e:match("^m_") then table.insert(out, e) end end
    table.sort(out); return out
end

-- Steps run one after another, with time between for captures.
function Test:onReaderReady()
    if os.getenv("FORKTEST_HIGHLIGHT") then
        -- The Highlight tool, chosen in the pen menu: a drag across a line
        -- with the pen skipping off the glass mid-way, then the same drag
        -- again. Then the side button pressed after a stroke has begun (as
        -- KOReader delivers it on the device): releasing it keeps the tool.
        local out = os.getenv("FORKTEST_HIGHLIGHT")
        local p, r = self.ui.pencil, { checks = {} }
        local function check(name, ok, detail) table.insert(r.checks, { name = name, ok = ok and true or false, detail = detail }) end
        local Input = require("device").input
        local function slot(id, x, y, tool) p:handleStylusSlot(Input, { slot = 4, id = id, x = x, y = y, tool = tool or 1 }) end
        local function count()
            local n = 0
            for _, a in ipairs(self.ui.annotation.annotations) do if a.drawer then n = n + 1 end end
            return n
        end
        local paints, drawers = 0, {}
        local paint = p._paintTempSelection
        p._paintTempSelection = function(...)
            paints = paints + 1
            local ret = paint(...)
            drawers[self.ui.view.highlight.temp_drawer] = true
            return ret
        end
        local function drag(done)
            slot(1, 40, 115)
            for x = 45, 200, 5 do slot(1, x, 115) end
            slot(-1, 200, 115) -- skips off the glass
            UIManager:scheduleIn(0.1, function()
                for x = 205, 420, 5 do slot(1, x, 115) end
                slot(-1, 420, 115)
                UIManager:scheduleIn(1, done)
            end)
        end
        G_reader_settings:saveSetting("pencil_annotation_enabled", true)
        UIManager:scheduleIn(1, function()
            -- A fresh profile's first-run messages would sit over the page.
            for i = #UIManager._window_stack, 1, -1 do
                local w = UIManager._window_stack[i].widget
                if w ~= self.ui then UIManager:close(w) end
            end
            self.ui:handleEvent(Event:new("GotoPage", 40))
            local before = count()
            UIManager:scheduleIn(1, function()
                -- The menu, from its gesture action; choose Highlight.
                self.ui:handleEvent(Event:new("PencilMenu"))
                local menu = p.color_picker_widget
                check("the pen menu opens from its action", menu ~= nil)
                UIManager:scheduleIn(0.5, function()
                    UIManager:forceRePaint()
                    require("device").screen.bb:writePNG(out .. ".png")
                    local item = menu and menu.rows[1][2]
                    check("its first row is the tools", item and item.tool == "highlight" and item.box ~= nil, item and item.box)
                    if item and item.box then
                        menu:handlePenTap(item.box.x + 5, item.box.y + 5)
                    end
                    check("choosing Highlight selects it and closes the menu",
                        p.current_tool == "highlight" and p.color_picker_widget == nil, p.current_tool)
                    drag(function()
                        check("one highlight for a drag that skipped", count() == before + 1, count() - before)
                        check("the selection is shown inverted while dragging", drawers.invert == true and drawers.lighten == nil, drawers)
                        check("repainted per word, not per pen report", paints < 30, paints)
                        check("KOReader's own selection style is restored", self.ui.view.highlight.temp_drawer == "lighten",
                            self.ui.view.highlight.temp_drawer)
                        local last = self.ui.annotation.annotations[#self.ui.annotation.annotations]
                        r.text = last and last.text
                        drag(function()
                            check("the same drag again adds no duplicate", count() == before + 1, count() - before)
                            -- Pen, then a stroke with the button pressed after it began.
                            p:setTool("pen")
                            slot(1, 600, 900)
                            p:onStylusButtonPress()
                            slot(1, 640, 910)
                            slot(-1, 640, 910)
                            p:onStylusButtonRelease()
                            check("a button press that came after the stroke began doesn't toggle", p.current_tool == "pen", p.current_tool)
                            local f = io.open(out, "w"); f:write(JSON.encode(r)); f:close()
                            UIManager:quit()
                        end)
                    end)
                end)
            end)
        end)
        return
    end
    if os.getenv("FORKTEST_FONT") then
        -- Ink after a font change: a note written beside a line follows its
        -- word to its new page and place, can be erased there, comes back
        -- with undo, and is drawn exactly as written in the old font again.
        local out = os.getenv("FORKTEST_FONT")
        local p, doc, r = self.ui.pencil, self.ui.document, { checks = {} }
        local function check(name, ok, detail) table.insert(r.checks, { name = name, ok = ok and true or false, detail = detail }) end
        local function shot(name)
            UIManager:forceRePaint()
            require("device").screen.bb:writePNG(out .. "." .. name .. ".png")
        end
        local function centre(st)
            local x0, y0, x1, y1 = math.huge, math.huge, -math.huge, -math.huge
            for _, q in ipairs(st.points) do
                x0, y0, x1, y1 = math.min(x0, q.x), math.min(y0, q.y), math.max(x1, q.x), math.max(y1, q.y)
            end
            return (x0 + x1) / 2, (y0 + y1) / 2
        end
        local function shownNote(page, first)
            local out_list = {}
            for _, sh in ipairs(p:shownStrokes(page)) do
                if sh[1] >= first then table.insert(out_list, sh[2]) end
            end
            return out_list
        end
        local size0
        G_reader_settings:saveSetting("pencil_annotation_enabled", true)
        UIManager:scheduleIn(1, function()
            for i = #UIManager._window_stack, 1, -1 do
                local w = UIManager._window_stack[i].widget
                if w ~= self.ui then UIManager:close(w) end
            end
            self.ui:handleEvent(Event:new("GotoPage", 40))
            -- A first layout at a new screen size is finished in the
            -- background; the page is captured (and ink anchored) after.
            local start
            local function ready(fn)
                if self.ui.rolling.rendering_state and (os.time() - start) < 60 then
                    return UIManager:scheduleIn(0.5, function() ready(fn) end)
                end
                r.waited_s = os.time() - start
                fn()
            end
            start = os.time()
            UIManager:scheduleIn(1, function() ready(function()
                self.ui:handleEvent(Event:new("GotoPage", 40))
                p:capturePage()
                local first = #p.strokes + 1
                -- "ok" in the margin right of the 4th line (y ~ 222).
                local function draw(points) p:startRawStroke(); for _, q in ipairs(points) do p:addRawPoint(q[1], q[2]) end; p:endRawStroke() end
                draw({ { 960, 205 }, { 975, 230 }, { 990, 205 } })
                draw({ { 1005, 200 }, { 1005, 235 } })
                draw({ { 1005, 220 }, { 1025, 205 } })
                local a = p.strokes[first].anchor
                r.anchor_word = a and doc:getTextFromXPointers(a.xpointer, doc:getNextVisibleWordEnd(a.xpointer))
                check("the note is anchored and its layout recorded", a ~= nil and p.strokes[first].layout ~= nil, a)
                local box0 = a and p:anchorWordBox(a.xpointer)
                local nx0, ny0 = centre(p.strokes[first])
                r.offset_before = box0 and { nx0 - box0.x, ny0 - box0.y }
                shot("before")
                size0 = doc.configurable.font_size
                self.ui:handleEvent(Event:new("SetFontSize", size0 + 8))
                -- Straight after the change, while KOReader may still be
                -- laying the book out in the background.
                UIManager:scheduleIn(0.2, function()
                    r.early = {
                        rendering = self.ui.rolling.rendering_state ~= nil,
                        page = doc:getPageFromXPointer(a.xpointer),
                    }
                    self.ui:handleEvent(Event:new("GotoPage", r.early.page))
                    UIManager:scheduleIn(0.1, function()
                        local shown = shownNote(r.early.page, first)
                        local box = p:anchorWordBox(a.xpointer)
                        local mx, my
                        if shown[1] then mx, my = centre(shown[1]) end
                        r.early.n, r.early.box, r.early.note = #shown, box, mx and { mx, my }
                    end)
                end)
                UIManager:scheduleIn(3, function()
                    local page = doc:getPageFromXPointer(a.xpointer)
                    self.ui:handleEvent(Event:new("GotoPage", page))
                    UIManager:scheduleIn(1, function()
                        local shown = shownNote(page, first)
                        check("the note is shown on its word's new page", #shown == 3, { page = page, n = #shown })
                        check("and was already there straight after the change", r.early and r.early.n == 3
                            and r.early.page == page, r.early)
                        local box = p:anchorWordBox(a.xpointer)
                        local mx, my
                        if shown[1] then mx, my = centre(shown[1]) end
                        r.word_box_after, r.note_after = box, mx and { mx, my }
                        check("beside its word: level with it and just to its right", box and mx
                            and math.abs(my - (box.y + box.h / 2)) < box.h * 1.5 and mx > box.x and mx < box.x + 600,
                            { box = box, note = { mx, my } })
                        check("not drawn on its old page", page == 40 or #shownNote(40, first) == 0)
                        shot("after")
                        -- Erase it where it's shown; undo puts it back as written.
                        local erased = mx and p:eraseAtPoint(mx, my, page)
                        check("erased where it's shown", erased and #erased >= 1, erased and #erased)
                        local written = erased and erased[1] and { centre(erased[1]) }
                        check("the eraser hands back the stroke as written", written and math.abs(written[1] - nx0) < 40
                            and math.abs(written[2] - ny0) < 40, written)
                        -- As the eraser does when it lifts.
                        table.insert(p.undo_stack, { type = "delete", strokes = erased })
                        p:undoLastStroke()
                        self.ui:handleEvent(Event:new("SetFontSize", size0))
                        UIManager:scheduleIn(3, function()
                            self.ui:handleEvent(Event:new("GotoPage", 40))
                            UIManager:scheduleIn(1, function()
                                local again = shownNote(40, first)
                                local exact = #again == 3
                                for _, st in ipairs(again) do
                                    if getmetatable(st) ~= nil then exact = false end
                                end
                                check("back in the old font, drawn exactly as written", exact, #again)
                                shot("back")
                                local f = io.open(out, "w"); f:write(JSON.encode(r)); f:close()
                                UIManager:quit()
                            end)
                        end)
                    end)
                end)
            end) end)
        end)
        return
    end
    if os.getenv("FORKTEST_MARKS") then
        -- Marks after a font change: an underline and a circle are drawn
        -- again under and around the same words in the new layout.
        local out = os.getenv("FORKTEST_MARKS")
        local p, doc, r = self.ui.pencil, self.ui.document, { checks = {} }
        local function check(name, ok, detail) table.insert(r.checks, { name = name, ok = ok and true or false, detail = detail }) end
        local function draw(points) p:startRawStroke(); for _, q in ipairs(points) do p:addRawPoint(q[1], q[2]) end; p:endRawStroke() end
        local function shot(name) UIManager:forceRePaint(); require("device").screen.bb:writePNG(out .. "." .. name .. ".png") end
        local function boxOf(points)
            local b = { math.huge, math.huge, -math.huge, -math.huge }
            for _, q in ipairs(points) do
                b[1], b[2] = math.min(b[1], q.x), math.min(b[2], q.y)
                b[3], b[4] = math.max(b[3], q.x), math.max(b[4], q.y)
            end
            return b
        end
        G_reader_settings:saveSetting("pencil_annotation_enabled", true)
        UIManager:scheduleIn(1, function()
            for i = #UIManager._window_stack, 1, -1 do
                local w = UIManager._window_stack[i].widget
                if w ~= self.ui then UIManager:close(w) end
            end
            self.ui:handleEvent(Event:new("GotoPage", 40))
            UIManager:scheduleIn(2, function()
                p:capturePage()
                local first = #p.strokes + 1
                -- Under "Laertes, when his fatal" (line 2), and around "funeral"
                -- (line 1), placed from the page's own word boxes.
                local function wordBox(text)
                    for _, w in ipairs(p.page_capture.words) do
                        if w.text:find("^" .. text) then return w.boxes[1] end
                    end
                end
                local l0, l1, f = wordBox("Laertes"), wordBox("fatal"), wordBox("funeral")
                local y = l0[4] + 4
                draw({ { l0[1] - 2, y }, { (l0[1] + l1[3]) / 2, y + 2 }, { l1[3] + 2, y } })
                local cx, cy = (f[1] + f[3]) / 2, (f[2] + f[4]) / 2
                local rx, ry = (f[3] - f[1]) / 2 + 12, (f[4] - f[2]) / 2 + 6
                local ring = {}
                for k = 0, 24 do
                    local a = k / 24 * 2 * math.pi
                    table.insert(ring, { cx + rx * math.cos(a), cy + ry * math.sin(a) })
                end
                draw(ring)
                local u, c = p.strokes[first], p.strokes[first + 1]
                local function text(m) return m and doc:getTextFromXPointers(m.pos0, m.pos1) end
                r.underlined, r.circled = text(u.mark), text(c.mark)
                check("the underline knows its words", u.mark and u.mark.kind == "underline" and r.underlined
                    and r.underlined:find("Laertes") and r.underlined:find("fatal"), r.underlined)
                check("the circle knows its word", c.mark and c.mark.kind == "circle" and r.circled == "funeral", r.circled)
                shot("before")
                local size0 = doc.configurable.font_size
                self.ui:handleEvent(Event:new("SetFontSize", size0 + (tonumber(os.getenv("FORKTEST_GROW")) or 14)))
                UIManager:scheduleIn(3, function()
                    local page = doc:getPageFromXPointer(u.mark.pos0)
                    self.ui:handleEvent(Event:new("GotoPage", page))
                    UIManager:scheduleIn(1, function()
                        local shown = { [first] = {}, [first + 1] = {} }
                        for _, sh in ipairs(p:shownStrokes(page)) do
                            if shown[sh[1]] then table.insert(shown[sh[1]], boxOf(sh[2].points)) end
                        end
                        local words = doc:getScreenBoxesFromPositions(u.mark.pos0, u.mark.pos1, true)
                        r.lines_now, r.underline_pieces = #words, #shown[first]
                        -- Each piece sits just below some of the words, within their span.
                        local fits = #shown[first] >= 1
                        for _, b in ipairs(shown[first]) do
                            local under = false
                            for _, w in ipairs(words) do
                                if b[2] >= w.y + w.h - 5 and b[2] <= w.y + w.h + w.h * 0.6
                                        and b[1] >= -5 and b[3] <= require("device").screen:getWidth() + 5 then under = true end
                            end
                            fits = fits and under
                        end
                        check("the underline is drawn under its words in the new layout", fits, { pieces = shown[first], words = #words })
                        local cw = doc:getScreenBoxesFromPositions(c.mark.pos0, c.mark.pos1, true)[1]
                        local cb = shown[first + 1][1]
                        check("the circle is drawn around its word in the new layout", cw and cb and cb[1] < cw.x
                            and cb[3] > cw.x + cw.w and cb[2] < cw.y + cw.h / 2 and cb[4] > cw.y + cw.h / 2,
                            { word = cw, circle = cb })
                        shot("after")
                        self.ui:handleEvent(Event:new("SetFontSize", size0))
                        UIManager:scheduleIn(3, function()
                            self.ui:handleEvent(Event:new("GotoPage", 40))
                            UIManager:scheduleIn(1, function()
                                local exact = 0
                                for _, sh in ipairs(p:shownStrokes(40)) do
                                    if sh[1] >= first and getmetatable(sh[2]) == nil then exact = exact + 1 end
                                end
                                check("back at the old size, both drawn exactly as written", exact == 2, exact)
                                local f = io.open(out, "w"); f:write(JSON.encode(r)); f:close()
                                UIManager:quit()
                            end)
                        end)
                    end)
                end)
            end)
        end)
        return
    end
    if os.getenv("FORKTEST_ROTATE") then
        -- Turning the screen is a layout change like any other: a note and
        -- an underline follow their words, no camera badge is shown, and
        -- turning back draws them exactly as written.
        local out = os.getenv("FORKTEST_ROTATE")
        local p, doc, r = self.ui.pencil, self.ui.document, { checks = {} }
        local Screen = require("device").screen
        local function check(name, ok, detail) table.insert(r.checks, { name = name, ok = ok and true or false, detail = detail }) end
        local function boxOf(points)
            local b = { math.huge, math.huge, -math.huge, -math.huge }
            for _, q in ipairs(points) do
                b[1], b[2] = math.min(b[1], q.x), math.min(b[2], q.y)
                b[3], b[4] = math.max(b[3], q.x), math.max(b[4], q.y)
            end
            return b
        end
        G_reader_settings:saveSetting("pencil_annotation_enabled", true)
        UIManager:scheduleIn(1, function()
            for i = #UIManager._window_stack, 1, -1 do
                local w = UIManager._window_stack[i].widget
                if w ~= self.ui then UIManager:close(w) end
            end
            self.ui:handleEvent(Event:new("GotoPage", 40))
            UIManager:scheduleIn(2, function()
                p:capturePage()
                local function wordBox(text)
                    for _, w in ipairs(p.page_capture.words) do
                        if w.text:find("^" .. text) then return w.boxes[1] end
                    end
                end
                local first = #p.strokes + 1
                local l0, l1 = wordBox("Laertes"), wordBox("fatal")
                draw(p, { { l0[1] - 2, l0[4] + 4 }, { (l0[1] + l1[3]) / 2, l0[4] + 6 }, { l1[3] + 2, l0[4] + 4 } })
                draw(p, { { 960, 300 }, { 1000, 310 } })
                draw(p, { { 965, 330 }, { 1005, 340 } })
                p:saveStrokes()
                for _, g in ipairs(p.annotation_groups) do p:captureGroupImage(g) end
                local key0 = p:layoutKey()
                local note = p.strokes[first + 1]
                self.ui:handleEvent(Event:new("SetRotationMode", 1))
                UIManager:scheduleIn(3, function()
                    check("turning the screen changes the layout", p:layoutKey() ~= key0, { p:layoutKey(), key0 })
                    local u = p.strokes[first]
                    local page = doc:getPageFromXPointer(u.mark.pos0)
                    self.ui:handleEvent(Event:new("GotoPage", page))
                    UIManager:scheduleIn(1, function()
                        local shown = {}
                        for _, sh in ipairs(p:shownStrokes(page)) do
                            if sh[1] >= first then shown[sh[1]] = boxOf(sh[2].points) end
                        end
                        local words = doc:getScreenBoxesFromPositions(u.mark.pos0, u.mark.pos1, true)
                        local w0 = words[1]
                        local ub = shown[first]
                        check("the underline is under its words, turned", ub and w0 and ub[2] >= w0.y + w0.h - 5
                            and ub[2] <= w0.y + w0.h * 1.6, { underline = ub, word = w0 })
                        check("no camera badge", p:getStaleGroupsForCurrentView() == nil)
                        -- The note's word may be on another page now.
                        local npage = doc:getPageFromXPointer(note.anchor.xpointer)
                        self.ui:handleEvent(Event:new("GotoPage", npage))
                        UIManager:scheduleIn(1, function()
                        local nshown = {}
                        for _, sh in ipairs(p:shownStrokes(npage)) do
                            if sh[1] == first + 1 then nshown = boxOf(sh[2].points) end
                        end
                        local nb = p:anchorWordBox(note.anchor.xpointer)
                        check("the note is beside its word, turned", nb and nshown[1] and nshown[1] > nb.x
                            and math.abs((nshown[2] + nshown[4]) / 2 - (nb.y + nb.h / 2)) < nb.h * 1.5
                            and nshown[3] <= Screen:getWidth(), { note = nshown, word = nb })
                        check("no camera badge on its page either", p:getStaleGroupsForCurrentView() == nil)
                        self.ui:handleEvent(Event:new("SetRotationMode", 0))
                        UIManager:scheduleIn(3, function()
                            self.ui:handleEvent(Event:new("GotoPage", 40))
                            UIManager:scheduleIn(1, function()
                                local exact = 0
                                for _, sh in ipairs(p:shownStrokes(40)) do
                                    if sh[1] >= first and getmetatable(sh[2]) == nil then exact = exact + 1 end
                                end
                                check("turned back, drawn exactly as written", exact == 3, exact)
                                local f = io.open(out, "w"); f:write(JSON.encode(r)); f:close()
                                UIManager:quit()
                            end)
                        end)
                        end)
                    end)
                end)
            end)
        end)
        return
    end
    if os.getenv("FORKTEST_RENAME") then
        -- Rename and copy a book with ink, as KOReader's file manager does
        -- (DocSettings.updateLocation): the ink, its pictures and its export
        -- follow a rename; a copy gets its own and the original keeps its.
        local out = os.getenv("FORKTEST_RENAME")
        local DocSettings = require("docsettings")
        local ReaderUI = require("apps/reader/readerui")
        local p, file = self.ui.pencil, self.ui.document.file
        local dir = file:match("^(.*)/[^/]+$")
        local a, b, c = dir .. "/a.epub", dir .. "/b.epub", dir .. "/c.epub"
        local function sdr(path) return (path:gsub("%.epub$", ".sdr")) end
        local function exists(path) return lfs.attributes(path) ~= nil end
        local function state(path)
            local s = sdr(path)
            local markups = 0
            if lfs.attributes(s .. "/pencil/markups", "mode") == "directory" then
                for e in lfs.dir(s .. "/pencil/markups") do if e:match("^m_") then markups = markups + 1 end end
            end
            return { strokes = exists(s .. "/pencil_strokes.lua"), markups = markups,
                images = exists(s .. "/pencil_images"), dir = exists(s) }
        end
        local afterClose
        local function reopen(path)
            UIManager:scheduleIn(0.5, function()
                -- Closed (its settings saved where they are), then renamed or
                -- copied and opened, all at once so KOReader doesn't quit
                -- with nothing open.
                self.ui:onClose()
                afterClose(path)
            end)
        end
        local function load()
            local f = io.open(out, "r"); local r = f and JSON.decode(f:read("*a")) or { checks = {} }; if f then f:close() end
            return r
        end
        local function save(r) local f = io.open(out, "w"); f:write(JSON.encode(r)); f:close() end
        local function check(r, name, ok, detail) table.insert(r.checks, { name = name, ok = ok and true or false, detail = detail }) end
        afterClose = function(next_doc)
            -- What the file manager does: the book file, then its settings.
            if next_doc == b then
                os.rename(a, b)
                DocSettings.updateLocation(a, b)
            else
                local fi, fo = io.open(b, "rb"), io.open(c, "wb"); fo:write(fi:read("*a")); fi:close(); fo:close()
                DocSettings.updateLocation(b, c, true)
            end
            ReaderUI:showReader(next_doc)
        end
        G_reader_settings:saveSetting("pencil_annotation_enabled", true)
        UIManager:scheduleIn(1, function()
            for i = #UIManager._window_stack, 1, -1 do
                local w = UIManager._window_stack[i].widget
                if w ~= self.ui then UIManager:close(w) end
            end
            if file == a then
                self.ui:handleEvent(Event:new("GotoPage", 40))
                UIManager:scheduleIn(2, function()
                    p:capturePage()
                    draw(p, { { 960, 300 }, { 1000, 310 } })
                    draw(p, { { 965, 330 }, { 1005, 340 } })
                    p:saveStrokes()
                    p:captureGroupImage(p.annotation_groups[#p.annotation_groups])
                    p:saveStrokes(); p:syncMarkups(true)
                    local r = { checks = {}, before = state(a) }
                    check(r, "the book has ink, an export and a picture", r.before.strokes and r.before.markups == 1 and r.before.images, r.before)
                    save(r)
                    reopen(b)
                end)
            elseif file == b then
                UIManager:scheduleIn(1, function()
                    local r = load()
                    r.renamed, r.old = state(b), state(a)
                    check(r, "after a rename, the ink is in the new book", #p.strokes == 2, #p.strokes)
                    check(r, "its export and pictures came too", r.renamed.strokes and r.renamed.markups == 1 and r.renamed.images, r.renamed)
                    check(r, "nothing is left in the old folder", not r.old.dir, r.old)
                    save(r)
                    reopen(c)
                end)
            elseif file == c then
                UIManager:scheduleIn(1, function()
                    local r = load()
                    r.copy, r.original = state(c), state(b)
                    check(r, "a copy gets the ink", #p.strokes == 2 and r.copy.strokes and r.copy.markups == 1, r.copy)
                    check(r, "and the original keeps its own", r.original.strokes and r.original.markups == 1 and r.original.images, r.original)
                    save(r)
                    UIManager:quit()
                end)
            end
        end)
        return
    end
    if not OUT then return end
    local p, doc, r = self.ui.pencil, self.ui.document, { checks = {}, notes = {} }
    local function check(name, ok, detail) table.insert(r.checks, { name = name, ok = ok and true or false, detail = detail }) end
    local dir
    local steps = {
        function()
            dir = p:getMarkupsDir()
            self.ui:handleEvent(Event:new("GotoPage", 40))
        end,
        function()
            -- Underline the second line ("Laertes, when his fatal hour…") and
            -- write a short note in the right margin.
            draw(p, { { 18, 132 }, { 300, 133 }, { 600, 134 } })
            draw(p, { { 960, 300 }, { 1000, 310 } })
            draw(p, { { 965, 330 }, { 1005, 340 } })
        end,
        function()
            check("page captured after the pen rests", next(p.markup_captures) ~= nil)
            -- The margin note (y 300-340) anchors to a word on its own line.
            local note = p.strokes[2]
            local w = note.anchor and self.ui.document:getTextFromXPointers(note.anchor.xpointer,
                self.ui.document:getNextVisibleWordEnd(note.anchor.xpointer))
            r.note_anchor = w
            check("margin note anchored beside it", note.anchor and math.abs(note.anchor.dy) < 1.5, note.anchor)
            p:saveStrokes(); p:syncMarkups()
            local f = folders(dir)
            check("one markup folder", #f == 1, f)
            local m = dir .. "/" .. (f[1] or "")
            r.page40 = f[1]
            for _, name in ipairs({ "markup.json", "ink.json", "page.png", "words.json" }) do
                check(name .. " written", lfs.attributes(m .. "/" .. name, "mode") == "file")
            end
            r.markup = JSON.decode(io.open(m .. "/markup.json"):read("*a"))
            r.ink_strokes = #JSON.decode(io.open(m .. "/ink.json"):read("*a")).strokes
            check("three strokes in the ink", r.ink_strokes == 3, r.ink_strokes)
            local words = JSON.decode(io.open(m .. "/words.json"):read("*a")).words
            -- What a reader would take as underlined: words on the line just
            -- above the underline (y 132), across its width.
            local under = {}
            for _, w in ipairs(words) do
                local b = w.boxes[1]
                if b[4] <= 140 and b[4] >= 90 and b[1] < 600 then table.insert(under, w.text) end
            end
            r.underlined = table.concat(under, " ")
            r.words = #words
            self.ui:handleEvent(Event:new("GotoPage", 41))
        end,
        function()
            draw(p, { { 500, 600 }, { 560, 610 } })
        end,
        function()
            p:saveStrokes(); p:syncMarkups()
            check("a second markup for page 41", #folders(dir) == 2, folders(dir))
            -- Erase it: its folder goes.
            p:eraseAtPoint(500, 600, p:getCurrentPage())
            p:saveStrokes(); p:syncMarkups()
            local f = folders(dir)
            check("erased markup removed", #f == 1 and f[1] == r.page40, f)
            self.ui:handleEvent(Event:new("GotoPage", 40))
        end,
        function()
            -- As on a device that captured the page on arrival: the reader
            -- pauses, then writes.
            p:capturePage()
            draw(p, { { 960, 600 }, { 1000, 610 } })
        end,
        function()
            p:saveStrokes(); p:syncMarkups()
            check("writing again on a revisited page starts a new markup", #folders(dir) == 2, folders(dir))
            -- Written after the page was captured (3 s after arriving): the
            -- markup still gets the page's picture and words.
            for _, f in ipairs(folders(dir)) do
                if f ~= r.page40 then
                    local m = JSON.decode(io.open(dir .. "/" .. f .. "/markup.json"):read("*a"))
                    check("a markup begun after the capture has its page", m.has_page_image and m.screen ~= nil
                        and lfs.attributes(dir .. "/" .. f .. "/words.json", "mode") == "file", m)
                end
            end
            r.folder = dir .. "/" .. r.page40
            write(JSON.encode(r))
            UIManager:quit()
        end,
    }
    local i = 0
    local function nxt()
        i = i + 1
        if not steps[i] then return end
        local ok, err = pcall(steps[i])
        if not ok then write(JSON.encode({ checks = { { name = "runs without an error", ok = false, detail = tostring(err) } } })); UIManager:quit(); return end
        UIManager:scheduleIn(3, nxt)
    end
    UIManager:scheduleIn(2, nxt)
end

return Test
