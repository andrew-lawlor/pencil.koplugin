--[[--
Pencil plugin for KOReader.
Enables freehand drawing and annotation with stylus on supported devices.

@module koplugin.pencil
--]]--

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local DataStorage = require("datastorage")
local Device = require("device")
local Dispatcher = require("dispatcher")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local PencilGeometry = require("lib/geometry")
local PencilAnchor = require("lib/anchor")
local PencilStore = require("lib/store")
local PencilExport = require("lib/export")
local PencilWords = require("lib/words")
local PencilRefit = require("lib/refit")
local PenMenu = require("lib/penmenu")
local JSON = require("json")
local Screen = Device.screen
local Size = require("ui/size")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template
local time = require("ui/time")

-- Check if device supports touch input
if not Device:isTouchDevice() then
    return { disabled = true }
end

-- Tool types
local TOOL_PEN = "pen"
local TOOL_HIGHLIGHTER = "highlighter"
local TOOL_ERASER = "eraser"
-- Dragging across text makes a KOReader highlight (chosen in the pen menu).
local TOOL_TEXT_HIGHLIGHT = "highlight"

-- How long the pen may leave the glass mid-highlight and carry on.
local TEXT_HIGHLIGHT_LIFT_S = 0.3

-- Whether two text positions are the same: XPointers (EPUB) are strings,
-- PDF positions tables of page, x and y.
local function samePosition(a, b)
    if type(a) == "table" and type(b) == "table" then
        return a.page == b.page and a.x == b.x and a.y == b.y
    end
    return a ~= nil and a == b
end

-- Color picker trigger settings
local COLOR_PICKER_DELAY_MS = 500  -- How long pen must be held still (milliseconds)
local COLOR_PICKER_TOLERANCE_PIXELS = 15  -- How many pixels pen can move while "still"

-- Annotation grouping constants
local GROUP_TIME_THRESHOLD_S = 10   -- seconds between strokes to be grouped
local GROUP_SPATIAL_THRESHOLD = 200 -- pixels between bboxes to be grouped

-- Annotation image constants
local IMAGE_CAPTURE_V_MARGIN_PX = 24     -- vertical padding around bbox before clamping
local IMAGE_MIN_HEIGHT_PX = 350          -- floor for captured strip height (legibility)
local IMAGE_MAX_DIM = 1280               -- only downscale captures whose longer side exceeds this
local IMAGE_JPEG_QUALITY = 85
local IMAGE_CAPTURE_DEBOUNCE_S = 8       -- seconds after last stroke before capturing (kept off the pen)
local IMAGE_BADGE_SIZE = 48              -- on-page badge edge (px) when annotation is stale
local IMAGE_BADGE_HIT_PAD = 32           -- extra pixels around badge for tap hit-test
local IMAGE_BADGE_MARGIN_GAP = 5         -- gap from text/screen edge for margin badge

-- Module-level reference to the most recently initialized Pencil instance.
-- Used by the bookmark-list hook (a class-level monkey-patch installed once)
-- to find the live plugin without coupling to KOReader internals.
local _active_pencil = nil

-- Written into each markup export, so readers know what made it.
local PLUGIN_VERSION = "0.6.4"
-- Nothing slow happens while writing (KOReader runs on one thread, so any
-- work freezes the pen). The page picture and its words are taken shortly
-- after arriving on a page, inside the page turn's own refresh; if the pen
-- gets there first, once it has rested a while.
local PAGE_CAPTURE_DELAY_S = 0.5
local PAGE_CAPTURE_PEN_REST_S = 2
-- Encoding pictures and writing the export wait for this long without the
-- pen or a page turn (or for closing the book, or sleep).
local EXPORT_IDLE_S = 8
local _bookmark_hook_installed = false

local Pencil = InputContainer:extend{
    name = "pencil_annotation",
    is_doc_only = true,  -- Only available when a document is open
    current_stroke = nil,
    strokes = nil,       -- All strokes for current document
    current_tool = TOOL_PEN,
    touch_zones_registered = false,
    undo_stack = {},     -- For undo functionality
    eraser_tool_active = false,  -- Track if physical eraser end is in use (via BTN_TOOL_RUBBER)
    eraser_button_active = false,  -- Hardware eraser button held
    eraser_button_deleted = {},    -- Track deletions for undo
    -- Text-highlight state: true while a side-button + pen-drag is building a
    -- KOReader text-highlight selection via ReaderHighlight. Sticky through
    -- pen lift so releasing the side button mid-drag doesn't abort.
    highlighting = false,

    -- Stylus callback for lowest latency (via Input:registerStylusCallback)
    stylus_callback_registered = false,
    pen_down = false,
    erasing = false,  -- Track if currently in erase mode (for finger modifier)
    pen_x = 0,
    pen_y = 0,

    last_refresh_time = 0,
    refresh_interval_ms = 16,  -- Refresh at most every 16ms during drawing (~60fps)
    dirty_region = nil,  -- Accumulated dirty region for batch refresh

    -- Delayed refresh - only refresh after user stops writing
    pending_refresh = nil,
    refresh_delay_ms = 600, -- Wait 600ms after last stroke before final refresh
    -- Screen-space bbox of strokes drawn since the last delayed refresh fired.
    -- The post-lift "clean" refresh is scoped to this region instead of the
    -- whole screen, so a dense page doesn't trigger a full-panel e-ink update.
    pending_refresh_bbox = nil,

    -- Debounced save - coalesces full O(N) serialization across consecutive strokes.
    -- Force-flushed on page change, close, and the deferred-work scheduler.
    pending_save = nil,
    save_delay_ms = 1500,
    dirty_groups = nil, -- Set of groups awaiting syncGroupBookmark (id -> group)

    -- Tool settings
    tool_settings = {
        [TOOL_PEN] = {
            width = 3,
            color = nil,  -- Blitbuffer color, set in init
            color_name = "Black",  -- For persistence and display
            alpha = 255,
        },
        [TOOL_HIGHLIGHTER] = {
            width = 20,
            color = nil,  -- Set in init (needs Blitbuffer)
            alpha = 128,
        },
        [TOOL_ERASER] = {
            width = 20,
        },
    },

    -- Side button state
    side_button_down = false,
    side_button_used_for_highlight = false,  -- Track if button was used during a stroke

    -- Color picker state (triggered by holding pen within 5 pixels for 5 seconds)
    color_picker_start_x = nil,  -- Initial X position when pen touched down
    color_picker_start_y = nil,  -- Initial Y position when pen touched down
    color_picker_start_time = nil,  -- Timestamp when pen touched down (nil if moved too far)
    color_picker_check_pending = nil,  -- Scheduled periodic check
    color_picker_showing = false,  -- Whether color picker is currently displayed

    -- Available colors for the pen (initialized in init() with actual Blitbuffer colors)
    available_colors = {},
}

function Pencil:init()
    -- CRITICAL: Add plugin to ReaderUI widget tree so it receives ALL key events
    -- This ensures we catch Eraser button press/release events
    -- Technique borrowed from eraser.koplugin by SimonLiu <simonliu423@gmail.com>
    table.insert(self.ui, self)                -- Add to widget children for event propagation
    table.insert(self.ui.active_widgets, self) -- Always receive events even when hidden

    self.ui.menu:registerToMainMenu(self)
    self.strokes = {}
    self.page_strokes = {}  -- Index: page -> array of stroke indices
    self.annotation_groups = {}  -- Annotation groups for bookmark integration
    self.strokes_loaded = false  -- Set true after successful loadStrokes
    -- Markup export (lib/export): the page visit new strokes belong to,
    -- what was taken from the screen per markup, and what was last written.
    self.visit = nil
    self.page_capture = nil     -- the current page's picture and words
    self.markup_captures = {}   -- markup id -> the capture of its page
    self.markup_written = {}    -- markup id -> signature last written
    self.markup_has_image = {}  -- markup id -> page.png written
    self.undo_stack = {}

    -- Initialize highlighter color (yellow)
    self.tool_settings[TOOL_HIGHLIGHTER].color = Blitbuffer.Color8(0xDD)  -- Light gray for e-ink

    -- Calculate gray value from highlight_lighten_factor setting
    local lighten_factor = G_reader_settings:readSetting("highlight_lighten_factor") or 0.2
    local gray_value = math.floor(255 * (1 - lighten_factor))

    -- Available colors for color picker (Blitbuffer color values)
    self.available_colors = {
        { name = "Black", color = Blitbuffer.COLOR_BLACK },
        { name = "Red", color = Blitbuffer.ColorRGB32(0xFF, 0x33, 0x00, 0xFF) },
        { name = "Orange", color = Blitbuffer.ColorRGB32(0xFF, 0x88, 0x00, 0xFF) },
        { name = "Yellow", color = Blitbuffer.ColorRGB32(0xFF, 0xFF, 0x33, 0xFF) },
        { name = "Green", color = Blitbuffer.ColorRGB32(0x00, 0xAA, 0x66, 0xFF) },
        { name = "Olive", color = Blitbuffer.ColorRGB32(0x88, 0xFF, 0x77, 0xFF) },
        { name = "Cyan", color = Blitbuffer.ColorRGB32(0x00, 0xFF, 0xEE, 0xFF) },
        { name = "Blue", color = Blitbuffer.ColorRGB32(0x00, 0x66, 0xFF, 0xFF) },
        { name = "Purple", color = Blitbuffer.ColorRGB32(0xEE, 0x00, 0xFF, 0xFF) },
        { name = "Gray", color = Blitbuffer.Color8(gray_value) },
    }

    -- Available pen widths for the optional experimental width picker.
    -- Chosen in the pen menu; see loadSettings().
    self.available_widths = {
        { name = "w3", width = 3 },
        { name = "w5", width = 5 },
        { name = "w7", width = 7 },
        { name = "w9", width = 9 },
    }

    -- Load tool and stylus button settings
    self:loadSettings()

    -- Ensure pen color has a default value (black) if not set
    if not self.tool_settings[TOOL_PEN].color then
        self.tool_settings[TOOL_PEN].color = Blitbuffer.COLOR_BLACK
        self.tool_settings[TOOL_PEN].color_name = "Black"
    end

    -- Register as view module to render strokes
    self.view = self.ui.view
    self.view:registerViewModule("pencil_strokes", self)

    -- Try to load strokes now if doc_settings is ready
    -- (backup: they'll also be loaded in onReaderReady/onReadSettings)
    if self.ui.doc_settings and self.ui.doc_settings.doc_sidecar_dir then
        logger.info("Pencil: doc_settings available in init, loading strokes")
        self:loadStrokes()
    else
        logger.info("Pencil: doc_settings not ready in init, will load in onReaderReady")
    end

    -- Check if plugin is enabled globally and auto-setup
    if self:isEnabled() then
        self:setupPenInput()
    end

    -- Initialize debug logging (if debug mode enabled)
    self:initDebugLog()

    -- Register custom actions for gesture mapping
    Dispatcher:registerAction("pencil_toggle_tool", {
        category = "none",
        event = "PencilToggleTool",
        title = _("Pencil: toggle pencil/eraser"),
        reader = true,
    })
    Dispatcher:registerAction("pencil_toggle_enabled", {
        category = "none",
        event = "PencilToggleEnabled",
        title = _("Pencil: toggle on/off"),
        reader = true,
    })
    Dispatcher:registerAction("pencil_select_pen", {
        category = "none",
        event = "PencilSelectPen",
        title = _("Pencil: select pencil"),
        reader = true,
    })
    Dispatcher:registerAction("pencil_select_highlight", {
        category = "none",
        event = "PencilSelectHighlight",
        title = _("Pencil: select highlight"),
        reader = true,
    })
    Dispatcher:registerAction("pencil_menu", {
        category = "none",
        event = "PencilMenu",
        title = _("Pencil: pen menu"),
        reader = true,
    })
    Dispatcher:registerAction("pencil_select_eraser", {
        category = "none",
        event = "PencilSelectEraser",
        title = _("Pencil: select eraser"),
        reader = true,
    })
    Dispatcher:registerAction("pencil_undo", {
        category = "none",
        event = "PencilUndo",
        title = _("Pencil: undo"),
        reader = true,
        separator = true,
    })

    -- Per-instance state for the annotation-image feature
    self.pending_image_captures = {}
    self.image_data_dirty = false
    _active_pencil = self

    -- Install the (class-level, one-time) bookmark list hook so taps on
    -- pencil bookmarks open the saved image.
    self:installBookmarkHook()

    logger.info("Pencil: initialized, enabled =", self:isEnabled(), "tool =", self.current_tool, "strokes =", #self.strokes)
end

-- Dispatcher event handlers (for custom gesture mapping)
function Pencil:onPencilToggleTool()
    if self.current_tool == TOOL_ERASER then
        self.current_tool = TOOL_PEN
    else
        self.current_tool = TOOL_ERASER
    end
    UIManager:show(InfoMessage:new{
        text = T(_("Tool: %1"), self:toolName(self.current_tool)),
        timeout = 1,
    })
    return true
end

function Pencil:onPencilToggleEnabled()
    local enabled = self:isEnabled()
    self:setEnabled(not enabled)
    if self:isEnabled() then
        self:setupPenInput()
        UIManager:show(InfoMessage:new{
            text = _("Pencil enabled"),
            timeout = 1,
        })
    else
        self:teardownPenInput()
        UIManager:show(InfoMessage:new{
            text = _("Pencil disabled"),
            timeout = 1,
        })
    end
    return true
end

function Pencil:onPencilSelectPen()
    self.current_tool = TOOL_PEN
    UIManager:show(InfoMessage:new{
        text = _("Pencil tool: pencil"),
        timeout = 1,
    })
    return true
end

function Pencil:onPencilSelectEraser()
    self.current_tool = TOOL_ERASER
    UIManager:show(InfoMessage:new{
        text = _("Eraser selected"),
        timeout = 1,
    })
    return true
end

function Pencil:onPencilSelectHighlight()
    self:setTool(TOOL_TEXT_HIGHLIGHT)
    return true
end

function Pencil:onPencilMenu()
    self:showPenMenu()
    return true
end

function Pencil:onPencilUndo()
    self:undoLastStroke()
    return true
end

-- Setup stylus callback for lowest latency pen capture
-- Uses the new Input:registerStylusCallback() API that intercepts stylus events
-- before they reach the gesture detector
function Pencil:setupStylusCallback()
    if self.stylus_callback_registered then return end

    local Input = Device.input
    if not Input or not Input.registerStylusCallback then
        logger.warn("Pencil: stylus callback API not available")
        return
    end

    local plugin = self

    -- Register the stylus callback
    -- Callback receives: input (Input object), slot (table with slot, id, x, y, tool, timev)
    -- Return true to "dominate" (remove from gesture detection)
    Input:registerStylusCallback(function(input, slot)
        return plugin:handleStylusSlot(input, slot)
    end)

    self.stylus_callback_registered = true
    logger.info("Pencil: stylus callback registered")
end

-- Transform stylus coordinates based on screen rotation
-- Raw stylus coordinates are in hardware space; framebuffer expects logical (rotated) space
function Pencil:transformCoordinates(x, y)
    local rotation = Screen:getRotationMode()
    return PencilGeometry.transformForRotation(x, y, rotation, Screen:getWidth(), Screen:getHeight())
end


-- Handle a stylus slot from the callback
-- slot = {slot=N, id=N, x=N, y=N, tool=N, timev=timestamp}
-- id >= 0 means contact active, id == -1 means contact lifted
function Pencil:handleStylusSlot(input, slot)
    -- Tool types from Linux input subsystem
    local TOOL_TYPE_PEN = 1
    local TOOL_TYPE_ERASER = 2
    local TOOL_TYPE_HIGHLIGHTER = 3

    -- Debug logging at the very start to see slot.tool
    if self.input_debug_mode then
        self:writeDebugLog(string.format("STYLUS SLOT: id=%d x=%d y=%d tool=%d eraser_active=%s",
            slot.id or -1, slot.x or 0, slot.y or 0, slot.tool or -1,
            tostring(self.eraser_button_active)))
    end

    -- Don't capture pen input when a menu or overlay is on top of the reader
    if self:isOverlayActive() then return false end

    -- Detect eraser end via slot.tool BEFORE key events arrive
    -- This handles the timing issue where stylus callback fires before key events
    if ((self.swap_eraser_and_highlighter and slot.tool == TOOL_TYPE_HIGHLIGHTER) or (not self.swap_eraser_and_highlighter and slot.tool == TOOL_TYPE_ERASER)) and not self.eraser_button_active then
        logger.info("Pencil: Eraser end detected via slot.tool, activating eraser mode")
        self.eraser_button_active = true
        self.eraser_button_deleted = {}
    elseif ((self.swap_eraser_and_highlighter and not (slot.tool == TOOL_TYPE_HIGHLIGHTER)) or (not self.swap_eraser_and_highlighter and not (slot.tool == TOOL_TYPE_ERASER))) and self.eraser_button_active then
        -- Switched from eraser end to pen tip
        logger.info("Pencil: Pen tip detected via slot.tool, deactivating eraser mode")
        if self.eraser_button_deleted and #self.eraser_button_deleted > 0 then
            table.insert(self.undo_stack, { type = "delete", strokes = self.eraser_button_deleted })
            self:saveStrokes()
        end
        self.eraser_button_active = false
        self.eraser_button_deleted = nil
        UIManager:setDirty(self.view, "ui")
    end

    -- Eraser mode (from eraser end or hardware button) - works even if pencil disabled
    if self.eraser_button_active then
        if slot.id and slot.id >= 0 then
            local raw_x = slot.x or self.pen_x
            local raw_y = slot.y or self.pen_y
            local x, y = self:transformCoordinates(raw_x, raw_y)
            local page = self:getCurrentPage()
            local deleted = self:eraseAtPoint(x, y, page)
            if deleted then
                for _, stroke in ipairs(deleted) do
                    table.insert(self.eraser_button_deleted, stroke)
                end
                self.view:paintTo(Screen.bb, 0, 0)
                self:paintTo(Screen.bb, 0, 0)
                local rx, ry, rw, rh = self:erasedStrokesRefreshRect(deleted)
                if rx then
                    Screen:refreshFast(rx, ry, rw, rh)
                else
                    Screen:refreshFast(0, 0, Screen:getWidth(), Screen:getHeight())
                end
            end
            -- Also remove any native KOReader text highlight at this position.
            -- removeItemByIndex emits AnnotationsModified and triggers its own
            -- repaint, so we don't need to mirror the refreshFast call above.
            self:eraseHighlightAtScreenPos(x, y)
            self.pen_x = x
            self.pen_y = y
        end
        return true
    end

    -- The Highlight tool: the pen selects text and makes a KOReader
    -- highlight instead of drawing. Runs before any draw/stroke logic, and
    -- carries on until the highlight is saved.
    if self.highlighting or (self.current_tool == TOOL_TEXT_HIGHLIGHT and self:isEnabled()) then
        local current_slot_id = slot.id or -1
        if current_slot_id >= 0 and not self.highlighting then
            self:startTextHighlight(slot.x or 0, slot.y or 0)
        elseif current_slot_id >= 0 and self.highlighting then
            -- Back on the glass soon after a lift (the pen skipped): the
            -- same selection carries on.
            self:cancelTextHighlightFinish()
            self:extendTextHighlight(slot.x or 0, slot.y or 0)
        elseif current_slot_id < 0 and self.highlighting then
            self:scheduleTextHighlightFinish()
        end
        return true
    end

    if not self:isEnabled() or self:isOverlayActive() then return false end

    -- Log in debug mode
    if self.input_debug_mode then
        self:writeDebugLog(string.format("STYLUS: slot=%d id=%d x=%d y=%d tool=%d pen_down=%s tool=%s",
            slot.slot or -1, slot.id or -1, slot.x or 0, slot.y or 0, slot.tool or -1,
            tostring(self.pen_down), self.current_tool))
    end

    -- Determine effective tool:
    -- 1. Physical eraser end via slot.tool (TOOL_TYPE_ERASER = 2) takes priority
    -- 2. Physical eraser end via BTN_TOOL_RUBBER key event (eraser_tool_active) as backup
    -- 3. Otherwise use selected tool (user can toggle via gesture)
    local TOOL_TYPE_ERASER = 2
    local effective_tool
    if (self.swap_eraser_and_highlighter and slot.tool == TOOL_TYPE_HIGHLIGHTER) or (not self.swap_eraser_and_highlighter and slot.tool == TOOL_TYPE_ERASER) or self.eraser_tool_active then
        effective_tool = TOOL_ERASER
        if self.input_debug_mode and slot.tool == TOOL_TYPE_ERASER then
            self:writeDebugLog(string.format("ERASER END detected via slot.tool=%d", slot.tool))
        end
    else
        effective_tool = self.current_tool
    end

    -- Handle eraser mode
    if effective_tool == TOOL_ERASER then
        if self.input_debug_mode and not self.erasing then
            self:writeDebugLog(string.format("ERASER MODE: pen_down=%s slot.id=%d",
                tostring(self.pen_down), slot.id or -1))
        end
        if slot.id and slot.id >= 0 then
            -- Eraser is touching - erase at this position
            local first_touch = false
            if not self.pen_down then
                self.pen_down = true
                self.erasing = true
                self.eraser_deleted = {}
                first_touch = true
                if self.input_debug_mode then
                    self:writeDebugLog("=== ERASER DOWN ===")
                end
            end

            local raw_x = slot.x or self.pen_x
            local raw_y = slot.y or self.pen_y
            local x, y = self:transformCoordinates(raw_x, raw_y)
            -- Erase on first touch OR when position changes
            if first_touch or x ~= self.pen_x or y ~= self.pen_y then
                local page = self:getCurrentPage()
                if self.input_debug_mode then
                    self:writeDebugLog(string.format("ERASE ATTEMPT at (%d, %d) page=%s erasing=%s",
                        x, y, tostring(page), tostring(self.erasing)))
                end
                local deleted = self:eraseAtPoint(x, y, page)
                if deleted then
                    for _, stroke in ipairs(deleted) do
                        table.insert(self.eraser_deleted, stroke)
                    end
                    -- Immediately repaint view and our strokes overlay, then refresh
                    self.view:paintTo(Screen.bb, 0, 0)
                    self:paintTo(Screen.bb, 0, 0)
                    local rx, ry, rw, rh = self:erasedStrokesRefreshRect(deleted)
                    if rx then
                        Screen:refreshUI(rx, ry, rw, rh)
                    else
                        Screen:refreshUI(0, 0, Screen:getWidth(), Screen:getHeight())
                    end
                    if self.input_debug_mode then
                        self:writeDebugLog(string.format("ERASED %d strokes at (%d, %d)", #deleted, x, y))
                    end
                end
                self.pen_x = x
                self.pen_y = y
            end
        else
            -- Eraser lifted
            if self.pen_down and self.erasing then
                self.pen_down = false
                self.erasing = false
                if self.eraser_deleted and #self.eraser_deleted > 0 then
                    table.insert(self.undo_stack, { type = "delete", strokes = self.eraser_deleted })
                    self:saveStrokes()
                end
                self.eraser_deleted = nil
                UIManager:setDirty(self.view, "ui")
                if self.input_debug_mode then
                    self:writeDebugLog("=== ERASER UP ===")
                end
            end
        end
        return true  -- Dominate: remove from gesture detection
    end

    -- Handle pen/highlighter mode
    if slot.id and slot.id >= 0 then
        -- Pen down or moving
        if not self.pen_down then
            -- Check if color picker is showing - route pen tap to it
            if self.color_picker_showing and self.color_picker_widget then
                local raw_x = slot.x or 0
                local raw_y = slot.y or 0
                local x, y = self:transformCoordinates(raw_x, raw_y)
                if self.color_picker_widget:handlePenTap(x, y) then
                    -- Color picker handled the tap, don't start a stroke
                    return true
                end
            end

            -- Start new stroke
            self.pen_down = true
            self.erasing = false
            self:cancelPendingRefresh()
            self:cancelColorPickerTimer()
            self:startRawStroke()
            -- Record initial position and timestamp for color picker trigger
            local raw_x = slot.x or 0
            local raw_y = slot.y or 0
            local x, y = self:transformCoordinates(raw_x, raw_y)
            self.pen_x = x
            self.pen_y = y
            -- Only track picker state and schedule the 10Hz poll when the
            -- hold-pen-still gesture would actually produce something to
            -- show. Skipping these when both experimental pickers are off
            -- avoids an UIManager:scheduleIn closure allocation on every
            -- pen-down — real GC pressure on the A53 during multi-second
            -- strokes.
            if self.hold_opens_pen_menu then
                self.color_picker_start_x = x
                self.color_picker_start_y = y
                self.color_picker_start_time = time.now()
                -- Schedule periodic check for color picker trigger
                self:scheduleColorPickerCheck()
            end
            if self.input_debug_mode then
                self:writeDebugLog("=== PEN DOWN ===")
            end
        else
            -- Pen is moving
            local raw_x = slot.x or self.pen_x
            local raw_y = slot.y or self.pen_y
            local x, y = self:transformCoordinates(raw_x, raw_y)
            if x ~= self.pen_x or y ~= self.pen_y then
                -- Check if pen moved more than tolerance from start position
                if self.color_picker_start_x and self.color_picker_start_y then
                    local dx = math.abs(x - self.color_picker_start_x)
                    local dy = math.abs(y - self.color_picker_start_y)
                    if dx > COLOR_PICKER_TOLERANCE_PIXELS or dy > COLOR_PICKER_TOLERANCE_PIXELS then
                        -- Pen moved too far - reset tracking (no color picker)
                        self:resetColorPickerTracking()
                    end
                end
                self:addRawPoint(x, y)
                self.pen_x = x
                self.pen_y = y
            end
        end
    else
        -- Pen lifted (id == -1)
        if self.pen_down and not self.erasing then
            self.pen_down = false
            self:cancelColorPickerTimer()
            self:endRawStroke()
            if self.input_debug_mode then
                self:writeDebugLog("=== PEN UP ===")
            end
        end
    end

    return true  -- Dominate: remove from gesture detection
end

-- Teardown stylus callback
function Pencil:teardownStylusCallback()
    if not self.stylus_callback_registered then return end

    local Input = Device.input
    if Input and Input.unregisterStylusCallback then
        Input:unregisterStylusCallback()
    end

    self.stylus_callback_registered = false
    self.pen_down = false
    logger.info("Pencil: stylus callback unregistered")
end

-- Start a new stroke from raw input
function Pencil:startRawStroke()
    -- Nothing slow while the pen is down, and no repaint under it: a
    -- clean-up refresh still pending from the last stroke would start an
    -- e-ink update that the next ink refresh has to wait for (~250 ms on a
    -- Libra Colour). It's scheduled again when this stroke ends.
    self:cancelPageCapture()
    self:cancelIdleExport()
    self:cancelPendingRefresh()
    local page = self:getCurrentPage()
    local tool = self.side_button_down and TOOL_HIGHLIGHTER or self.current_tool
    local tool_settings = self.tool_settings[tool] or self.tool_settings[TOOL_PEN]

    if self.side_button_down then
        self.side_button_used_for_highlight = true
    end

    -- Black pen ink can be shown with the fast waveform (see refreshInk).
    self.ink_fast = tool == TOOL_PEN
        and (tool_settings.color_name == nil or tool_settings.color_name == "Black")
        and not Screen.night_mode
    self.current_stroke = {
        page = page,
        tool = tool,
        points = {},
        width = tool_settings.width,
        color = tool_settings.color,
        color_name = tool_settings.color_name,
        alpha = tool_settings.alpha,
        datetime = os.time(),
    }
    self.last_refresh_time = time.now()
    self.dirty_region = nil  -- Clear any pending dirty region
    logger.dbg("Pencil: raw stroke started")
end

-- Add a point from raw input and draw it
function Pencil:addRawPoint(x, y)
    if not self.current_stroke then return end

    local point = { x = x, y = y }
    table.insert(self.current_stroke.points, point)

    local n = #self.current_stroke.points

    local width = self.current_stroke.width
    local color = self.current_stroke.color
    local half_w = math.floor(width / 2) + 2  -- padding for antialiasing

    -- Reinvert color in night mode (if it's not black or gray)
    if Screen.night_mode and self.current_stroke.color_name ~= "Black" and self.current_stroke.color_name ~= "Gray" then
        color = color:invert()
    end

    -- Draw to framebuffer and track dirty region
    local dirty_x, dirty_y, dirty_w, dirty_h
    if n == 1 then
        -- Draw first point same size as line segments for consistency
        local half_w_draw = math.floor(width / 2)
        Screen.bb:paintRectRGB32(x - half_w_draw, y - half_w_draw, width, width, color)
        -- Use slightly larger dirty region for refresh padding
        dirty_x = x - half_w
        dirty_y = y - half_w
        dirty_w = width + 4
        dirty_h = width + 4
    elseif n >= 2 then
        local p1 = self.current_stroke.points[n - 1]
        local p2 = self.current_stroke.points[n]
        if self.current_stroke.tool == TOOL_HIGHLIGHTER then
            self:drawHighlighterSegment(Screen.bb, p1.x, p1.y, p2.x, p2.y, width, color)
        else
            self:drawLineSegment(Screen.bb, p1.x, p1.y, p2.x, p2.y, width, color)
        end
        -- Calculate bounding box of the segment
        dirty_x = math.min(p1.x, p2.x) - half_w
        dirty_y = math.min(p1.y, p2.y) - half_w
        dirty_w = math.abs(p2.x - p1.x) + width + 4
        dirty_h = math.abs(p2.y - p1.y) + width + 4
    end

    -- Accumulate dirty region for batch refresh
    if dirty_x then
        if self.dirty_region then
            -- Expand existing dirty region
            local r = self.dirty_region
            local new_x = math.min(r.x, dirty_x)
            local new_y = math.min(r.y, dirty_y)
            local new_x2 = math.max(r.x + r.w, dirty_x + dirty_w)
            local new_y2 = math.max(r.y + r.h, dirty_y + dirty_h)
            self.dirty_region = { x = new_x, y = new_y, w = new_x2 - new_x, h = new_y2 - new_y }
        else
            self.dirty_region = { x = dirty_x, y = dirty_y, w = dirty_w, h = dirty_h }
        end
    end

    -- Periodic refresh of dirty region only
    local now = time.now()
    if time.to_ms(now - self.last_refresh_time) >= self.refresh_interval_ms then
        self.last_refresh_time = now
        if self.dirty_region then
            local r = self.dirty_region
            -- Clamp to screen bounds
            local rx = math.max(0, math.floor(r.x))
            local ry = math.max(0, math.floor(r.y))
            local rw = math.min(Screen:getWidth() - rx, math.ceil(r.w))
            local rh = math.min(Screen:getHeight() - ry, math.ceil(r.h))
            self:refreshInk(rx, ry, rw, rh)
            self.dirty_region = nil
        end
    end
end

-- End stroke from raw input
function Pencil:endRawStroke()
    if self.input_debug_mode then
        self:writeDebugLog(string.format("endRawStroke: current_stroke=%s points=%d",
            tostring(self.current_stroke ~= nil),
            self.current_stroke and #self.current_stroke.points or 0))
    end
    if self.current_stroke and #self.current_stroke.points >= 1 then
        self:anchorStroke(self.current_stroke)
        self:assignMarkup(self.current_stroke)
        table.insert(self.strokes, self.current_stroke)
        self:indexStroke(#self.strokes, self.current_stroke.page)
        table.insert(self.undo_stack, { type = "add", stroke_idx = #self.strokes })
        self:assignStrokeToGroup(#self.strokes)
        self:scheduleDeferredWork()
        if self.input_debug_mode then
            self:writeDebugLog(string.format("endRawStroke: SAVED stroke #%d with %d points, total strokes=%d",
                #self.strokes, #self.current_stroke.points, #self.strokes))
        end
        logger.dbg("Pencil: raw stroke ended with", #self.current_stroke.points, "points")
        -- Track the region this stroke touched so the delayed refresh below
        -- can be scoped to it instead of the whole screen.
        self:accumulateRefreshBbox(self.current_stroke)
    else
        if self.input_debug_mode then
            self:writeDebugLog("endRawStroke: NOT SAVED (no current_stroke or no points)")
        end
    end
    -- Show the end of the stroke now: points drawn since the last periodic
    -- refresh would otherwise stay invisible until writing stops.
    self:flushDirtyRegion()
    self.current_stroke = nil
    -- Schedule delayed refresh for clean display after writing stops
    self:scheduleDelayedRefresh()
end

-- Refreshes the part of the screen drawn on since the last refresh.
function Pencil:flushDirtyRegion()
    local r = self.dirty_region
    if not r then return end
    self.dirty_region = nil
    local rx = math.max(0, math.floor(r.x))
    local ry = math.max(0, math.floor(r.y))
    local rw = math.min(Screen:getWidth() - rx, math.ceil(r.w))
    local rh = math.min(Screen:getHeight() - ry, math.ceil(r.h))
    if rw > 0 and rh > 0 then
        self:refreshInk(rx, ry, rw, rh)
    end
end

-- Shows freshly drawn ink. Black pen ink uses the fast waveform (DU): on
-- MediaTek Kobos (the Libra Colour), KOReader waits for every other partial
-- update to be accepted by the display controller, which holds it back
-- while an earlier, overlapping update (~250 ms for the UI waveform) is
-- still running: that wait was the pen's lag. Fast updates are never
-- waited on, and black on white is what DU is for. Colours, grey and the
-- highlighter need the UI waveform; everything gets a clean UI refresh
-- once writing stops (scheduleDelayedRefresh).
function Pencil:refreshInk(x, y, w, h)
    if self.ink_fast then
        Screen:refreshFast(x, y, w, h)
    else
        Screen:refreshUI(x, y, w, h)
    end
end

-- Paint the in-progress text selection as "invert" rectangles while a
-- highlight drag is active. Mirrors what KOReader does during a normal
-- finger long-press+drag: the reader's paintTo iterates
-- self.view.highlight.temp[page] and inversion-paints each sbox. All we
-- have to do is populate that table with our current sboxes, then
-- setDirty so a repaint runs.
function Pencil:_paintTempSelection()
    if not (self.ui and self.ui.view and self.ui.view.highlight and self.ui.highlight) then
        return
    end
    local rh = self.ui.highlight
    local temp = self.ui.view.highlight.temp
    -- Shown inverted: the fast waveform only has black and white, and turns
    -- KOReader's usual light grey selection white.
    if self._temp_drawer == nil then
        self._temp_drawer = self.ui.view.highlight.temp_drawer
        self.ui.view.highlight.temp_drawer = "invert"
    end
    -- Reset any previous frame's temp entries so stale sboxes from earlier
    -- in the drag don't linger after the selection shrinks.
    for k in pairs(temp) do temp[k] = nil end
    if rh.selected_text and rh.selected_text.sboxes and #rh.selected_text.sboxes > 0 then
        local page_key = rh.hold_pos and rh.hold_pos.page or 1
        temp[page_key] = rh.selected_text.sboxes
    end
    -- The fast waveform: KOReader waits on UI refreshes on MediaTek Kobos,
    -- which made the selection lag behind the pen. It's refreshed properly
    -- when the highlight is saved.
    UIManager:setDirty(self.ui.dialog or self.ui.view, "fast")
end

-- Clear the in-progress selection preview. Called on pen lift before we
-- persist the selection as a saved highlight (which then paints itself
-- via drawSavedHighlight instead of via temp).
function Pencil:_clearTempSelection()
    if not (self.ui and self.ui.view and self.ui.view.highlight) then return end
    local temp = self.ui.view.highlight.temp
    for k in pairs(temp) do temp[k] = nil end
    if self._temp_drawer ~= nil then
        self.ui.view.highlight.temp_drawer = self._temp_drawer
        self._temp_drawer = nil
    end
    UIManager:setDirty(self.ui.dialog or self.ui.view, "ui")
end

-- Start a native KOReader text-highlight selection at a raw stylus position.
-- Called from handleStylusSlot when the Highlight tool is chosen.
--
-- Manipulates self.ui.highlight (ReaderHighlight) directly because there is
-- no public "start programmatic selection" API — the standard entry points
-- (onHold / onHoldPan) do extra work (panel-zoom probing, gesture wiring)
-- that we don't need and that would interact badly with our stylus-sourced
-- events. The methods we do call (getWordFromPosition / getTextFromPositions
-- / saveHighlight) are the same ones KOReader itself invokes internally.
function Pencil:startTextHighlight(raw_x, raw_y)
    if not (self.ui and self.ui.highlight and self.ui.view and self.ui.document) then
        return
    end
    local screen_x, screen_y = self:transformCoordinates(raw_x, raw_y)
    local page_pos = self.ui.view:screenToPageTransform({ x = screen_x, y = screen_y })
    if not page_pos then return end  -- Tap outside any page area

    local rh = self.ui.highlight
    rh.hold_pos = page_pos

    local ok, word = pcall(self.ui.document.getWordFromPosition, self.ui.document, page_pos)
    if ok and word and word.pos0 and word.pos1 then
        rh.selected_text = {
            text = word.word or "",
            pos0 = word.pos0,
            pos1 = word.pos1,
            sboxes = word.sbox and { word.sbox } or {},
            pboxes = word.pbox and { word.pbox } or {},
        }
    else
        rh.selected_text = nil
    end

    self.highlighting = true
    -- Prevent the drawing-path pen-down branch from also firing on subsequent
    -- events for this contact.
    self.pen_down = true

    -- Show the first-word preview immediately.
    self:_paintTempSelection()
end

-- Extend the active text-highlight selection to a new raw stylus position.
-- Called on each stylus slot update while self.highlighting is true.
function Pencil:extendTextHighlight(raw_x, raw_y)
    if not (self.ui and self.ui.highlight and self.ui.view and self.ui.document) then
        return
    end
    local rh = self.ui.highlight
    if not rh.hold_pos then return end

    local screen_x, screen_y = self:transformCoordinates(raw_x, raw_y)
    local page_pos = self.ui.view:screenToPageTransform({ x = screen_x, y = screen_y })
    if not page_pos then return end
    rh.holdpan_pos = page_pos

    -- getTextFromPositions handles EPUB (xpointer) and PDF (x/y/page) shapes
    -- and returns a selection dict with pos0/pos1/text/sboxes/pboxes.
    local ok, selected = pcall(self.ui.document.getTextFromPositions,
                               self.ui.document, rh.hold_pos, rh.holdpan_pos)
    if ok and selected and selected.pos0 and selected.pos1 then
        local before = rh.selected_text
        rh.selected_text = selected
        -- Repaint only when the selection reaches another word: the pen
        -- reports far more often than that.
        if not (before and samePosition(before.pos0, selected.pos0)
                and samePosition(before.pos1, selected.pos1)) then
            self:_paintTempSelection()
        end
    end
end

-- Saves the highlight a moment after the pen lifts, so a pen that skips off
-- the glass mid-drag doesn't split one highlight into several.
function Pencil:scheduleTextHighlightFinish()
    if self.pending_highlight_finish then return end
    local action
    action = function()
        if self.pending_highlight_finish ~= action then return end
        self.pending_highlight_finish = nil
        self:finishTextHighlight()
    end
    self.pending_highlight_finish = action
    UIManager:scheduleIn(TEXT_HIGHLIGHT_LIFT_S, action)
end

function Pencil:cancelTextHighlightFinish()
    if self.pending_highlight_finish then
        UIManager:unschedule(self.pending_highlight_finish)
        self.pending_highlight_finish = nil
    end
end

-- Whether the book already has a highlight from pos0 to pos1.
function Pencil:highlightExists(pos0, pos1)
    local annotations = self.ui and self.ui.annotation and self.ui.annotation.annotations
    for _, item in ipairs(annotations or {}) do
        if item.drawer and samePosition(item.pos0, pos0) and samePosition(item.pos1, pos1) then
            return true
        end
    end
    return false
end

-- Persist the current selection as a KOReader highlight annotation and reset.
-- Called on slot.id transitioning to -1 (pen lift) while self.highlighting.
function Pencil:finishTextHighlight()
    local rh = self.ui and self.ui.highlight
    local has_selection = rh and rh.selected_text
        and rh.selected_text.pos0 and rh.selected_text.pos1

    -- Clear the in-progress preview first; the saved highlight's own paint
    -- path (drawSavedHighlight) will take over on the next frame.
    self:_clearTempSelection()

    if has_selection and self:highlightExists(rh.selected_text.pos0, rh.selected_text.pos1) then
        has_selection = false
    end
    if has_selection then
        -- saveHighlight(false) builds the annotation item from self.selected_text
        -- and calls self.ui.annotation:addItem(item) internally, handling the
        -- PDF/EPUB item-shape difference. It emits AnnotationsModified itself,
        -- so we do NOT emit a second one here — a userpatch may further wrap
        -- this call to prompt for color, but that's not the plugin's concern.
        local ok, err = pcall(rh.saveHighlight, rh, false)
        if not ok then
            logger.warn("Pencil: saveHighlight failed:", tostring(err))
        end
    end

    if rh and rh.clear then
        pcall(rh.clear, rh)
    end

    self:cancelTextHighlightFinish()
    self.highlighting = false
    self.pen_down = false
end

-- Find the index in self.ui.annotation.annotations of a saved text highlight
-- whose rendered boxes cover screen position (screen_x, screen_y).
-- Returns nil if no highlight is at that position.
-- Used by the eraser path so flipping to the eraser end and swiping across a
-- highlight removes it, the same way it removes freehand strokes.
function Pencil:findHighlightAtScreenPos(screen_x, screen_y)
    if not (self.ui and self.ui.annotation and self.ui.annotation.annotations
            and self.ui.view and self.ui.document) then
        return nil
    end

    local is_paging = self.ui.paging ~= nil
    local page_pos
    if is_paging then
        page_pos = self.ui.view:screenToPageTransform({ x = screen_x, y = screen_y })
        if not page_pos then return nil end
    end

    for index, item in ipairs(self.ui.annotation.annotations) do
        -- drawer is nil for page-bookmarks; only text highlights have it set.
        if item.drawer and item.pos0 and item.pos1 then
            local boxes
            if is_paging then
                if item.page == page_pos.page then
                    local ok, got = pcall(self.ui.document.getPageBoxesFromPositions,
                                          self.ui.document, page_pos.page, item.pos0, item.pos1)
                    if ok then boxes = got end
                end
            else
                -- Rolling mode (EPUB): work in screen coordinates directly.
                local ok, got = pcall(self.ui.document.getScreenBoxesFromPositions,
                                      self.ui.document, item.pos0, item.pos1, true)
                if ok then boxes = got end
            end
            if boxes then
                local px = is_paging and page_pos.x or screen_x
                local py = is_paging and page_pos.y or screen_y
                for _, box in ipairs(boxes) do
                    if px >= box.x and px < box.x + box.w
                            and py >= box.y and py < box.y + box.h then
                        return index
                    end
                end
            end
        end
    end
    return nil
end

-- Delete any KOReader text highlight at the given screen position.
-- Used by the eraser pass inside handleStylusSlot. removeItemByIndex emits
-- AnnotationsModified and does the logical cleanup, but on e-ink its
-- setDirty is not strong enough to clear the highlight's painted pixels
-- from the framebuffer — users saw the removed highlight linger until the
-- next page turn forced a full refresh. Force a UI-mode setDirty here so
-- the overlay actually disappears.
function Pencil:eraseHighlightAtScreenPos(screen_x, screen_y)
    local index = self:findHighlightAtScreenPos(screen_x, screen_y)
    if not index then return false end
    if not (self.ui and self.ui.bookmark and self.ui.bookmark.removeItemByIndex) then
        return false
    end
    local ok = pcall(self.ui.bookmark.removeItemByIndex, self.ui.bookmark, index)
    if ok then
        UIManager:setDirty(self.ui.dialog or self.ui.view, "ui")
    end
    return ok
end

-- Get the path to the plugin's log file
function Pencil:getDebugLogPath()
    -- Write to KOReader's data directory (always writable)
    local log_dir = DataStorage:getDataDir()
    return log_dir .. "/pencil_input_debug.log"
end

-- Write a line to the debug log file
function Pencil:writeDebugLog(msg)
    if not self.input_debug_mode then return end

    local log_path = self:getDebugLogPath()
    local f = io.open(log_path, "a")
    if f then
        local timestamp = os.date("%H:%M:%S")
        f:write(string.format("[%s] %s\n", timestamp, msg))
        f:close()
    end
end

-- Clear the debug log file
function Pencil:clearDebugLog()
    local log_path = self:getDebugLogPath()
    local f = io.open(log_path, "w")
    if f then
        f:write("=== Pencil Annotation Input Debug Log ===\n")
        f:write("Started: " .. os.date("%Y-%m-%d %H:%M:%S") .. "\n")
        local device_name = "unknown"
        if Device.model then
            device_name = Device.model
        elseif Device.getDeviceName then
            device_name = Device:getDeviceName() or "unknown"
        end
        f:write("Device: " .. device_name .. "\n")
        f:write("==========================================\n\n")
        f:close()
        logger.info("Pencil: cleared debug log at", log_path)
    end
end

-- Initialize debug logging (clear log and write header)
function Pencil:initDebugLog()
    if not self.input_debug_mode then return end
    self:clearDebugLog()
    self:writeDebugLog("Debug logging enabled")
    local Input = Device.input
    if Input then
        self:writeDebugLog("Input.pen_slot = " .. tostring(Input.pen_slot or "nil"))
    end
end

-- Load plugin settings
function Pencil:loadSettings()
    local settings = G_reader_settings:readSetting("pencil_annotation_settings") or {}
    -- Always start with pencil tool when opening a book
    self.current_tool = TOOL_PEN
    -- Input debug mode: log all input details
    self.input_debug_mode = settings.input_debug_mode or false
    -- Experimental features
    self.experimental_bookmark_sync = settings.experimental_bookmark_sync or false
    -- Swap eraser and highlighter
    self.swap_eraser_and_highlighter = settings.swap_eraser_and_highlighter or false
    self.hold_opens_pen_menu = settings.hold_opens_pen_menu or false
    -- Load pen color by name and look up the actual color value
    local color_name = settings.pen_color_name
    if color_name then
        self.tool_settings[TOOL_PEN].color_name = color_name
        for _, color_info in ipairs(self.available_colors) do
            if color_info.name == color_name then
                self.tool_settings[TOOL_PEN].color = color_info.color
                break
            end
        end
    end
    -- Load pen width if previously chosen via the experimental width picker.
    -- Validated against available_widths so a malformed settings file can't
    -- inject arbitrary widths.
    local saved_width = settings.pen_width
    if saved_width then
        for _, w in ipairs(self.available_widths) do
            if w.width == saved_width then
                self.tool_settings[TOOL_PEN].width = saved_width
                break
            end
        end
    end
end

-- Save plugin settings
function Pencil:saveSettings()
    G_reader_settings:saveSetting("pencil_annotation_settings", {
        input_debug_mode = self.input_debug_mode,
        experimental_bookmark_sync = self.experimental_bookmark_sync,
        hold_opens_pen_menu = self.hold_opens_pen_menu,
        pen_color_name = self.tool_settings[TOOL_PEN].color_name,
        swap_eraser_and_highlighter = self.swap_eraser_and_highlighter,
        pen_width = self.tool_settings[TOOL_PEN].width,
    })
end

-- Set current tool. `quiet`: without the brief message, which would keep
-- the pen from writing while it shows (the pen menu marks the choice).
function Pencil:setTool(tool, quiet)
    self.current_tool = tool
    self:saveSettings()
    if quiet then return end
    -- Show visual feedback with proper display name
    UIManager:show(InfoMessage:new{
        text = T(_("Tool: %1"), self:toolName(tool)),
        timeout = 1,
    })
end

-- A tool's name as shown to the reader.
function Pencil:toolName(tool)
    if tool == TOOL_ERASER then return _("eraser") end
    if tool == TOOL_TEXT_HIGHLIGHT then return _("highlight") end
    return _("pencil")
end

function Pencil:isEnabled()
    return G_reader_settings:readSetting("pencil_annotation_enabled") == true
end

-- Check if a menu or overlay is shown on top of the reader view.
-- When true, pen input should pass through so the overlay can handle it.
function Pencil:isOverlayActive()
    local top = UIManager:getTopmostVisibleWidget()
    if not top then return false end
    -- ReaderUI is the document view itself — anything else is an overlay.
    -- getTopmostVisibleWidget skips widgets marked invisible — transient
    -- decorations that paint but don't capture input, e.g. TrapWidget.
    return (top.name or top.id) ~= "ReaderUI"
end

-- Set enabled state (global setting)
function Pencil:setEnabled(enabled)
    G_reader_settings:saveSetting("pencil_annotation_enabled", enabled)
end

function Pencil:addToMainMenu(menu_items)
    menu_items.pencil_annotation = {
        text = _("Pencil"),
        sorting_hint = "more_tools",
        sub_item_table = {
            {
                text = _("Enabled"),
                checked_func = function()
                    return self:isEnabled()
                end,
                callback = function()
                    self:onPencilToggleEnabled()
                end,
                separator = true,
            },
            {
                text = _("Swap Eraser and Highlighter"),
                checked_func = function()
                    return self.swap_eraser_and_highlighter
                end,
                callback = function()
                    self.swap_eraser_and_highlighter = not self.swap_eraser_and_highlighter
                    self:saveSettings()
                end,
                separator = true,
            },
            {
                text = _("Tool"),
                help_text = _("Select pencil, highlight or eraser."),
                sub_item_table = {
                    {
                        text = _("Pencil"),
                        checked_func = function()
                            return self.current_tool == TOOL_PEN
                        end,
                        callback = function()
                            self:setTool(TOOL_PEN)
                        end,
                    },
                    {
                        text = _("Highlight"),
                        help_text = _("Drag the pen across text to highlight it, as with a long press and Highlight."),
                        checked_func = function()
                            return self.current_tool == TOOL_TEXT_HIGHLIGHT
                        end,
                        callback = function()
                            self:setTool(TOOL_TEXT_HIGHLIGHT)
                        end,
                    },
                    {
                        text = _("Eraser"),
                        checked_func = function()
                            return self.current_tool == TOOL_ERASER
                        end,
                        callback = function()
                            self:setTool(TOOL_ERASER)
                        end,
                    },
                },
            },
            {
                text = _("Pen menu"),
                help_text = _("Choose the tool, the pen's colour and its width. To open it from the page, assign \"Pencil: pen menu\" to a gesture in Taps and gestures."),
                callback = function()
                    self:showPenMenu()
                end,
            },
            {
                text = _("Open the pen menu by holding the pen still"),
                help_text = _("Hold the pen still on the page for half a second to open the pen menu. Off by default: a pause while writing can open it."),
                checked_func = function()
                    return self.hold_opens_pen_menu
                end,
                callback = function()
                    self.hold_opens_pen_menu = not self.hold_opens_pen_menu
                    self:saveSettings()
                end,
            },
            {
                text = _("Undo last stroke"),
                callback = function()
                    self:undoLastStroke()
                end,
                enabled_func = function()
                    return #self.undo_stack > 0
                end,
                separator = true,
            },
            {
                text = _("Clear page strokes"),
                callback = function()
                    self:clearPageStrokes()
                end,
                enabled_func = function()
                    return self:hasStrokesOnCurrentPage()
                end,
            },
            {
                text = _("Clear all strokes"),
                callback = function()
                    self:clearAllStrokes()
                end,
                enabled_func = function()
                    return #self.strokes > 0
                end,
            },
            {
                text_func = function()
                    local bytes = self:getImagesSizeBytes()
                    if bytes <= 0 then
                        return _("Annotation images: none")
                    elseif bytes < 1024 * 1024 then
                        return T(_("Annotation images: %1 KB"), math.floor(bytes / 1024))
                    else
                        return T(_("Annotation images: %1 MB"),
                            string.format("%.1f", bytes / (1024 * 1024)))
                    end
                end,
                help_text = _("Saved preview images of your annotations are used to show what you wrote even after the device is rotated, and to preview annotations from the bookmark list. Tap to clear them for this book."),
                keep_menu_open = true,
                enabled_func = function()
                    return self:getImagesSizeBytes() > 0
                end,
                callback = function(touchmenu_instance)
                    self:purgeAllImages()
                    if touchmenu_instance then touchmenu_instance:updateItems() end
                    UIManager:show(InfoMessage:new{
                        text = _("Cleared all annotation preview images for this book."),
                        timeout = 2,
                    })
                end,
                separator = true,
            },
            {
                text = _("Experimental"),
                sub_item_table = {
                    {
                        text = _("Bookmark sync"),
                        help_text = _("Automatically create KOReader bookmarks for pencil annotations so you can navigate to annotated pages from the Bookmarks menu."),
                        checked_func = function()
                            return self.experimental_bookmark_sync
                        end,
                        callback = function()
                            self.experimental_bookmark_sync = not self.experimental_bookmark_sync
                            self:saveSettings()
                            if self.experimental_bookmark_sync then
                                self:syncAllBookmarks()
                                UIManager:show(InfoMessage:new{
                                    text = _("Bookmark sync enabled. Pencil annotations will appear in the Bookmarks menu."),
                                    timeout = 3,
                                })
                            else
                                self:removeAllPencilBookmarks()
                                UIManager:show(InfoMessage:new{
                                    text = _("Bookmark sync disabled. Pencil bookmarks removed."),
                                    timeout = 3,
                                })
                            end
                        end,
                    },
                },
                separator = true,
            },
            {
                text = _("Input debug mode"),
                help_text = _("Enable detailed logging of input events to help diagnose stylus detection issues."),
                checked_func = function()
                    return self.input_debug_mode
                end,
                callback = function()
                    self.input_debug_mode = not self.input_debug_mode
                    self:saveSettings()
                    if self.input_debug_mode then
                        -- Initialize debug logging
                        self:initDebugLog()
                        UIManager:show(InfoMessage:new{
                            text = T(_("Input debug mode enabled.\n\nLog file: %1\n\nUse both pen tip and eraser end, then check the log."), self:getDebugLogPath()),
                        })
                    else
                        UIManager:show(InfoMessage:new{
                            text = _("Input debug mode disabled."),
                        })
                    end
                end,
            },
            {
                text = _("Clear debug log"),
                enabled_func = function()
                    return self.input_debug_mode
                end,
                callback = function()
                    self:clearDebugLog()
                    UIManager:show(InfoMessage:new{
                        text = _("Debug log cleared. Ready to capture new input events."),
                        timeout = 2,
                    })
                end,
            },
            {
                text = _("Show annotation status"),
                callback = function()
                    self:showAnnotationStatus()
                end,
            },
        },
    }
end

-- Show current annotation status for debugging
function Pencil:showAnnotationStatus()
    local page = self:getCurrentPage()
    local page_strokes = self.page_strokes[page] and #self.page_strokes[page] or 0
    local filepath = self:getStrokesFilePath() or "not available"

    -- Show all pages with strokes for debugging
    local pages_info = ""
    for p, indices in pairs(self.page_strokes) do
        pages_info = pages_info .. string.format("\n  %s (%s): %d", tostring(p), type(p), #indices)
    end
    if pages_info == "" then
        pages_info = "\n  (none)"
    end

    -- Stylus callback status
    local Input = Device.input
    local pen_slot = Input and Input.pen_slot or "N/A"
    local stylus_callback_status = self.stylus_callback_registered and "registered" or "not registered"
    local pen_down_status = self.pen_down and "YES" or "no"

    local status_text = T(_([[Pencil Annotation Status

Selected tool: %1
Total strokes: %2
Strokes on this page: %3
Current page: %4 (%5)
Storage file: %6
Enabled: %7

Stylus callback: %9
Pen slot: %10
Pen down: %11

Side button: tap to toggle pen/eraser, hold+drag to highlight.

Enable "Input debug mode" to log raw events for diagnosis.

Pages with strokes:%8]]),
        self.current_tool,
        #self.strokes,
        page_strokes,
        tostring(page),
        type(page),
        filepath,
        self:isEnabled() and _("Yes") or _("No"),
        pages_info,
        stylus_callback_status,
        tostring(pen_slot),
        pen_down_status
    )

    UIManager:show(InfoMessage:new{
        text = status_text,
    })
end

-- Handle stylus button press (down event)
-- Side button behavior:
--   - Hold + drag = temporarily highlight, then return to original tool
--   - Quick press (no drawing while held) = toggle between pen and eraser
function Pencil:onStylusButtonPress()
    if not self:isEnabled() or self:isOverlayActive() then return false end

    self.side_button_down = true
    -- KOReader delivers the button's key event after the pen reports it
    -- handles straight away, so a stroke drawn with the button held may
    -- already be under way: then the press was used, and releasing it
    -- mustn't toggle pen/eraser.
    self.side_button_used_for_highlight = self.pen_down or false

    logger.dbg("Pencil: side button pressed")
    return true
end

-- Handle stylus button release (up event)
function Pencil:onStylusButtonRelease()
    if not self:isEnabled() or self:isOverlayActive() then return false end

    local was_down = self.side_button_down
    self.side_button_down = false

    -- If the button was NOT used for highlighting (no drawing while held),
    -- treat it as a quick press to toggle between pen and eraser
    if was_down and not self.side_button_used_for_highlight then
        logger.dbg("Pencil: side button quick press - toggling pen/eraser")
        self:togglePenEraser()
    else
        -- Was used for highlighting - show brief feedback that we're back to normal
        logger.dbg("Pencil: highlight complete, back to", self.current_tool)
    end

    self.side_button_used_for_highlight = false
    return true
end

-- Toggle between pen and eraser
function Pencil:togglePenEraser()
    local old_tool = self.current_tool
    local new_tool
    if self.current_tool == TOOL_ERASER then
        new_tool = TOOL_PEN
    else
        new_tool = TOOL_ERASER
    end

    self.current_tool = new_tool
    self:saveSettings()
    logger.dbg("Pencil: toggled from", old_tool, "to", new_tool)

    -- Show brief visual feedback
    UIManager:show(InfoMessage:new{
        text = T(_("Tool: %1"), new_tool),
        timeout = 0.5,
    })
end

-- Handle stylus button and tool events
function Pencil:onKeyPress(key)
    local key_str = tostring(key)

    -- Always log key events when debug mode is on (even if not enabled)
    if self.input_debug_mode then
        self:writeDebugLog(string.format("KEY PRESS: %s key.key=%s", key_str, tostring(key.key)))
    end

    -- Hardware Eraser button - works regardless of pencil enabled state
    if (not self.swap_eraser_and_highlighter and key.key == "Eraser") then
        logger.info("Pencil: Eraser button PRESSED")
        self.eraser_button_active = true
        self.eraser_button_deleted = {}
        return true
    end

    -- BTN_TOOL_RUBBER - physical eraser end - works regardless of pencil enabled state
    if (self.swap_eraser_and_highlighter and (key_str:match("Highlighter") or key_str:match("Stylus"))) or (not self.swap_eraser_and_highlighter and (key_str:match("BTN_TOOL_RUBBER") or key_str:match("ToolRubber"))) then
        logger.info("Pencil: BTN_TOOL_RUBBER press - activating eraser mode")
        self.eraser_button_active = true
        self.eraser_button_deleted = {}
        self.eraser_tool_active = true
        return true
    end

    -- BTN_TOOL_PEN - pen tip - deactivate eraser mode
    if key_str:match("BTN_TOOL_PEN") or key_str:match("ToolPen") then
        logger.info("Pencil: BTN_TOOL_PEN press - deactivating eraser mode")
        if self.eraser_button_active and self.eraser_button_deleted and #self.eraser_button_deleted > 0 then
            -- Save any pending eraser deletions before switching to pen
            table.insert(self.undo_stack, { type = "delete", strokes = self.eraser_button_deleted })
            self:saveStrokes()
        end
        self.eraser_button_active = false
        self.eraser_button_deleted = nil
        self.eraser_tool_active = false
        return true
    end

    if not self:isEnabled() or self:isOverlayActive() then return false end

    -- BTN_STYLUS (331) - side button on stylus (mapped to "Eraser" on Kobo)
    -- BTN_STYLUS2 (332) - second side button (mapped to "Highlighter" on Kobo)
    if (self.swap_eraser_and_highlighter and key.key == "Eraser") or (not self.swap_eraser_and_highlighter and (key_str:match("Highlighter") or key_str:match("Stylus"))) then
        logger.dbg("Pencil: Stylus button press detected:", key_str)
        return self:onStylusButtonPress()
    end
    return false
end

function Pencil:onKeyRelease(key)
    local key_str = tostring(key)

    -- Always log key events when debug mode is on (even if not enabled)
    if self.input_debug_mode then
        self:writeDebugLog(string.format("KEY RELEASE: %s key.key=%s", key_str, tostring(key.key)))
    end

    -- Hardware Eraser button released
    if key.key == "Eraser" and self.eraser_button_active then
        logger.info("Pencil: Eraser button RELEASED")
        self.eraser_button_active = false
        if self.eraser_button_deleted and #self.eraser_button_deleted > 0 then
            table.insert(self.undo_stack, { type = "delete", strokes = self.eraser_button_deleted })
            self:saveStrokes()
        end
        self.eraser_button_deleted = nil
        UIManager:setDirty(self.view, "ui")
        return true
    end

    -- BTN_TOOL_RUBBER released (eraser end moved away) - works regardless of pencil enabled state
    if key_str:match("BTN_TOOL_RUBBER") or key_str:match("ToolRubber") then
        logger.info("Pencil: BTN_TOOL_RUBBER release - deactivating eraser mode")
        if self.eraser_button_active and self.eraser_button_deleted and #self.eraser_button_deleted > 0 then
            table.insert(self.undo_stack, { type = "delete", strokes = self.eraser_button_deleted })
            self:saveStrokes()
        end
        self.eraser_button_active = false
        self.eraser_button_deleted = nil
        self.eraser_tool_active = false
        UIManager:setDirty(self.view, "ui")
        return true
    end

    -- BTN_TOOL_PEN released
    if key_str:match("BTN_TOOL_PEN") or key_str:match("ToolPen") then
        logger.dbg("Pencil: BTN_TOOL_PEN release detected")
        return true
    end

    if not self:isEnabled() or self:isOverlayActive() then return false end

    -- Side button released
    if key_str:match("Highlighter") or key_str:match("Stylus") then
        logger.dbg("Pencil: Stylus button release detected:", key_str)
        return self:onStylusButtonRelease()
    end
    return false
end

-- Undo last stroke
function Pencil:undoLastStroke()
    if #self.undo_stack == 0 then return end

    local last_action = table.remove(self.undo_stack)
    if last_action.type == "add" then
        -- Remove the stroke that was added
        local stroke_idx = last_action.stroke_idx
        if stroke_idx and self.strokes[stroke_idx] then
            table.remove(self.strokes, stroke_idx)
            self:rebuildPageIndex()
            self:rebuildAnnotationGroups()
            self:saveStrokes()
            UIManager:setDirty(self.view, "ui")
        end
    elseif last_action.type == "delete" then
        -- Restore deleted strokes
        for _, stroke in ipairs(last_action.strokes) do
            table.insert(self.strokes, stroke)
        end
        self:rebuildPageIndex()
        self:rebuildAnnotationGroups()
        self:saveStrokes()
        UIManager:setDirty(self.view, "ui")
    end
end

function Pencil:setupPenInput()
    if self.touch_zones_registered then return end

    logger.dbg("Pencil: setting up touch zones")

    -- Setup stylus callback for lowest latency pen capture
    self:setupStylusCallback()
    -- Register touch zones through the UI so they're in the active gesture hierarchy
    -- We need to override ALL gestures that might interfere with drawing
    self.ui:registerTouchZones({
        {
            -- Touch gesture fires IMMEDIATELY on first contact - critical for capturing stroke start
            id = "pencil_draw_touch",
            ges = "touch",
            screen_zone = {
                ratio_x = 0, ratio_y = 0,
                ratio_w = 1, ratio_h = 1,
            },
            overrides = {},
            handler = function(ges)
                return self:onDrawTouch(ges)
            end,
        },
        {
            id = "pencil_draw_tap",
            ges = "tap",
            screen_zone = {
                ratio_x = 0, ratio_y = 0,
                ratio_w = 1, ratio_h = 1,
            },
            overrides = {
                "tap_forward",
                "tap_backward",
                "readerfooter_tap",
                "readerconfigmenu_tap",
                "readerhighlight_tap",
                "readermenu_tap",
                "paging_tap",
                "rolling_tap",
            },
            handler = function(ges)
                return self:onDrawTap(ges)
            end,
        },
        {
            id = "pencil_draw_hold",
            ges = "hold",
            screen_zone = {
                ratio_x = 0, ratio_y = 0,
                ratio_w = 1, ratio_h = 1,
            },
            overrides = {
                "readerhighlight_hold",
                "readerfooter_hold",
            },
            handler = function(ges)
                return self:onDrawHold(ges)
            end,
        },
        {
            id = "pencil_draw_pan",
            ges = "pan",
            screen_zone = {
                ratio_x = 0, ratio_y = 0,
                ratio_w = 1, ratio_h = 1,
            },
            overrides = {
                "paging_pan",
                "rolling_pan",
                "paging_swipe",
                "rolling_swipe",
                "readerhighlight_pan",
            },
            handler = function(ges)
                return self:onDrawPan(ges)
            end,
        },
        {
            id = "pencil_draw_pan_release",
            ges = "pan_release",
            screen_zone = {
                ratio_x = 0, ratio_y = 0,
                ratio_w = 1, ratio_h = 1,
            },
            overrides = {
                "paging_pan_release",
                "rolling_pan_release",
                "readerhighlight_pan_release",
            },
            handler = function(ges)
                return self:onDrawPanRelease(ges)
            end,
        },
        {
            id = "pencil_draw_swipe",
            ges = "swipe",
            screen_zone = {
                ratio_x = 0, ratio_y = 0,
                ratio_w = 1, ratio_h = 1,
            },
            overrides = {
                "paging_swipe",
                "rolling_swipe",
                "readerhighlight_swipe",
            },
            handler = function(ges)
                return self:onDrawSwipe(ges)
            end,
        },
    })
    self.touch_zones_registered = true
end

function Pencil:teardownPenInput()
    if not self.touch_zones_registered then return end

    -- Teardown stylus callback
    self:teardownStylusCallback()

    self.ui:unRegisterTouchZones({
        { id = "pencil_draw_touch" },  -- Must unregister touch zone too
        { id = "pencil_draw_tap" },
        { id = "pencil_draw_hold" },
        { id = "pencil_draw_pan" },
        { id = "pencil_draw_pan_release" },
        { id = "pencil_draw_swipe" },
    })
    self.touch_zones_registered = false
end

-- Handle swipe gestures (block them when drawing mode is active)
function Pencil:onDrawSwipe(ges)
    if not self:isEnabled() or self:isOverlayActive() then return false end

    -- If raw input detected pen, block swipe to prevent page turns
    if self.pen_down then return true end

    -- Fallback: check pen input via gesture system's slot data
    local is_pen, _ = self:isPenInput(ges)
    if not is_pen then return false end

    -- Block the swipe - we don't want page turns while drawing
    return true
end

-- Handle tip long press (hold gesture)
function Pencil:onDrawHold(ges)
    if not self:isEnabled() or self:isOverlayActive() then return false end

    -- If raw input detected pen, block hold to prevent reader highlight mode
    if self.pen_down then return true end

    -- Fallback: check pen input via gesture system's slot data
    local is_pen, _ = self:isPenInput(ges)
    if not is_pen then return false end

    -- Block pen hold gestures while drawing mode is active
    return true
end

-- Union a finished stroke's (screen-space) bounding box into the pending
-- post-lift refresh region, expanded by the stroke's own half-width plus a
-- small antialiasing pad. The delayed refresh then only updates this region.
function Pencil:accumulateRefreshBbox(stroke)
    if not stroke then return end
    local bbox = PencilGeometry.computeStrokeBbox(stroke)
    if not bbox then return end
    local margin = math.floor((stroke.width or 0) / 2) + 4
    bbox = PencilGeometry.bboxExpand(bbox, margin)
    if self.pending_refresh_bbox then
        self.pending_refresh_bbox = PencilGeometry.bboxUnion(self.pending_refresh_bbox, bbox)
    else
        self.pending_refresh_bbox = bbox
    end
end

-- Schedule a delayed refresh after writing stops
function Pencil:scheduleDelayedRefresh()
    -- Cancel any existing pending refresh
    self:cancelPendingRefresh()

    -- Schedule new refresh. Store the closure itself (not scheduleIn's nil
    -- return) so cancelPendingRefresh can actually unschedule it.
    local action
    action = function()
        if self.pending_refresh == action then self.pending_refresh = nil end
        local bbox = self.pending_refresh_bbox
        self.pending_refresh_bbox = nil
        if bbox then
            -- Scope the fast refresh to the region the recent strokes touched.
            -- The view still repaints fully, but the slow e-ink update is small.
            bbox = PencilGeometry.bboxClampToScreen(bbox, Screen:getWidth(), Screen:getHeight())
            local rw = bbox.x1 - bbox.x0
            local rh = bbox.y1 - bbox.y0
            if rw > 0 and rh > 0 then
                -- The ink is already in the screen buffer: only its waveform
                -- needs upgrading (anti-aliasing, colour), not a repaint of
                -- the page.
                Screen:refreshUI(bbox.x0, bbox.y0, rw, rh)
            else
                UIManager:setDirty(self.view, "fast")
            end
        else
            -- No tracked region (e.g. refresh scheduled without a finished
            -- stroke) — fall back to a full-view fast refresh.
            UIManager:setDirty(self.view, "fast")
        end
        logger.dbg("Pencil: delayed refresh triggered")
    end
    self.pending_refresh = action
    UIManager:scheduleIn(self.refresh_delay_ms / 1000, action)
end

-- Cancel pending refresh (called when new stroke starts)
function Pencil:cancelPendingRefresh()
    if self.pending_refresh then
        UIManager:unschedule(self.pending_refresh)
        self.pending_refresh = nil
    end
end

-- Schedule a debounced save + bookmark flush after writing pauses.
-- NOTE: UIManager:scheduleIn() returns nil, and UIManager:unschedule() matches
-- by the action function reference. So we must store the closure itself in
-- pending_save (not scheduleIn's return value) or cancelPendingSave can never
-- cancel it — which previously caused one full save to fire per stroke.
function Pencil:scheduleDeferredWork()
    self:cancelPendingSave()
    local action
    action = function()
        if self.pending_save == action then self.pending_save = nil end
        -- Never under the pen: try again once the stroke is done.
        if self.current_stroke then
            return self:scheduleDeferredWork()
        end
        self:flushDirtyGroups()
        self:saveStrokes()
    end
    self.pending_save = action
    UIManager:scheduleIn(self.save_delay_ms / 1000, action)
end

function Pencil:cancelPendingSave()
    if self.pending_save then
        UIManager:unschedule(self.pending_save)
        self.pending_save = nil
    end
end

-- Run any pending deferred work immediately. Called before close, page change,
-- or any path that must persist state synchronously.
function Pencil:flushDeferredWork()
    if not self.pending_save and not (self.dirty_groups and next(self.dirty_groups)) then
        return
    end
    self:cancelPendingSave()
    self:flushDirtyGroups()
    self:saveStrokes()
end

-- Sync bookmarks for any groups marked dirty since the last flush. No-op when
-- the experimental bookmark sync feature is off or nothing is pending.
function Pencil:flushDirtyGroups()
    if not self.dirty_groups then return end
    if not self.experimental_bookmark_sync then
        self.dirty_groups = nil
        return
    end
    for _, group in pairs(self.dirty_groups) do
        self:syncGroupBookmark(group)
    end
    self.dirty_groups = nil
end

-- Reset color picker tracking (called when pen moves too far)
function Pencil:resetColorPickerTracking()
    self.color_picker_start_x = nil
    self.color_picker_start_y = nil
    self.color_picker_start_time = nil
end

-- Check if color picker should be shown (called periodically while pen is down)
function Pencil:checkColorPickerTrigger()
    -- Off unless chosen in the menu: resting the pen while writing would
    -- open it.
    if not self.hold_opens_pen_menu then return end
    if not self.color_picker_start_time then return end
    if self.color_picker_showing then return end

    local elapsed_ms = time.to_ms(time.now() - self.color_picker_start_time)
    if elapsed_ms >= COLOR_PICKER_DELAY_MS then
        -- Time elapsed without moving too far - show color picker
        self:showPenMenu(self.pen_x, self.pen_y)
        self:resetColorPickerTracking()
    end
end

-- Schedule periodic check for color picker trigger
function Pencil:scheduleColorPickerCheck()
    if self.color_picker_check_pending then
        UIManager:unschedule(self.color_picker_check_pending)
    end

    local plugin = self
    -- Check every 100ms for trigger
    self.color_picker_check_pending = UIManager:scheduleIn(0.1, function()
        plugin.color_picker_check_pending = nil
        if plugin.pen_down and plugin.color_picker_start_time and not plugin.color_picker_showing then
            plugin:checkColorPickerTrigger()
            -- Schedule next check if still waiting
            if plugin.color_picker_start_time then
                plugin:scheduleColorPickerCheck()
            end
        end
    end)
end

-- Cancel color picker check
function Pencil:cancelColorPickerTimer()
    if self.color_picker_check_pending then
        UIManager:unschedule(self.color_picker_check_pending)
        self.color_picker_check_pending = nil
    end
    self:resetColorPickerTracking()
end

-- The pen menu: a row of tools (pen, highlight, eraser), one of colours
-- and one of widths (black bars as thick as the stroke, in device pixels).
-- Rows and hit-testing come from lib/penmenu; this draws them.
local PenMenuWidget = InputContainer:extend {
    rows = nil, -- from PenMenu.rows
    callback = nil, -- callback(item), item from PenMenu.rows
    close_callback = nil,
}

-- The button for one item: a labelled box for a tool, a swatch for a
-- colour, a bar for a width. A thick border marks the current choice.
function PenMenuWidget:_makeButton(item, w, h)
    local border_size = item.selected and Size.border.thick * 3 or Size.border.thick
    local inner = Geom:new{ w = w - border_size * 2, h = h - border_size * 2 }
    local content, background, border_color = nil, Blitbuffer.COLOR_WHITE, Blitbuffer.COLOR_BLACK
    if item.kind == "tool" then
        content = CenterContainer:new{
            dimen = inner,
            TextWidget:new{ text = _(item.label), face = Font:getFace("cfont", 18) },
        }
    elseif item.kind == "width" then
        -- We deliberately don't scale by Screen:scaleBySize: strokes are
        -- drawn in raw pixels, so the bar shows the real line weight.
        content = CenterContainer:new{
            dimen = inner,
            FrameContainer:new{
                padding = 0, margin = 0, bordersize = 0,
                background = Blitbuffer.COLOR_BLACK,
                WidgetContainer:new{ dimen = Geom:new{ w = math.floor(inner.w * 0.7), h = item.width_value } },
            },
        }
    else
        background = item.color_value
        if Screen.night_mode and item.name ~= "Black" and item.name ~= "Gray" then
            background = background:invert()
        end
        if item.name == "Black" then border_color = Blitbuffer.Color8(0x44) end
        content = WidgetContainer:new{ dimen = inner }
    end
    local button = InputContainer:new{
        dimen = Geom:new{ w = w, h = h },
        FrameContainer:new{
            width = w, height = h, padding = 0, margin = 0,
            bordersize = border_size, color = border_color, background = background,
            content,
        },
    }
    item.button = button
    local widget = self
    button.ges_events = {
        TapSelect = { GestureRange:new{ ges = "tap", range = function() return button.dimen end } },
    }
    button.onTapSelect = function()
        widget:choose(item)
        return true
    end
    return button
end

function PenMenuWidget:init()
    local size = Screen:scaleBySize(36)
    local tool_w = Screen:scaleBySize(100)
    local spacing = Screen:scaleBySize(8)
    local row_gap = Screen:scaleBySize(10)
    local padding = Screen:scaleBySize(10)
    local column = VerticalGroup:new{ align = "center" }
    for r, row in ipairs(self.rows) do
        if r > 1 then table.insert(column, VerticalSpan:new{ width = row_gap }) end
        local group = HorizontalGroup:new{ align = "center" }
        for i, item in ipairs(row) do
            if i > 1 then table.insert(group, HorizontalSpan:new{ width = spacing }) end
            table.insert(group, self:_makeButton(item, item.kind == "tool" and tool_w or size, size))
        end
        table.insert(column, group)
    end
    self.frame = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = Size.border.window,
        padding = padding,
        column,
    }
    self[1] = self.frame
    self.dimen = self.frame:getSize()
    -- A tap outside closes the menu.
    self.ges_events = {
        TapCloseOutside = {
            GestureRange:new{
                ges = "tap",
                range = function() return Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() } end,
            },
        },
    }
end

function PenMenuWidget:choose(item)
    if self.callback then self.callback(item) end
    if self.close_callback then self.close_callback() end
end

function PenMenuWidget:paintTo(bb, x, y)
    -- Painted where it was placed (dimen); each button records its box.
    self.frame:paintTo(bb, self.dimen.x or x, self.dimen.y or y)
    for _, row in ipairs(self.rows) do
        for _, item in ipairs(row) do
            local d = item.button and item.button.dimen
            item.box = d and { x = d.x, y = d.y, w = d.w, h = d.h } or nil
        end
    end
end

-- A pen tap: chooses the item under it, closes the menu if it's outside.
-- Always consumed, so it never draws.
function PenMenuWidget:handlePenTap(x, y)
    local d = self.dimen
    if not (d and x >= d.x and x < d.x + d.w and y >= d.y and y < d.y + d.h) then
        if self.close_callback then self.close_callback() end
        return true
    end
    local item = PenMenu.hit(self.rows, x, y)
    if item then self:choose(item) end
    return true
end

function PenMenuWidget:onTapCloseOutside(_, ges)
    local d = self.dimen
    if ges and ges.pos and d then
        local x, y = ges.pos.x, ges.pos.y
        if x >= d.x and x < d.x + d.w and y >= d.y and y < d.y + d.h then
            return false -- a button's own tap handles it
        end
    end
    if self.close_callback then self.close_callback() end
    return true
end

function PenMenuWidget:onCloseWidget()
    UIManager:setDirty(nil, "ui", self.dimen)
end

-- Shows the pen menu near (x, y), or in the middle of the screen.
function Pencil:showPenMenu(x, y)
    if self.color_picker_showing then return end

    -- Discard any current stroke made while holding still to open the menu.
    if self.current_stroke then
        self.current_stroke = nil
        self.view:paintTo(Screen.bb, 0, 0)
        self:paintTo(Screen.bb, 0, 0)
        Screen:refreshUI(0, 0, Screen:getWidth(), Screen:getHeight())
    end

    self.color_picker_showing = true
    local plugin = self
    local menu = PenMenuWidget:new{
        rows = PenMenu.rows(self.available_colors, self.available_widths, {
            tool = self.current_tool,
            color_name = self.tool_settings[TOOL_PEN].color_name,
            width = self.tool_settings[TOOL_PEN].width,
        }),
        -- No message after a choice: one would keep the pen from writing
        -- while it shows, and the menu marked the choice.
        callback = function(item)
            if item.kind == "tool" then
                plugin:setTool(item.tool, true)
            elseif item.kind == "width" then
                plugin:setPenWidth(item.width_value)
            else
                plugin:setPenColor(item.color_value, item.name)
            end
        end,
        close_callback = function()
            plugin.color_picker_showing = false
            UIManager:close(plugin.color_picker_widget)
            plugin.color_picker_widget = nil
            UIManager:setDirty(plugin.view, "ui")
        end,
    }

    -- Above the pen if there's room, else below; on screen either way.
    local size = menu.dimen
    local margin = 10
    x = x or Screen:getWidth() / 2
    y = y or (Screen:getHeight() + size.h) / 2 + Screen:scaleBySize(30)
    local mx = math.max(margin, math.min(x - size.w / 2, Screen:getWidth() - size.w - margin))
    local my = y - size.h - Screen:scaleBySize(30)
    if my < margin then my = y + Screen:scaleBySize(30) end
    my = math.max(margin, math.min(my, Screen:getHeight() - size.h - margin))
    menu.dimen.x, menu.dimen.y = math.floor(mx), math.floor(my)

    self.color_picker_widget = menu
    UIManager:show(menu)
    UIManager:setDirty(menu, "ui")
end

function Pencil:setPenColor(color, color_name)
    self.tool_settings[TOOL_PEN].color = color
    self.tool_settings[TOOL_PEN].color_name = color_name
    logger.info("Pencil: setPenColor - color_name =", color_name)
    self:saveSettings()
end

-- Set pen width (from the pen menu).
function Pencil:setPenWidth(width)
    self.tool_settings[TOOL_PEN].width = width
    logger.info("Pencil: setPenWidth - width =", width)
    self:saveSettings()
end

-- Handle initial touch - fires IMMEDIATELY on first contact
-- This is critical for capturing the start of strokes without delay
-- NOTE: For pen/highlighter, raw input hook handles drawing directly for lowest latency
-- This handler blocks gestures and is a backup if raw input not working
function Pencil:onDrawTouch(ges)
    if not self:isEnabled() or self:isOverlayActive() then return false end

    -- Check if this is a finger touch (not pen) - let gesture system handle it
    local is_pen, _ = self:isPenInput(ges)
    if not is_pen then
        return false
    end

    -- Check if raw input hook detected pen - if so, block gesture but don't duplicate
    -- This is the primary pen detection method (lowest latency)
    if self.pen_down then
        -- Raw input is handling drawing - just block the gesture
        self:cancelPendingRefresh()
        return true
    end

    -- Fallback: check pen input via gesture system's slot data
    local is_pen, is_eraser_end, is_highlighter = self:isPenInput(ges)
    if not is_pen then return false end

    -- Cancel any pending refresh - user is still writing
    self:cancelPendingRefresh()

    local effective_tool = self:getEffectiveTool(is_eraser_end, is_highlighter)

    -- For eraser, we handle in pan (need movement to erase)
    if effective_tool == TOOL_ERASER then
        return true  -- Block but don't start stroke
    end

    -- Fallback: handle via gesture system if raw input not working
    local page = self:getCurrentPage()

    -- If side button is held for highlighting
    if self.side_button_down then
        self.side_button_used_for_highlight = true
    end

    -- Start new stroke immediately with first point
    local tool_settings = self.tool_settings[effective_tool] or self.tool_settings[TOOL_PEN]
    self.current_stroke = {
        page = page,
        tool = effective_tool,
        points = { { x = ges.pos.x, y = ges.pos.y } },
        width = tool_settings.width,
        color = tool_settings.color,
        color_name = tool_settings.color_name,
        alpha = tool_settings.alpha,
        datetime = os.time(),
    }

    -- Draw first point to framebuffer - NO REFRESH during drawing
    -- E-ink displays show "ghost" pixels when framebuffer changes, providing visual feedback
    -- Refresh only happens after user stops writing (delayed refresh)
    local width = tool_settings.width
    local color = tool_settings.color
    local half_w = math.floor(width / 2)
    Screen.bb:paintRectRGB32(ges.pos.x - half_w, ges.pos.y - half_w, width, width, color)

    return true
end

-- Check if this is a stylus/pen event (not finger)
-- Returns: is_pen (boolean), is_eraser_end (boolean), is_highlighter (boolean)
function Pencil:isPenInput(ges)
    if Device:isEmulator() then
        return true, false, false
    end

    local Input = Device.input
    if not Input or not Input.pen_slot then
        return false, false, false
    end

    local TOOL_TYPE_PEN = 1
    local TOOL_TYPE_ERASER = 2
    local TOOL_TYPE_HIGHLIGHTER = 3

    local pen_slot_data = Input:getMtSlot(Input.pen_slot)
    if pen_slot_data and pen_slot_data.id and pen_slot_data.id ~= -1 then
        if pen_slot_data.tool == TOOL_TYPE_PEN then
            return true, false, false
        elseif pen_slot_data.tool == TOOL_TYPE_ERASER then
            return true, true, false
        elseif pen_slot_data.tool == TOOL_TYPE_HIGHLIGHTER then
            return true, false, true
        end
    end

    return false, false, false
end

-- Get the effective tool (considers physical eraser end and side button)
function Pencil:getEffectiveTool(is_eraser_end, is_highlighter)
    -- Check both the tool type detection AND the BTN_TOOL_RUBBER state
    if self.eraser_tool_active or ((self.swap_eraser_and_highlighter and is_highlighter) or (not self.swap_eraser_and_highlighter and is_eraser_end)) then
        return TOOL_ERASER
    end

    -- Side button held = highlighter mode (for hold+drag highlighting)
    if self.side_button_down or ((self.swap_eraser_and_highlighter and is_eraser_end) or (not self.swap_eraser_and_highlighter and is_highlighter)) then
        return TOOL_HIGHLIGHTER
    end

    return self.current_tool
end

-- Called on tap - create a dot or erase at point
function Pencil:onDrawTap(ges)
    if not self:isEnabled() or self:isOverlayActive() then return false end

    -- If raw input detected pen recently, block tap to prevent navigation
    -- Note: pen_down will be false by tap time, but we may have just drawn
    -- We should block taps if there's a current stroke or recent drawing
    if self.current_stroke then
        return true  -- Block tap while stroke in progress
    end

    -- Rotation badge hit-test: consume taps (pen or finger) over the camera
    -- badge of a stale-rotation annotation and open its saved image.
    if ges and ges.pos then
        local hit = self:findGroupBadgeAtPoint(ges.pos.x, ges.pos.y)
        if hit then
            logger.info("Pencil: badge tap hit group", hit.id,
                "at (", ges.pos.x, ",", ges.pos.y, ")")
            self:showGroupImagePreview(hit)
            return true
        end
    end

    -- Check if finger tap - let gesture system handle it
    local is_pen, is_eraser_end, is_highlighter = self:isPenInput(ges)
    if not is_pen then
        return false
    end

    local page = self:getCurrentPage()
    local effective_tool = self:getEffectiveTool(is_eraser_end, is_highlighter)
    logger.dbg("Pencil: onDrawTap - effective_tool =", effective_tool)

    -- Log to debug file for analysis
    self:writeDebugLog(string.format("=== TAP at (%d, %d) ===", ges.pos.x, ges.pos.y))
    self:writeDebugLog(string.format("  is_eraser_end=%s eraser_tool_active=%s effective_tool=%s",
        tostring(is_eraser_end), tostring(self.eraser_tool_active), effective_tool))

    if effective_tool == TOOL_ERASER then
        -- Eraser: delete strokes near tap point
        logger.info("Pencil: eraser tap at", ges.pos.x, ges.pos.y, "page =", page)
        local erased = self:eraseAtPoint(ges.pos.x, ges.pos.y, page)
        if erased then
            logger.info("Pencil: erased", #erased, "strokes")
            table.insert(self.undo_stack, { type = "delete", strokes = erased })
            self:saveStrokes()
            UIManager:setDirty(self.view, "ui")
        else
            logger.info("Pencil: eraser tap found no strokes to erase")
        end
        return true
    end

    -- Pen or Highlighter: create a dot
    local tool_settings = self.tool_settings[effective_tool] or self.tool_settings[TOOL_PEN]
    local stroke = {
        page = page,
        tool = effective_tool,
        points = { { x = ges.pos.x, y = ges.pos.y } },
        width = tool_settings.width,
        color = tool_settings.color,
        alpha = tool_settings.alpha,
        datetime = os.time(),
    }

    table.insert(self.strokes, stroke)
    self:indexStroke(#self.strokes, page)
    self:saveStrokes()

    -- Add to undo stack
    table.insert(self.undo_stack, { type = "add", stroke_idx = #self.strokes })

    -- Draw directly to screen buffer
    self:renderStroke(Screen.bb, stroke)

    -- Direct framebuffer refresh for instant feedback
    local w = stroke.width
    Screen:refreshFast(ges.pos.x - w, ges.pos.y - w, w * 2, w * 2)

    return true
end

-- Called during pan - continues stroke started by onDrawTouch
-- NOTE: For pen/highlighter, raw input hook handles drawing directly for lowest latency
-- This handler blocks gestures and handles eraser mode
function Pencil:onDrawPan(ges)
    if not self:isEnabled() or self:isOverlayActive() then return false end

    -- Check if raw input hook detected pen - if so, block gesture
    -- Raw input handles all drawing; this just needs to block swipe/pan gestures
    if self.pen_down then
        return true  -- Block pan gesture, raw input is drawing
    end

    -- Fallback: check pen input via gesture system's slot data
    local is_pen, is_eraser_end, is_highlighter = self:isPenInput(ges)
    if not is_pen then return false end

    local page = self:getCurrentPage()
    local effective_tool = self:getEffectiveTool(is_eraser_end, is_highlighter)

    -- If side button is held and we're drawing, mark it as used for highlighting
    if self.side_button_down and effective_tool == TOOL_HIGHLIGHTER then
        self.side_button_used_for_highlight = true
    end

    -- Eraser mode: erase along path (raw input doesn't handle eraser)
    if effective_tool == TOOL_ERASER then
        if not self.eraser_deleted then
            self.eraser_deleted = {}
        end

        local deleted = self:eraseAtPoint(ges.pos.x, ges.pos.y, page)
        if deleted then
            for _, stroke in ipairs(deleted) do
                table.insert(self.eraser_deleted, stroke)
            end
            self.view:paintTo(Screen.bb, 0, 0)
            local rx, ry, rw, rh = self:erasedStrokesRefreshRect(deleted)
            if rx then
                Screen:refreshUI(rx, ry, rw, rh)
            else
                Screen:refreshUI()
            end
        end
        return true
    end

    -- Fallback: handle via gesture system if raw input not working
    local tool_settings = self.tool_settings[effective_tool] or self.tool_settings[TOOL_PEN]

    -- Stroke should already exist from onDrawTouch, but handle fallback cases
    if not self.current_stroke or self.current_stroke.page ~= page or self.current_stroke.tool ~= effective_tool then
        -- Fallback: create stroke if touch event was missed or context changed
        logger.dbg("Pencil: onDrawPan creating fallback stroke")
        self.current_stroke = {
            page = page,
            tool = effective_tool,
            points = {},
            width = tool_settings.width,
            color = tool_settings.color,
            color_name = tool_settings.color_name,
            alpha = tool_settings.alpha,
            datetime = os.time(),
        }
        -- Use start_pos if available for the first point
        if ges.start_pos then
            table.insert(self.current_stroke.points, { x = ges.start_pos.x, y = ges.start_pos.y })
        end
    end

    -- Add current point to stroke
    local point = { x = ges.pos.x, y = ges.pos.y }
    table.insert(self.current_stroke.points, point)

    -- Draw the new segment to framebuffer - NO REFRESH during drawing
    -- E-ink shows ghost pixels, refresh happens on pan_release
    local n = #self.current_stroke.points
    local width = self.current_stroke.width
    local color = self.current_stroke.color

    if n >= 2 then
        local p1 = self.current_stroke.points[n - 1]
        local p2 = self.current_stroke.points[n]

        if effective_tool == TOOL_HIGHLIGHTER then
            self:drawHighlighterSegment(Screen.bb, p1.x, p1.y, p2.x, p2.y, width, color)
        else
            self:drawLineSegment(Screen.bb, p1.x, p1.y, p2.x, p2.y, width, color)
        end
    elseif n == 1 then
        local p = self.current_stroke.points[1]
        local half_w = math.floor(width / 2)
        Screen.bb:paintRectRGB32(p.x - half_w, p.y - half_w, width, width, color)
    end

    return true
end

-- Called when pan ends - finalize stroke
-- NOTE: For pen/highlighter, raw input hook may have already finalized the stroke
function Pencil:onDrawPanRelease(ges)
    if not self:isEnabled() or self:isOverlayActive() then return false end

    -- Let finger releases be handled by gesture system
    local is_pen, is_eraser_end, is_highlighter = self:isPenInput(ges)
    if not is_pen then
        return false
    end

    local effective_tool = self:getEffectiveTool(is_eraser_end, is_highlighter)

    -- Log pan end to debug file
    self:writeDebugLog(string.format("=== PAN END at (%d, %d) ===", ges.pos.x, ges.pos.y))
    self:writeDebugLog(string.format("  is_eraser_end=%s eraser_tool_active=%s effective_tool=%s",
        tostring(is_eraser_end), tostring(self.eraser_tool_active), effective_tool))

    -- Handle eraser pan release (raw input doesn't handle eraser)
    if effective_tool == TOOL_ERASER then
        if self.eraser_deleted and #self.eraser_deleted > 0 then
            -- Add deleted strokes to undo stack
            table.insert(self.undo_stack, { type = "delete", strokes = self.eraser_deleted })
            self:saveStrokes()
        end
        -- Always refresh screen after erasing to clear any visual artifacts
        UIManager:setDirty(self.view, "partial")
        self.eraser_deleted = nil
        return true
    end

    -- For pen/highlighter: raw input hook already finalized the stroke
    -- Just consume the event and ensure delayed refresh is scheduled
    if not self.current_stroke then
        -- Raw input already handled it, just schedule refresh if not already pending
        self:scheduleDelayedRefresh()
        return true
    end

    -- Fallback: finalize stroke via gesture system
    if #self.current_stroke.points >= 1 then
        -- Finalize the stroke
        self:anchorStroke(self.current_stroke)
        self:assignMarkup(self.current_stroke)
        table.insert(self.strokes, self.current_stroke)
        self:indexStroke(#self.strokes, self.current_stroke.page)
        self:saveStrokes()

        -- Add to undo stack
        table.insert(self.undo_stack, { type = "add", stroke_idx = #self.strokes })
        self:assignStrokeToGroup(#self.strokes)

        logger.dbg("Pencil: stroke completed with", #self.current_stroke.points, "points")
        self:accumulateRefreshBbox(self.current_stroke)
    end

    self.current_stroke = nil

    -- Schedule delayed refresh - will fire after user stops writing
    -- If user starts another stroke, the refresh will be canceled and rescheduled
    self:scheduleDelayedRefresh()

    return true
end

-- Get current page number (stable reference for both paged and rolling modes)
function Pencil:getCurrentPage()
    if self.ui.paging then
        return self.view.state.page
    else
        -- For rolling/EPUB documents, convert XPointer to stable page number
        local xp = self.ui.document:getXPointer()
        if xp and self.ui.document.getPageFromXPointer then
            return self.ui.document:getPageFromXPointer(xp)
        end
        -- Fallback to XPointer if conversion not available
        return xp
    end
end

-- Index a stroke by page for quick lookup
function Pencil:indexStroke(stroke_idx, page)
    self._shown = nil
    if not self.page_strokes[page] then
        self.page_strokes[page] = {}
    end
    table.insert(self.page_strokes[page], stroke_idx)
end

-- Anchor a stroke to the word nearest its centre (lib/anchor), from the
-- words captured for its page (no call into the document per stroke).
-- Rolling documents only: a paged document's page numbers never change.
-- A stroke drawn before its page was captured is anchored when it is.
function Pencil:anchorStroke(stroke)
    if not stroke or not self.ui.rolling then return end
    -- The layout it's written in, so it's drawn as written there and moved
    -- with its word in another (shownStrokes).
    if stroke.layout == nil then stroke.layout = self:layoutKey() end
    if stroke.anchor then return end
    local capture = self.page_capture
    if not capture or capture.page ~= stroke.page or not capture.words then return end
    local bbox = PencilGeometry.computeStrokeBbox(stroke)
    if not bbox then return end
    local word, box = PencilWords.nearest(capture.words,
        (bbox.x0 + bbox.x1) / 2, (bbox.y0 + bbox.y1) / 2)
    if word then
        stroke.anchor = PencilAnchor.fromWord(bbox, word.pos0, box, self:textColumn())
    end
    -- An underline or circle: the words it marks, so it can be drawn under
    -- or around them on another layout (lib/refit).
    stroke.mark = stroke.mark or PencilRefit.markOf(bbox, capture.words)
end

-- Get an XPointer for a screen-space position on the current rolling-mode
-- page. Used to remember WHERE an annotation lives (so it can be re-resolved
-- to a post-rotation page) rather than just the top of the page it was
-- drawn on. Returns nil for paging docs or when the API is unavailable.
function Pencil:getXPointerAtBboxCenter(bbox)
    if not bbox then return nil end
    if not self.ui.rolling then return nil end
    if not self.ui.document or not self.ui.document.getTextFromPositions then
        return nil
    end
    local cx = math.floor((bbox.x0 + bbox.x1) / 2)
    local cy = math.floor((bbox.y0 + bbox.y1) / 2)
    local ok, range = pcall(self.ui.document.getTextFromPositions,
        self.ui.document, { x = cx, y = cy }, { x = cx, y = cy }, true)
    if ok and range and range.pos0 then
        return range.pos0
    end
    -- Fallback: nearest-line xpointer via the current scroll top.
    if self.ui.document.getXPointer then
        local ok2, xp = pcall(self.ui.document.getXPointer, self.ui.document)
        if ok2 and xp then return xp end
    end
    return nil
end

-- Resolve a group's page number in the current layout. For paging docs (PDF)
-- the saved group.page is stable. For rolling docs (EPUB) page numbers shift
-- with rotation / font / spacing changes, so re-derive from the saved
-- XPointer if we have one. Falls back to the original page number when no
-- XPointer was stored (older groups created before this code shipped).
function Pencil:getGroupCurrentPage(group)
    if not group then return nil end
    if self.ui.rolling and group.xpointer
            and self.ui.document and self.ui.document.getPageFromXPointer then
        local ok, pn = pcall(self.ui.document.getPageFromXPointer,
            self.ui.document, group.xpointer)
        if ok and pn then return pn end
    end
    return group.page
end

-- Lazily store / upgrade an XPointer for rolling-doc groups on the current
-- page. Two paths:
--   1. Legacy group with no xpointer: drop in the page-top xpointer so at
--      least same-rotation matching keeps working.
--   2. Group whose xpointer was stored at page-top (old buggy code) or for
--      any reason isn't marked precise: when we're on the same page AND in
--      the rotation the annotation was captured at, the bbox coords are
--      valid on the current screen, so we can resolve a precise per-bbox
--      xpointer. Mark xpointer_v2 to avoid repeated work.
function Pencil:backfillGroupXPointers()
    if not self.ui.rolling then return end
    if not self.ui.document or not self.ui.document.getXPointer
            or not self.ui.document.getPageFromXPointer then
        return
    end
    local cur_page = self:getCurrentPage()
    local cur_rot = Screen:getRotationMode()
    local cur_xp_top = nil
    local anchored = false
    for _, group in ipairs(self.annotation_groups or {}) do
        if group.page == cur_page then
            local upgraded = false
            if not group.xpointer_v2 and group.bbox
                    and (group.image_rotation == nil
                            or group.image_rotation == cur_rot) then
                local precise = self:getXPointerAtBboxCenter(group.bbox)
                if precise then
                    group.xpointer = precise
                    group.xpointer_v2 = true
                    self.image_data_dirty = true
                    upgraded = true
                end
            end
            if not upgraded and not group.xpointer then
                cur_xp_top = cur_xp_top or self.ui.document:getXPointer()
                if cur_xp_top then
                    group.xpointer = cur_xp_top
                    self.image_data_dirty = true
                end
            end
            -- Strokes from older files have no anchor. While their group's
            -- own XPointer still lands on this page, in the rotation it was
            -- drawn in, the layout is the one they were drawn on.
            if group.xpointer_v2 and group.xpointer
                    and (group.image_rotation == nil or group.image_rotation == cur_rot)
                    and self.ui.document:getPageFromXPointer(group.xpointer) == cur_page then
                local old_markup = nil
                for _, idx in ipairs(group.stroke_indices or {}) do
                    local stroke = self.strokes[idx]
                    -- Only ink in the layout it was written in is where
                    -- it was written.
                    if stroke and not stroke.anchor
                            and (stroke.layout == nil or stroke.layout == self:layoutKey()) then
                        self:anchorStroke(stroke)
                        if stroke.anchor then anchored = true end
                    end
                    -- Ink from before the export: one markup per group,
                    -- taken now that its page is on screen as drawn.
                    if stroke and not stroke.markup then
                        old_markup = old_markup or (group.id:gsub("^pencil_", "m_"))
                        stroke.markup = old_markup
                        anchored = true
                    end
                end
                if old_markup then
                    if self.page_capture and self.page_capture.page == cur_page then
                        self:attachPageCapture()
                    else
                        self:schedulePageCapture(PAGE_CAPTURE_DELAY_S)
                    end
                end
            end
        end
    end
    if anchored then
        self:scheduleDeferredWork()
    end
end

-- Assign a newly-added stroke to an annotation group (or create a new one).
-- Called after a stroke is finalized and inserted into self.strokes.
-- @param stroke_idx number  index of the stroke in self.strokes
-- @param skip_bookmark boolean  if true, skip bookmark sync (used during bootstrap)
function Pencil:assignStrokeToGroup(stroke_idx, skip_bookmark)
    self._shown = nil
    local stroke = self.strokes[stroke_idx]
    if not stroke then return end

    local bbox = PencilGeometry.computeStrokeBbox(stroke)
    if not bbox then return end

    local stroke_time = stroke.datetime or 0
    local best_group = nil

    for _, group in ipairs(self.annotation_groups) do
        if group.page == stroke.page then
            local time_diff = math.abs(stroke_time - (group.datetime_last or group.datetime or 0))
            if time_diff <= GROUP_TIME_THRESHOLD_S then
                local dist = PencilGeometry.bboxDistance(bbox, group.bbox)
                if dist <= GROUP_SPATIAL_THRESHOLD then
                    best_group = group
                    break
                end
            end
        end
    end

    if best_group then
        -- Merge into existing group
        table.insert(best_group.stroke_indices, stroke_idx)
        best_group.bbox = PencilGeometry.bboxUnion(best_group.bbox, bbox)
        best_group.datetime_last = math.max(best_group.datetime_last or 0, stroke_time)
        if not best_group.xpointer and stroke.anchor and stroke.anchor.xpointer then
            best_group.xpointer = stroke.anchor.xpointer
            best_group.xpointer_v2 = true
        end
        -- Update tool to majority
        local pen_count, hl_count = 0, 0
        for _, si in ipairs(best_group.stroke_indices) do
            local s = self.strokes[si]
            if s then
                if s.tool == TOOL_HIGHLIGHTER then hl_count = hl_count + 1
                else pen_count = pen_count + 1 end
            end
        end
        best_group.tool = hl_count > pen_count and TOOL_HIGHLIGHTER or TOOL_PEN
        if not skip_bookmark then
            self:markGroupDirty(best_group)
            -- A merged stroke invalidates the previously captured image (bbox
            -- grew); re-schedule the deferred capture.
            self:removeGroupImage(best_group)
            self:scheduleGroupImageCapture(best_group)
        end
    else
        -- Create new group
        local group = {
            -- Stable: from this stroke alone, never from when groups were
            -- (re)built (lib/store).
            id = PencilStore.groupId(stroke),
            page = stroke.page,
            stroke_indices = { stroke_idx },
            bbox = bbox,
            datetime = stroke_time,
            datetime_last = stroke_time,
            tool = (stroke.tool == TOOL_HIGHLIGHTER) and TOOL_HIGHLIGHTER or TOOL_PEN,
        }
        -- For rolling/EPUB docs, capture an XPointer AT THE ANNOTATION'S
        -- POSITION (bbox center) so we can re-resolve which page the
        -- annotation falls on after rotation / font change. CRITICAL: only
        -- valid when we're actually viewing the page this stroke was drawn
        -- on, because getTextFromPositions reads from the currently
        -- rendered page. During a full rebuild (after erase / undo) we
        -- process strokes from every page; for off-current-page strokes
        -- we skip the xpointer and let getGroupCurrentPage fall back to
        -- the saved group.page number. Backfill upgrades them later.
        -- The stroke's own anchor, recorded when it was drawn, survives any
        -- rebuild; failing that, the text under the box, if on screen.
        if stroke.anchor and stroke.anchor.xpointer then
            group.xpointer = stroke.anchor.xpointer
            group.xpointer_v2 = true
        elseif stroke.page == self:getCurrentPage() then
            local annot_xp = self:getXPointerAtBboxCenter(bbox)
            if annot_xp then
                group.xpointer = annot_xp
                group.xpointer_v2 = true
            end
        end
        table.insert(self.annotation_groups, group)
        if not skip_bookmark then
            self:markGroupDirty(group)
            self:scheduleGroupImageCapture(group)
        end
    end
end

-- Mark a group as needing a bookmark sync on the next deferred-work flush.
-- Keeps the heavy getPageXPointer / annotation insertion off the writing path.
function Pencil:markGroupDirty(group)
    if not self.experimental_bookmark_sync then return end
    self.dirty_groups = self.dirty_groups or {}
    self.dirty_groups[group.id] = group
end

-- Rebuild all annotation groups from scratch by re-running the grouping algorithm
-- on all existing strokes sorted by datetime. Called after erase/undo operations.
function Pencil:rebuildAnnotationGroups()
    self._shown = nil
    local ok, err = pcall(function()
        -- Remove all existing bookmarks for pencil groups, and cancel any
        -- pending image captures (group ids will change).
        for _, group in ipairs(self.annotation_groups) do
            self:removeGroupBookmark(group)
            self:cancelGroupImageCapture(group.id)
        end

        -- Groups before the rebuild, by id: one that comes out the same
        -- keeps its saved image (ids are stable, lib/store).
        local before = {}
        for _, group in ipairs(self.annotation_groups) do
            before[group.id] = group
        end

        self.annotation_groups = {}

        -- Build list of {index, datetime} sorted by datetime
        local sorted = {}
        for i, stroke in ipairs(self.strokes) do
            table.insert(sorted, { idx = i, dt = stroke.datetime or 0 })
        end
        table.sort(sorted, function(a, b) return a.dt < b.dt end)

        -- Re-assign each stroke
        for _, entry in ipairs(sorted) do
            self:assignStrokeToGroup(entry.idx)
        end

        for _, group in ipairs(self.annotation_groups) do
            local old = before[group.id]
            if PencilStore.sameGroup(old, group) then
                self:cancelGroupImageCapture(group.id)
                group.image_path = old.image_path
                group.image_rotation = old.image_rotation
            end
            if old and not group.xpointer and old.xpointer_v2 then
                group.xpointer = old.xpointer
                group.xpointer_v2 = true
            end
        end
    end)
    if not ok then
        logger.warn("Pencil: rebuildAnnotationGroups failed:", err)
        self.annotation_groups = self.annotation_groups or {}
    end
    -- Any JPEGs whose stem no longer matches a current group.id are now stale.
    self:purgeOrphanImages()
end

-- Get page number for bookmark display (always numeric).
function Pencil:getPageNumber(page_ref)
    if type(page_ref) == "number" then
        return page_ref
    end
    -- For XPointer (rolling docs), try to convert
    if self.ui.document and self.ui.document.getPageFromXPointer then
        local pn = self.ui.document:getPageFromXPointer(page_ref)
        if pn then return pn end
    end
    return 0
end

-- Get the bookmark page reference for a group.
-- For paging mode (PDF), this is the page number.
-- For rolling mode (EPUB), this must be an XPointer.
function Pencil:getBookmarkPageRef(group_page)
    if self.ui.rolling and self.ui.document and self.ui.document.getPageXPointer then
        -- group.page is a number (from getCurrentPage), convert back to XPointer
        return self.ui.document:getPageXPointer(group_page)
    end
    return group_page
end

-- Sync a group's bookmark into KOReader's annotation system.
function Pencil:syncGroupBookmark(group)
    if not self.experimental_bookmark_sync then return end
    if not self.ui or not self.ui.annotation then
        logger.dbg("Pencil: annotation module not available, skipping bookmark sync")
        return
    end
    if not self.ui.annotation.annotations then
        logger.dbg("Pencil: annotations not loaded yet, skipping bookmark sync")
        return
    end

    local ok, err = pcall(function()
        -- Remove existing bookmark for this group first
        self:removeGroupBookmark(group)

        local pageno = self:getPageNumber(group.page)
        local bookmark_page = self:getBookmarkPageRef(group.page)
        local chapter = ""
        if self.ui.toc and self.ui.toc.getTocTitleByPage then
            chapter = self.ui.toc:getTocTitleByPage(bookmark_page) or ""
        end

        local datetime = group.id  -- use group id as unique datetime key
        group.bookmark_datetime = datetime

        local item = {
            page = bookmark_page,
            datetime = datetime,
            text = string.format("Pencil annotation on page %d", pageno),
            chapter = chapter,
        }

        if self.ui.annotation.addItem then
            self.ui.annotation:addItem(item)
            logger.dbg("Pencil: synced bookmark for group", group.id, "on page", pageno)
        else
            logger.warn("Pencil: annotation.addItem not available")
        end
    end)
    if not ok then
        logger.warn("Pencil: bookmark sync failed:", err)
    end
end

-- Remove a group's bookmark from KOReader's annotation system.
function Pencil:removeGroupBookmark(group)
    if not self.experimental_bookmark_sync then return end
    if not self.ui or not self.ui.annotation then return end
    if not group.bookmark_datetime then return end

    local ok, err = pcall(function()
        local annotations = self.ui.annotation.annotations
        if not annotations then return end

        for i, ann in ipairs(annotations) do
            if ann.datetime == group.bookmark_datetime then
                table.remove(annotations, i)
                logger.dbg("Pencil: removed bookmark for group", group.id)
                return
            end
        end
    end)
    if not ok then
        logger.warn("Pencil: bookmark removal failed:", err)
    end
end

-- Remove ALL pencil bookmarks from KOReader's annotation system.
-- Used before re-syncing to avoid duplicates.
-- Note: always runs regardless of feature flag, so disabling cleans up.
function Pencil:removeAllPencilBookmarks()
    if not self.ui or not self.ui.annotation then return end
    local annotations = self.ui.annotation.annotations
    if not annotations then return end

    -- Remove in reverse order to maintain indices
    for i = #annotations, 1, -1 do
        if annotations[i].datetime and annotations[i].datetime:match("^pencil_") then
            table.remove(annotations, i)
        end
    end
end

-- Sync all annotation groups to bookmarks (used after load/rebuild).
function Pencil:syncAllBookmarks()
    if not self.experimental_bookmark_sync then return end

    -- Clean slate: remove all pencil bookmarks first to avoid duplicates
    self:removeAllPencilBookmarks()

    for _, group in ipairs(self.annotation_groups) do
        self:syncGroupBookmark(group)
    end
    logger.info("Pencil: synced", #self.annotation_groups, "annotation group bookmarks")
end

------------------------------------------------------------------------------
-- Annotation image capture & preview (issue #51)
------------------------------------------------------------------------------

-- Directory holding per-group preview JPEGs for this document.
function Pencil:getImagesDir()
    if not self.ui or not self.ui.doc_settings then return nil end
    local sidecar_dir = self.ui.doc_settings.doc_sidecar_dir
    if not sidecar_dir then return nil end
    return sidecar_dir .. "/pencil_images"
end

function Pencil:ensureImagesDir()
    local dir = self:getImagesDir()
    if not dir then return nil end
    local ok, err = lfs.mkdir(dir)
    if not ok and err ~= "File exists" then
        logger.warn("Pencil: failed to create images dir:", err)
        return nil
    end
    return dir
end

function Pencil:getGroupImagePath(group)
    local dir = self:getImagesDir()
    if not dir or not group or not group.image_path then return nil end
    return dir .. "/" .. group.image_path
end

-- Render the captured-page-context image for a group into a Blitbuffer and
-- write it as a JPEG. Returns true on success.
function Pencil:captureGroupImage(group)
    if not group or not group.bbox then return false end
    if not self.view or not self.view.paintTo then return false end

    local dir = self:ensureImagesDir()
    if not dir then return false end

    -- Only capture if the group's page matches the current pagination;
    -- otherwise ReaderView would render the wrong content. For rolling docs
    -- this uses the group's XPointer (rotation-stable) when available.
    -- Only in the layout the ink was written in: elsewhere its own
    -- positions don't match the page (shownStrokes moves it).
    local key = self:layoutKey()
    for _, idx in ipairs(group.stroke_indices or {}) do
        local stroke = self.strokes[idx]
        if key and stroke and stroke.layout and stroke.layout ~= key then return false end
    end

    local gpage = self:getGroupCurrentPage(group)
    if gpage ~= self:getCurrentPage() then
        logger.dbg("Pencil: captureGroupImage: page mismatch (group=", tostring(gpage),
            " current=", tostring(self:getCurrentPage()), "), deferring")
        return false
    end

    -- Capture a full-screen-width strip vertically bounded by the bbox + a
    -- small margin. This gives the user enough context (full line of text)
    -- when they preview the annotation from the bookmark list or rotation
    -- badge, instead of a tight crop that just shows the strokes.
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    local rect = PencilGeometry.captureStripRect(
        group.bbox, sw, sh, IMAGE_CAPTURE_V_MARGIN_PX, IMAGE_MIN_HEIGHT_PX)
    local w = math.floor(rect.x1 - rect.x0)
    local h = math.floor(rect.y1 - rect.y0)
    if w < 8 or h < 8 then return false end

    -- Allocate offscreen buffer of the same type as Screen.bb so paintTo writes
    -- pixels in the format ReaderView expects.
    local bb_type = Screen.bb:getType()
    local ok_bb, off_bb = pcall(Blitbuffer.new, w, h, bb_type)
    if not ok_bb or not off_bb then
        logger.warn("Pencil: failed to allocate offscreen buffer for capture")
        return false
    end

    -- Paint the page (and other plugins / highlights / dogear etc.) into the
    -- offscreen buffer. The (-x, -y) offset places the captured page region
    -- at (0, 0) inside off_bb; Blitbuffer paints clip to buffer bounds.
    local x0, y0 = math.floor(rect.x0), math.floor(rect.y0)
    self._capturing = true
    local ok_paint, paint_err = pcall(self.view.paintTo, self.view, off_bb, -x0, -y0)
    self._capturing = false
    if not ok_paint then
        logger.warn("Pencil: ReaderView paint to offscreen failed:", paint_err)
        if off_bb.free then off_bb:free() end
        return false
    end

    -- Render this group's strokes over the painted page background.
    for _, idx in ipairs(group.stroke_indices or {}) do
        local stroke = self.strokes[idx]
        if stroke then
            self:renderStrokeOffset(off_bb, stroke, -x0, -y0)
        end
    end

    -- Downscale if longer side exceeds IMAGE_MAX_DIM (storage / encode budget).
    local final_bb = off_bb
    local longer = math.max(w, h)
    if longer > IMAGE_MAX_DIM and off_bb.scale then
        local scale = IMAGE_MAX_DIM / longer
        local sw_new = math.max(1, math.floor(w * scale))
        local sh_new = math.max(1, math.floor(h * scale))
        local ok_scale, scaled = pcall(off_bb.scale, off_bb, sw_new, sh_new)
        if ok_scale and scaled then
            final_bb = scaled
        end
    end

    -- Encode + write.
    local filename = group.id .. ".jpg"
    local fullpath = dir .. "/" .. filename
    local ok_write, write_err = pcall(final_bb.writeJPG, final_bb, fullpath, IMAGE_JPEG_QUALITY)

    -- Free buffers we own (final_bb might be the same object as off_bb after
    -- skipping the downscale path).
    if final_bb ~= off_bb and final_bb.free then final_bb:free() end
    if off_bb.free then off_bb:free() end

    if not ok_write then
        logger.warn("Pencil: failed to write JPEG:", write_err)
        return false
    end

    group.image_path = filename
    group.image_rotation = Screen:getRotationMode()
    self.image_data_dirty = true
    logger.info("Pencil: captured image for group", group.id, "rotation", group.image_rotation, "->", fullpath)
    return true
end

-- Variant of renderStroke that translates points by (dx, dy) before drawing.
-- Used during capture to render a group's strokes onto an offscreen buffer
-- whose origin corresponds to the bbox top-left.
function Pencil:renderStrokeOffset(bb, stroke, dx, dy)
    if not stroke or not stroke.points or #stroke.points < 1 then return end

    local tool = stroke.tool or TOOL_PEN
    local width = stroke.width or self.tool_settings[tool].width or 3
    local color = stroke.color or self.tool_settings[tool].color or Blitbuffer.COLOR_BLACK

    if Screen.night_mode and stroke.color_name ~= "Black" and stroke.color_name ~= "Gray" then
        color = color:invert()
    end

    local is_highlighter = (tool == TOOL_HIGHLIGHTER)
    if is_highlighter then
        color = stroke.color or Blitbuffer.Color8(0xDD)
    end

    if #stroke.points == 1 then
        local p = stroke.points[1]
        local half_w = math.floor(width / 2)
        bb:paintRectRGB32(p.x + dx - half_w, p.y + dy - half_w, width, width, color)
    else
        for i = 2, #stroke.points do
            local p1 = stroke.points[i - 1]
            local p2 = stroke.points[i]
            if is_highlighter then
                self:drawHighlighterSegment(bb, p1.x + dx, p1.y + dy, p2.x + dx, p2.y + dy, width, color)
            else
                self:drawLineSegment(bb, p1.x + dx, p1.y + dy, p2.x + dx, p2.y + dy, width, color)
            end
        end
    end
end

-- Schedule a deferred capture for the group. If a capture is already pending
-- for this group id, cancel and re-arm so we only capture once after the
-- grouping window has settled.
-- delay (optional): seconds before firing. Defaults to IMAGE_CAPTURE_DEBOUNCE_S
-- so we wait past the GROUP_TIME_THRESHOLD_S merge window before capturing a
-- fresh stroke. Backfill uses a shorter delay since no merges are pending.
function Pencil:scheduleGroupImageCapture(group, delay)
    if not group or not group.id then return end
    self.pending_image_captures = self.pending_image_captures or {}

    self:cancelGroupImageCapture(group.id)

    local cb = function()
        self.pending_image_captures[group.id] = nil
        -- Never under the pen: try again in a moment.
        if self.current_stroke then
            return self:scheduleGroupImageCapture(group, 2)
        end
        -- The group might have been deleted by the eraser by now.
        local current = nil
        for _, g in ipairs(self.annotation_groups) do
            if g.id == group.id then current = g; break end
        end
        if not current then return end
        local ok, err = pcall(self.captureGroupImage, self, current)
        if not ok then
            logger.warn("Pencil: captureGroupImage error:", err)
        end
        if self.image_data_dirty then
            self.image_data_dirty = false
            self:saveStrokes()
        end
    end

    self.pending_image_captures[group.id] = cb
    local d = delay or IMAGE_CAPTURE_DEBOUNCE_S
    UIManager:scheduleIn(d, cb)
    logger.dbg("Pencil: scheduled image capture for group", group.id, "in", d, "seconds")
end

function Pencil:cancelGroupImageCapture(group_id)
    if not self.pending_image_captures then return end
    local cb = self.pending_image_captures[group_id]
    if cb then
        UIManager:unschedule(cb)
        self.pending_image_captures[group_id] = nil
    end
end

-- Run all pending captures synchronously and clear the queue. Called on
-- document close / suspend so we don't lose freshly drawn annotations.
function Pencil:flushPendingCaptures()
    if not self.pending_image_captures then return end
    local pending = self.pending_image_captures
    self.pending_image_captures = {}
    for _, cb in pairs(pending) do
        UIManager:unschedule(cb)
        local ok, err = pcall(cb)
        if not ok then
            logger.warn("Pencil: flushPendingCaptures error:", err)
        end
    end
end

function Pencil:removeGroupImage(group)
    local path = self:getGroupImagePath(group)
    if not path then return end
    os.remove(path)
    group.image_path = nil
    group.image_rotation = nil
end

-- Delete any JPEG in pencil_images/ whose stem isn't a current group.id.
-- Called after group rebuilds (which regenerate ids) and during saveStrokes.
function Pencil:purgeOrphanImages()
    local dir = self:getImagesDir()
    if not dir then return end
    local attr = lfs.attributes(dir)
    if not attr or attr.mode ~= "directory" then return end

    local valid = {}
    for _, g in ipairs(self.annotation_groups or {}) do
        if g.image_path then
            valid[g.image_path] = true
        end
    end

    for file in lfs.dir(dir) do
        if file ~= "." and file ~= ".." and file:match("%.jpg$") and not valid[file] then
            os.remove(dir .. "/" .. file)
            logger.dbg("Pencil: purged orphan image", file)
        end
    end
end

-- Open the saved image for a group in an ImageViewer popup.
function Pencil:showGroupImagePreview(group)
    if not group then return end
    local path = self:getGroupImagePath(group)
    if not path then
        UIManager:show(InfoMessage:new{
            text = _("No saved image for this annotation yet."),
            timeout = 2,
        })
        return
    end
    local attr = lfs.attributes(path)
    if not attr then
        UIManager:show(InfoMessage:new{
            text = _("Annotation image is missing on disk."),
            timeout = 2,
        })
        return
    end
    local ImageViewer = require("ui/widget/imageviewer")
    local pageno = self:getPageNumber(group.page) or 0
    UIManager:show(ImageViewer:new{
        file = path,
        with_title_bar = true,
        title_text = T(_("Annotation - page %1"), pageno),
        fullscreen = false,
    })
end

-- Compute the on-screen badge rect for a stale-rotation group. The badge is
-- pinned to the right edge of the screen (i.e. in the margin) at a vertical
-- position proportional to the original bbox center Y, so multiple stale
-- annotations stack along the right side in roughly their original reading
-- order.
function Pencil:getGroupBadgeRect(group)
    if not group or not group.bbox or not group.image_rotation then return nil end
    local current_rot = Screen:getRotationMode()
    if current_rot == group.image_rotation then return nil end

    local sw = Screen:getWidth()
    local sh = Screen:getHeight()

    -- Source-rotation screen height: rotations 0/2 vs 1/3 swap width/height.
    local src_sh = sh
    if (group.image_rotation == 1 or group.image_rotation == 3) ~=
            (current_rot == 1 or current_rot == 3) then
        src_sh = sw
    end

    -- Vertical: proportional remap of the bbox center onto current screen.
    local cy = (group.bbox.y0 + group.bbox.y1) / 2
    local y_fraction = src_sh > 0 and (cy / src_sh) or 0.5
    local target_y = math.floor(y_fraction * sh)

    -- Horizontal: fixed position in the right margin. Simple and reliable;
    -- avoids depending on the document's reported page margins which can
    -- behave unexpectedly across EPUB engines.
    local badge_x = sw - IMAGE_BADGE_SIZE - IMAGE_BADGE_MARGIN_GAP

    local half = math.floor(IMAGE_BADGE_SIZE / 2)
    local x = math.max(0, math.min(sw - IMAGE_BADGE_SIZE, badge_x))
    local y = math.max(0, math.min(sh - IMAGE_BADGE_SIZE, target_y - half))
    return { x = x, y = y, w = IMAGE_BADGE_SIZE, h = IMAGE_BADGE_SIZE }
end

-- Pick a representative color for an annotation group: the first stroke's
-- saved color. Returns nil if no usable color is found, so the caller can
-- fall back to a default.
function Pencil:getGroupColor(group)
    if not group or not group.stroke_indices then return nil end
    for _, idx in ipairs(group.stroke_indices) do
        local stroke = self.strokes[idx]
        if stroke and stroke.color then
            return stroke.color
        end
    end
    return nil
end

function Pencil:renderRotationBadge(bb, group)
    local rect = self:getGroupBadgeRect(group)
    if not rect then return end
    -- Fill matches the annotation color so users can tell badges apart when
    -- a page has annotations in different colors. Black border for
    -- definition, white inner mark to suggest interactivity (and to keep
    -- light colors like gray / highlighter yellow visible).
    -- Must use paintRectRGB32 (not paintRect) to preserve the color channels
    -- of ColorRGB32 fills; paintRect treats the value as a luminance and
    -- would render colored fills as gray.
    local fill = self:getGroupColor(group)
            or Blitbuffer.ColorRGB32(0xCC, 0x00, 0x00, 0xFF)
    bb:paintRectRGB32(rect.x, rect.y, rect.w, rect.h, Blitbuffer.COLOR_BLACK)
    bb:paintRectRGB32(rect.x + 2, rect.y + 2, rect.w - 4, rect.h - 4, fill)
    local inset = math.floor(rect.w / 3)
    bb:paintRectRGB32(rect.x + inset, rect.y + inset,
        rect.w - 2 * inset, rect.h - 2 * inset, Blitbuffer.COLOR_WHITE)
end

-- Whether a group's ink is drawn by its words on any layout, rotation
-- included (shownStrokes): a reflowable book, every stroke anchored. Only
-- other ink (a PDF's, or older ink not anchored yet) still needs the
-- rotation badge.
function Pencil:followsText(group)
    if not self.ui.rolling then return false end
    local indices = group.stroke_indices or {}
    if #indices == 0 then return false end
    for _, idx in ipairs(indices) do
        local stroke = self.strokes[idx]
        if not (stroke and stroke.anchor) then return false end
    end
    return true
end

-- Compute the list of stale-rotation groups whose badges should be drawn on
-- the current page in the current rotation. Returns nil if no badges should
-- show (no stale groups, or suppressed because a native annotation is also
-- on this page). Shared by paintTo and findGroupBadgeAtPoint to keep
-- drawing and hit-testing in lockstep.
function Pencil:getStaleGroupsForCurrentView()
    local current_rot = Screen:getRotationMode()
    local page = self:getCurrentPage()
    local stale = nil
    local has_native = false
    for _, group in ipairs(self.annotation_groups or {}) do
        local gpage = self:getGroupCurrentPage(group)
        if gpage == page then
            if group.image_rotation == nil
                    or group.image_rotation == current_rot
                    or self:followsText(group) then
                has_native = true
            elseif group.image_path then
                stale = stale or {}
                stale[#stale + 1] = group
            end
        end
    end
    if has_native then return nil end
    return stale
end

-- Hit-test the rotation badges on the current page. Mirrors the drawing
-- logic in paintTo: a badge is tappable iff its group would have its badge
-- drawn by the current render pass.
function Pencil:findGroupBadgeAtPoint(x, y)
    local stale = self:getStaleGroupsForCurrentView()
    if not stale then return nil end
    for _, group in ipairs(stale) do
        local rect = self:getGroupBadgeRect(group)
        if rect
                and x >= rect.x - IMAGE_BADGE_HIT_PAD
                and x <= rect.x + rect.w + IMAGE_BADGE_HIT_PAD
                and y >= rect.y - IMAGE_BADGE_HIT_PAD
                and y <= rect.y + rect.h + IMAGE_BADGE_HIT_PAD then
            return group
        end
    end
    return nil
end

-- Called by the bookmark-list hook on menu select. Returns true if we
-- handled the tap (and the original navigation should be skipped).
function Pencil:tryShowImageForBookmark(item)
    if not item or not item.datetime then return false end
    if not item.datetime:match("^pencil_") then return false end
    -- Find the matching group by id (group.id is stored as the bookmark datetime).
    for _, group in ipairs(self.annotation_groups or {}) do
        if group.id == item.datetime then
            if group.image_path then
                self:showGroupImagePreview(group)
                return true
            end
            return false  -- pencil bookmark but no image yet; fall through to navigate
        end
    end
    return false
end

-- Total disk usage of pencil_images/ for the current document, in bytes.
function Pencil:getImagesSizeBytes()
    local dir = self:getImagesDir()
    if not dir then return 0 end
    local attr = lfs.attributes(dir)
    if not attr or attr.mode ~= "directory" then return 0 end
    local total = 0
    for file in lfs.dir(dir) do
        if file ~= "." and file ~= ".." then
            local fattr = lfs.attributes(dir .. "/" .. file)
            if fattr and fattr.size then total = total + fattr.size end
        end
    end
    return total
end

-- Remove all preview images for the current book and clear group references.
function Pencil:purgeAllImages()
    local dir = self:getImagesDir()
    if dir then
        local attr = lfs.attributes(dir)
        if attr and attr.mode == "directory" then
            for file in lfs.dir(dir) do
                if file ~= "." and file ~= ".." then
                    os.remove(dir .. "/" .. file)
                end
            end
        end
    end
    for _, group in ipairs(self.annotation_groups or {}) do
        group.image_path = nil
        group.image_rotation = nil
    end
    self:saveStrokes()
    UIManager:setDirty(self.view, "ui")
end

-- Re-capture missing images for groups on the currently visible page.
-- Called from onReaderReady and onPageUpdate so the user sees rotation
-- badges work without needing to redraw the annotation. Uses a short delay
-- so the page has fully rendered before we ask ReaderView to repaint into
-- our offscreen, but no merge-window wait since the group is already final.
function Pencil:backfillMissingImages()
    local page = self:getCurrentPage()
    for _, group in ipairs(self.annotation_groups or {}) do
        if self:getGroupCurrentPage(group) == page and not group.image_path then
            self:scheduleGroupImageCapture(group, 1.0)
        end
    end
end

-- Install a one-time class-level patch on ReaderBookmark so that
-- long-pressing a pencil bookmark that has a saved image opens a
-- full-screen ImageViewer popup directly, instead of the standard
-- bookmark detail dialog. Closing the ImageViewer returns to the
-- bookmark list with nothing else stacked behind it.
--
-- Falls through to the standard dialog for non-pencil bookmarks and for
-- pencil bookmarks without a saved image. Short-tap still navigates to
-- the bookmark (default behavior, untouched).
function Pencil:installBookmarkHook()
    if _bookmark_hook_installed then return end

    local ok, ReaderBookmark = pcall(require, "apps/reader/modules/readerbookmark")
    if not ok or not ReaderBookmark or not ReaderBookmark.showBookmarkDetails then
        logger.warn("Pencil: ReaderBookmark module not available, skipping hook")
        return
    end

    local original_showBookmarkDetails = ReaderBookmark.showBookmarkDetails
    function ReaderBookmark:showBookmarkDetails(item_or_index)
        local item = type(item_or_index) == "table"
            and item_or_index
            or (self.ui.annotation and self.ui.annotation.annotations
                    and self.ui.annotation.annotations[item_or_index])
        if item and item.datetime and item.datetime:match("^pencil_")
                and _active_pencil and _active_pencil.annotation_groups then
            for _, group in ipairs(_active_pencil.annotation_groups) do
                if group.id == item.datetime and group.image_path then
                    local path = _active_pencil:getGroupImagePath(group)
                    if path and lfs.attributes(path) then
                        _active_pencil:showGroupImagePreview(group)
                        return true  -- suppress standard dialog
                    end
                    break
                end
            end
        end
        return original_showBookmarkDetails(self, item_or_index)
    end

    _bookmark_hook_installed = true
    logger.info("Pencil: installed bookmark list hook")
end

-- Rebuild page index from strokes
function Pencil:rebuildPageIndex()
    self.page_strokes = {}
    for i, stroke in ipairs(self.strokes) do
        self:indexStroke(i, stroke.page)
    end
end

-- Get strokes for a specific page
function Pencil:getStrokesForPage(page)
    local result = {}
    local indices = self.page_strokes[page] or {}
    for _, idx in ipairs(indices) do
        if self.strokes[idx] then
            table.insert(result, self.strokes[idx])
        end
    end
    return result
end

-- Check if current page has strokes
function Pencil:hasStrokesOnCurrentPage()
    local page = self:getCurrentPage()
    return self.page_strokes[page] and #self.page_strokes[page] > 0
end

-- Clear strokes on current page
function Pencil:clearPageStrokes()
    local page = self:getCurrentPage()
    local indices_to_remove = self.page_strokes[page]

    if not indices_to_remove or #indices_to_remove == 0 then
        UIManager:show(InfoMessage:new{
            text = _("No annotations found on this page."),
            timeout = 1,
        })
        return
    end

    -- Copy and sort in reverse order to maintain indices during removal
    local sorted_indices = {}
    for _, idx in ipairs(indices_to_remove) do
        table.insert(sorted_indices, idx)
    end
    table.sort(sorted_indices, function(a, b) return a > b end)

    local deleted_strokes = {}
    for _, idx in ipairs(sorted_indices) do
        if self.strokes[idx] then
            table.insert(deleted_strokes, self.strokes[idx])
            table.remove(self.strokes, idx)
        end
    end

    if #deleted_strokes > 0 then
        table.insert(self.undo_stack, { type = "delete", strokes = deleted_strokes })
    end

    self:rebuildPageIndex()
    self:rebuildAnnotationGroups()
    self:saveStrokes()

    UIManager:show(InfoMessage:new{
        text = T(_("Cleared %1 annotation(s) from page."), #deleted_strokes),
        timeout = 1,
    })
    UIManager:setDirty(self.view, "ui")
end

-- Clear all strokes
function Pencil:clearAllStrokes()
    -- Remove all bookmarks for annotation groups + delete their images.
    for _, group in ipairs(self.annotation_groups) do
        self:removeGroupBookmark(group)
        self:cancelGroupImageCapture(group.id)
        self:removeGroupImage(group)
    end
    self.strokes = {}
    self.page_strokes = {}
    self.annotation_groups = {}
    self:saveStrokes()
    -- Belt-and-suspenders: any leftover files get reaped.
    self:purgeOrphanImages()

    UIManager:setDirty(self.view, "ui")
end

-- Render a line segment using rectangles (since BlitBuffer has no native line drawing)
-- Rasterize a thick line by stamping width×width squares along the segment.
-- Steps by ~half the pen width (via Geometry.segmentStepCount) so the squares
-- overlap without the ~width-fold per-pixel overdraw that stepping by 1px gives.
function Pencil:drawThickLine(bb, x1, y1, x2, y2, width, color)
    local dx = x2 - x1
    local dy = y2 - y1
    local dist = math.sqrt(dx * dx + dy * dy)
    local half_w = math.floor(width / 2)

    if dist < 1 then
        -- Just draw a single point
        bb:paintRectRGB32(x1 - half_w, y1 - half_w, width, width, color)
        return
    end

    -- Inclusive 0..steps loop emits both endpoints (t=0 and t=1).
    local steps = PencilGeometry.segmentStepCount(dist, width)
    for i = 0, steps do
        local t = i / steps
        local x = math.floor(x1 + dx * t)
        local y = math.floor(y1 + dy * t)
        bb:paintRectRGB32(x - half_w, y - half_w, width, width, color)
    end
end

function Pencil:drawLineSegment(bb, x1, y1, x2, y2, width, color)
    self:drawThickLine(bb, x1, y1, x2, y2, width, color)
end

-- Render a highlighter segment (semi-transparent, wider)
function Pencil:drawHighlighterSegment(bb, x1, y1, x2, y2, width, color)
    -- Highlighter is drawn as a lighter gray to simulate transparency on e-ink
    local highlight_color = color or Blitbuffer.Color8(0xDD)
    self:drawThickLine(bb, x1, y1, x2, y2, width, highlight_color)
end

-- Check if a point is near a stroke (for eraser)
function Pencil:isPointNearStroke(px, py, stroke, threshold)
    return PencilGeometry.isPointNearStroke(px, py, stroke, threshold)
end

-- Screen-space refresh rect (x, y, w, h) covering a set of just-deleted
-- strokes, expanded by the eraser width and clamped to the screen. Returns
-- nil when no stroke has geometry, signalling the caller to refresh fully.
function Pencil:erasedStrokesRefreshRect(strokes)
    -- Where the erased ink was shown, which may differ from where it was
    -- written (shownStrokes).
    if self._erased_shown then
        strokes = self._erased_shown
        self._erased_shown = nil
    end
    local bbox = nil
    for _, s in ipairs(strokes) do
        local b = PencilGeometry.computeStrokeBbox(s)
        if b then
            bbox = bbox and PencilGeometry.bboxUnion(bbox, b) or b
        end
    end
    if not bbox then return nil end
    local margin = (self.tool_settings[TOOL_ERASER] and self.tool_settings[TOOL_ERASER].width) or 20
    bbox = PencilGeometry.bboxExpand(bbox, margin)
    bbox = PencilGeometry.bboxClampToScreen(bbox, Screen:getWidth(), Screen:getHeight())
    local w = bbox.x1 - bbox.x0
    local h = bbox.y1 - bbox.y0
    if w <= 0 or h <= 0 then return nil end
    return bbox.x0, bbox.y0, w, h
end

-- Erase strokes at a given point
-- Returns array of deleted strokes (for undo), or nil if none
function Pencil:eraseAtPoint(x, y, page)
    -- Only erase strokes on the current page
    if self.input_debug_mode then
        self:writeDebugLog(string.format("ERASE: searching %d strokes at (%d, %d)",
            #self.strokes, x, y))
    end

    if #self.strokes == 0 then
        if self.input_debug_mode then
            self:writeDebugLog("ERASE: no strokes exist")
        end
        return nil
    end

    local eraser_width = self.tool_settings[TOOL_ERASER].width
    local deleted = {}
    local indices_to_remove = {}

    -- Iterate only strokes on the current page via the page index. Keeps the
    -- per-sample erase cost O(strokes-on-page) instead of O(total-strokes).
    -- Ink is erased where it's shown, moved or not (shownStrokes).
    local shown_list = self:shownStrokes(page)
    if #shown_list > 0 then
        for _, shown in ipairs(shown_list) do
            local i, stroke = shown[1], shown[2]
            if stroke then
                if self.input_debug_mode and stroke.points and #stroke.points > 0 then
                    local min_x, max_x, min_y, max_y = stroke.points[1].x, stroke.points[1].x, stroke.points[1].y, stroke.points[1].y
                    for _, pt in ipairs(stroke.points) do
                        if pt.x < min_x then min_x = pt.x end
                        if pt.x > max_x then max_x = pt.x end
                        if pt.y < min_y then min_y = pt.y end
                        if pt.y > max_y then max_y = pt.y end
                    end
                    self:writeDebugLog(string.format("ERASE: stroke %d bounds: (%d-%d, %d-%d), eraser at (%d,%d) threshold=%d",
                        i, min_x, max_x, min_y, max_y, x, y, eraser_width))
                end
                if self:isPointNearStroke(x, y, stroke, eraser_width) then
                    -- The stroke itself, as written (undo puts it back); the refresh
                    -- covers it where it was shown.
                    table.insert(deleted, self.strokes[i])
                    self._erased_shown = self._erased_shown or {}
                    table.insert(self._erased_shown, stroke)
                    table.insert(indices_to_remove, i)
                    if self.input_debug_mode then
                        self:writeDebugLog(string.format("ERASE: found stroke %d to delete", i))
                    end
                end
            end
        end
    end

    -- Remove strokes (in reverse order to maintain indices)
    if #indices_to_remove > 0 then
        table.sort(indices_to_remove, function(a, b) return a > b end)
        for _, idx in ipairs(indices_to_remove) do
            table.remove(self.strokes, idx)
        end
        self:rebuildPageIndex()
        self:rebuildAnnotationGroups()
        if self.input_debug_mode then
            self:writeDebugLog(string.format("ERASE: deleted %d strokes", #deleted))
        end
        return deleted
    end

    return nil
end

-- Render a complete stroke
function Pencil:renderStroke(bb, stroke)
    if not stroke.points or #stroke.points < 1 then
        return
    end

    local tool = stroke.tool or TOOL_PEN
    local width = stroke.width or self.tool_settings[tool].width or 3

    -- Get color directly (it's already a Blitbuffer color)
    local color = stroke.color or self.tool_settings[tool].color or Blitbuffer.COLOR_BLACK

    -- Reinvert color in night mode (if it's not black or gray)
    if Screen.night_mode and stroke.color_name ~= "Black" and stroke.color_name ~= "Gray" then
        color = color:invert()
    end

    -- Highlighter uses lighter color
    local is_highlighter = (tool == TOOL_HIGHLIGHTER)
    if is_highlighter then
        -- For highlighter, use stored color or default gray
        color = stroke.color or Blitbuffer.Color8(0xDD)
    end

    if #stroke.points == 1 then
        -- Single point (dot)
        local p = stroke.points[1]
        local half_w = math.floor(width / 2)
        bb:paintRectRGB32(p.x - half_w, p.y - half_w, width, width, color)
    else
        -- Multiple points - draw line segments
        for i = 2, #stroke.points do
            local p1 = stroke.points[i - 1]
            local p2 = stroke.points[i]
            if is_highlighter then
                self:drawHighlighterSegment(bb, p1.x, p1.y, p2.x, p2.y, width, color)
            else
                self:drawLineSegment(bb, p1.x, p1.y, p2.x, p2.y, width, color)
            end
        end
    end
end

-- View module paintTo method - called by ReaderView during repaints.
-- When the captureGroupImage routine asks ReaderView to repaint into our
-- offscreen buffer, this method is invoked recursively as part of the view
-- module loop; the _capturing guard suppresses re-entry so we can paint the
-- group's strokes deliberately onto the captured page background.
-- ---- Ink across layouts --------------------------------------------------

-- The current layout of a rolling document (KOReader's rendering hash: the
-- font, its size, spacing, margins, styles and screen), or nil.
function Pencil:layoutKey()
    if not self.ui.rolling or not self.ui.document then return nil end
    local ok, key = pcall(self.ui.document.getDocumentRenderingHash, self.ui.document, true)
    return ok and key or nil
end

-- The text's left and right edges on screen ({x0, x1}), from the page
-- margins.
function Pencil:textColumn()
    local ok, m = pcall(self.ui.document.getPageMargins, self.ui.document)
    if not ok or not m then return nil end
    return { x0 = m.left or 0, x1 = Screen:getWidth() - (m.right or 0) }
end

-- The box ({x, y, w, h}) on screen of the word an anchor names, or nil.
function Pencil:anchorWordBox(xpointer)
    local doc = self.ui.document
    local ok, boxes = pcall(function()
        return doc:getScreenBoxesFromPositions(xpointer, doc:getNextVisibleWordEnd(xpointer), true)
    end)
    return ok and boxes and boxes[1] or nil
end

-- A stroke drawn (dx, dy) away from where it was written.
local function movedStroke(stroke, dx, dy)
    local points = {}
    for i, p in ipairs(stroke.points) do
        points[i] = { x = p.x + dx, y = p.y + dy }
    end
    return setmetatable({ points = points }, { __index = stroke })
end

-- The strokes shown on `page`, as { idx, stroke } pairs: ink written in the
-- current layout as written; ink written in another, on the page its
-- anchor word is on now and moved with it (lib/anchor), each group of
-- strokes as one so handwriting keeps its shape, and kept on screen. Ink
-- with no anchor stays where it was written. Cached until the layout, the
-- page or the strokes change.
function Pencil:shownStrokes(page)
    local key = self:layoutKey()
    local cache = self._shown
    if cache and cache.key == key and cache.page == page then return cache.list end
    local list = {}
    local elsewhere = {} -- strokes from other layouts, to be moved
    for idx, stroke in ipairs(self.strokes) do
        if key == nil or stroke.layout == nil or stroke.layout == key or not stroke.anchor then
            if stroke.page == page then table.insert(list, { idx, stroke }) end
        else
            elsewhere[idx] = true
        end
    end
    if next(elsewhere) then
        local column = self:textColumn()
        local W, H = Screen:getWidth(), Screen:getHeight()
        -- Underlines and circles are drawn again under or around their
        -- words, wherever those are now (lib/refit).
        for idx in pairs(elsewhere) do
            local stroke = self.strokes[idx]
            if stroke.mark then
                elsewhere[idx] = nil
                for _, points in ipairs(self:fittedMark(stroke, page)) do
                    table.insert(list, { idx, setmetatable({ points = points }, { __index = stroke }) })
                end
            end
        end
        local function move(indices)
            -- The group's first anchored stroke places it.
            local ref
            for _, idx in ipairs(indices) do
                if elsewhere[idx] then ref = self.strokes[idx]; break end
            end
            if not ref then return end
            local ok, p = pcall(self.ui.document.getPageFromXPointer, self.ui.document, ref.anchor.xpointer)
            if not ok or p ~= page then return end
            local box = self:anchorWordBox(ref.anchor.xpointer)
            local bbox = PencilGeometry.computeStrokeBbox(ref)
            if not box or not bbox then return end
            local nx, ny = PencilAnchor.place(ref.anchor, box, column)
            local dx = nx - (bbox.x0 + bbox.x1) / 2
            local dy = ny - (bbox.y0 + bbox.y1) / 2
            -- Kept on screen, as a whole.
            local all
            for _, idx in ipairs(indices) do
                if elsewhere[idx] then
                    local b = PencilGeometry.computeStrokeBbox(self.strokes[idx])
                    if b then
                        all = all or { x0 = b.x0, y0 = b.y0, x1 = b.x1, y1 = b.y1 }
                        all.x0, all.y0 = math.min(all.x0, b.x0), math.min(all.y0, b.y0)
                        all.x1, all.y1 = math.max(all.x1, b.x1), math.max(all.y1, b.y1)
                    end
                end
            end
            if all then
                dx = math.max(-all.x0, math.min(dx, W - 1 - all.x1))
                dy = math.max(-all.y0, math.min(dy, H - 1 - all.y1))
            end
            for _, idx in ipairs(indices) do
                if elsewhere[idx] then
                    table.insert(list, { idx, movedStroke(self.strokes[idx], math.floor(dx + 0.5), math.floor(dy + 0.5)) })
                end
            end
        end
        local grouped = {}
        for _, group in ipairs(self.annotation_groups) do
            move(group.stroke_indices or {})
            for _, idx in ipairs(group.stroke_indices or {}) do grouped[idx] = true end
        end
        for idx in pairs(elsewhere) do
            if not grouped[idx] then move({ idx }) end
        end
    end
    self._shown = { key = key, page = page, list = list }
    return list
end

-- A mark stroke drawn again on `page` of the current layout: one point list
-- per line its words are on here (none when they're on another page).
function Pencil:fittedMark(stroke, page)
    local doc, mark = self.ui.document, stroke.mark
    local ok0, p0 = pcall(doc.getPageFromXPointer, doc, mark.pos0)
    local ok1, p1 = pcall(doc.getPageFromXPointer, doc, mark.pos1)
    if not ((ok0 and p0 == page) or (ok1 and p1 == page)) then return {} end
    local ok, boxes = pcall(doc.getScreenBoxesFromPositions, doc, mark.pos0, mark.pos1, true)
    if not ok or not boxes then return {} end
    -- The words' boxes on screen, one per line.
    local H = Screen:getHeight()
    local lines = {}
    for _, b in ipairs(boxes) do
        if b.y >= 0 and b.y + b.h <= H then
            local cy = b.y + b.h / 2
            local line
            for _, l in ipairs(lines) do
                if l[2] <= cy and cy <= l[4] then line = l; break end
            end
            if line then
                line[1], line[3] = math.min(line[1], b.x), math.max(line[3], b.x + b.w)
                line[2], line[4] = math.min(line[2], b.y), math.max(line[4], b.y + b.h)
            else
                table.insert(lines, { b.x, b.y, b.x + b.w, b.y + b.h })
            end
        end
    end
    local bbox = PencilGeometry.computeStrokeBbox(stroke)
    if not bbox or #lines == 0 then return {} end
    return PencilRefit.fit(mark, stroke.points, bbox, lines)
end

-- KOReader finished laying the book out again: ink positions may change.
function Pencil:onDocumentRerendered()
    self._shown = nil
end

function Pencil:paintTo(bb, x, y)
    if self._capturing then return end

    local page = self:getCurrentPage()
    local current_rot = Screen:getRotationMode()

    -- Backfill XPointers for legacy groups before we filter, so the
    -- rotation-aware page resolution below sees them.
    self:backfillGroupXPointers()

    -- Identify groups whose captured-image rotation no longer matches the
    -- current screen rotation. Their strokes will draw in the wrong place,
    -- so we skip them and draw a badge instead. For EPUB we match by the
    -- group's XPointer re-resolved to the current pagination, since the
    -- saved group.page would be stale across rotations.
    --
    -- Suppression: if any group on this page renders natively at the
    -- current rotation (i.e. matches current_rot, or pre-dates the feature
    -- entirely), we hide badges for OTHER stale groups on the same page so
    -- the view isn't cluttered with badges next to a visible annotation.
    -- Re-rotate to see the suppressed annotation.
    local stale_indices = nil
    local stale_groups = nil
    local groups_on_page = 0
    local groups_with_image = 0
    local has_native_annotation = false
    for _, group in ipairs(self.annotation_groups) do
        local gpage = self:getGroupCurrentPage(group)
        if gpage == page then
            groups_on_page = groups_on_page + 1
            if group.image_path then
                groups_with_image = groups_with_image + 1
            end
            if group.image_rotation == nil
                    or group.image_rotation == current_rot
                    or self:followsText(group) then
                -- Renders natively (same rotation as capture, legacy group
                -- without rotation info, or ink that follows its words to
                -- any layout: shownStrokes draws it).
                has_native_annotation = true
            elseif group.image_path then
                stale_groups = stale_groups or {}
                stale_groups[#stale_groups + 1] = group
                stale_indices = stale_indices or {}
                for _, idx in ipairs(group.stroke_indices or {}) do
                    stale_indices[idx] = true
                end
            end
        end
    end
    if has_native_annotation then
        -- Drop badges entirely; native-rotation strokes will render below.
        stale_groups = nil
        stale_indices = nil
    end
    local stale_count = stale_groups and #stale_groups or 0
    if not self._last_paint_log
            or self._last_paint_log.page ~= page
            or self._last_paint_log.rot ~= current_rot
            or self._last_paint_log.on_page ~= groups_on_page
            or self._last_paint_log.with_image ~= groups_with_image
            or self._last_paint_log.stale ~= stale_count
            or self._last_paint_log.native ~= has_native_annotation then
        logger.info("Pencil: paintTo page=", page, " rot=", current_rot,
            " groups_on_page=", groups_on_page,
            " with_image=", groups_with_image,
            " native=", tostring(has_native_annotation),
            " badges=", stale_count)
        self._last_paint_log = {
            page = page,
            rot = current_rot,
            on_page = groups_on_page,
            with_image = groups_with_image,
            stale = stale_count,
            native = has_native_annotation,
        }
    end

    -- Render the strokes shown on this page (skipping stale ones).
    for _, shown in ipairs(self:shownStrokes(page)) do
        if not (stale_indices and stale_indices[shown[1]]) then
            self:renderStroke(bb, shown[2])
        end
    end

    -- Draw rotation-mismatch badges over the spots where the strokes would
    -- have appeared. Tapping a badge opens the saved image.
    if stale_groups then
        for _, group in ipairs(stale_groups) do
            self:renderRotationBadge(bb, group)
        end
    end

    -- Render current stroke being drawn (only if on current page)
    if self.current_stroke and self.current_stroke.page == page then
        self:renderStroke(bb, self.current_stroke)
    end
end

-- Get the pencil strokes file path for this document
-- ---- Markup export (lib/export) ------------------------------------------

-- Puts a new stroke in the current page visit's markup, starting one if
-- this is the first stroke since arriving on the page.
function Pencil:assignMarkup(stroke)
    if not stroke or stroke.markup then return end
    if not self.visit or self.visit.page ~= stroke.page then
        self.visit = { id = PencilExport.markupId(stroke), page = stroke.page }
    end
    stroke.markup = self.visit.id
    if self.page_capture and self.page_capture.page == stroke.page then
        -- The page was taken before this markup began (the reader paused
        -- before writing). The stroke isn't in the page's list yet, so
        -- attachPageCapture wouldn't find it: give it the capture here.
        if not self.markup_captures[stroke.markup] then
            self.markup_captures[stroke.markup] = self.page_capture
            self.page_capture.used = true
            self:scheduleIdleExport()
        end
    else
        -- Not taken yet (the pen beat it): once the pen rests.
        self:schedulePageCapture(PAGE_CAPTURE_PEN_REST_S)
    end
end

function Pencil:cancelPageCapture()
    if self.pending_page_capture then
        UIManager:unschedule(self.pending_page_capture)
        self.pending_page_capture = nil
    end
end

-- Takes the current page's picture and words after `delay` seconds,
-- unless the pen moves first (then the next stroke reschedules it).
function Pencil:schedulePageCapture(delay)
    if not self.ui.document then return end
    self:cancelPageCapture()
    local cb
    cb = function()
        if self.pending_page_capture ~= cb then return end
        self.pending_page_capture = nil
        local ok, err = pcall(self.capturePage, self)
        if not ok then
            logger.warn("Pencil: page capture failed:", err)
        end
    end
    self.pending_page_capture = cb
    UIManager:scheduleIn(delay, cb)
end

-- Paints the page as shown, without this plugin's ink, in grey, and lists
-- its words. Kept in memory until the export is next written.
function Pencil:capturePage()
    local page = self:getCurrentPage()
    if self.page_capture and self.page_capture.page == page then return end
    if self.current_stroke then
        return self:schedulePageCapture(PAGE_CAPTURE_PEN_REST_S)
    end
    -- While KOReader finishes laying the book out in the background, it
    -- draws a progress icon and page numbers may still change: wait.
    if self.ui.rolling and self.ui.rolling.rendering_state then
        return self:schedulePageCapture(1)
    end
    local started = time.now()
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    local bb = Blitbuffer.new(sw, sh, Blitbuffer.TYPE_BB8)
    bb:fill(Blitbuffer.COLOR_WHITE)
    self._capturing = true
    local painted, err = pcall(self.view.paintTo, self.view, bb, 0, 0)
    self._capturing = false
    if not painted then
        bb:free()
        logger.warn("Pencil: painting the page failed:", err)
        return
    end
    local capture = {
        bb = bb,
        page = page,
        layout_key = self:layoutKey(),
        screen = { width = sw, height = sh, rotation = Screen:getRotationMode() },
    }
    if self.ui.rolling then
        local words, first, last = PencilWords.onScreen(self.ui.document, sw, sh)
        capture.words, capture.start, capture.finish = words, first, last
        local conf = self.ui.document.configurable or {}
        capture.layout = {
            font_face = self.ui.font and self.ui.font.font_face,
            font_size = conf.font_size,
            line_spacing = conf.line_spacing,
            h_page_margins = conf.h_page_margins,
            t_page_margin = conf.t_page_margin,
            b_page_margin = conf.b_page_margin,
        }
    end
    if self.ui.toc and self.ui.toc.getTocTitleByPage then
        local ok, title = pcall(self.ui.toc.getTocTitleByPage, self.ui.toc, page)
        if ok and title and title ~= "" then capture.chapter = title end
    end
    self:releasePageCapture()
    self.page_capture = capture
    logger.info(string.format("Pencil: captured page %s (%d words) in %d ms",
        tostring(page), capture.words and #capture.words or 0, time.to_ms(time.now() - started)))
    self:attachPageCapture()
end

-- Gives the current page's capture to every markup on the page without one,
-- and anchors the page's strokes that have none.
function Pencil:attachPageCapture()
    local capture = self.page_capture
    if not capture then return end
    local attached = false
    for _, stroke in ipairs(self:getStrokesForPage(capture.page)) do
        -- Ink written in another layout was on another page as shown then.
        local here = stroke.layout == nil or stroke.layout == capture.layout_key
        if here and stroke.markup and not self.markup_captures[stroke.markup] then
            self.markup_captures[stroke.markup] = capture
            capture.used = true
            attached = true
        end
        if here and stroke.markup and self.markup_captures[stroke.markup] == capture and not stroke.anchor then
            self:anchorStroke(stroke)
        end
        -- Ink from before marks were recorded: what it marks, now that its
        -- page is on screen as written.
        if here and stroke.mark == nil and capture.words and self.ui.rolling then
            local bbox = PencilGeometry.computeStrokeBbox(stroke)
            stroke.mark = bbox and PencilRefit.markOf(bbox, capture.words) or false
        end
    end
    if attached then
        self:scheduleIdleExport()
    end
end

-- Lets go of the current page's capture when leaving it: its picture is
-- freed unless a markup still needs it encoded.
function Pencil:releasePageCapture()
    local capture = self.page_capture
    self.page_capture = nil
    if capture and capture.bb and not capture.used then
        capture.bb:free()
        capture.bb = nil
    end
end

function Pencil:cancelIdleExport()
    if self.pending_idle_export then
        UIManager:unschedule(self.pending_idle_export)
        self.pending_idle_export = nil
    end
end

-- Writes the export once the reader has been idle for EXPORT_IDLE_S:
-- rescheduled by every stroke and page turn.
function Pencil:scheduleIdleExport(delay)
    self:cancelIdleExport()
    local cb
    cb = function()
        if self.pending_idle_export ~= cb then return end
        self.pending_idle_export = nil
        if self.current_stroke then
            return self:scheduleIdleExport(2)
        end
        local ok, err = pcall(self.syncMarkups, self)
        if not ok then
            logger.warn("Pencil: markup export failed:", err)
        end
    end
    self.pending_idle_export = cb
    UIManager:scheduleIn(delay or EXPORT_IDLE_S, cb)
end

function Pencil:getMarkupsDir()
    local sidecar_dir = self.ui.doc_settings and self.ui.doc_settings.doc_sidecar_dir
    return sidecar_dir and (sidecar_dir .. "/" .. PencilExport.DIR)
end

local function mkdirs(path)
    local sofar = ""
    for part in path:gmatch("[^/]+") do
        sofar = sofar .. "/" .. part
        if lfs.attributes(sofar, "mode") ~= "directory" then
            lfs.mkdir(sofar)
        end
    end
    return lfs.attributes(path, "mode") == "directory"
end

-- Writes `data` to `path` through a temporary file, so a reader never sees
-- half of it.
local function writeAtomic(path, data)
    local tmp = path .. ".part"
    local f, err = io.open(tmp, "wb")
    if not f then return false, err end
    f:write(data)
    f:close()
    return os.rename(tmp, path)
end

local function readJSON(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local text = f:read("*a")
    f:close()
    local ok, data = pcall(JSON.decode, text)
    return ok and data or nil
end

local function copyFile(from, to)
    local src = io.open(from, "rb")
    if not src then return false end
    local data = src:read("*a")
    src:close()
    local dst = io.open(to, "wb")
    if not dst then return false end
    dst:write(data)
    dst:close()
    return true
end

local function removeDir(path)
    for entry in lfs.dir(path) do
        if entry ~= "." and entry ~= ".." then
            os.remove(path .. "/" .. entry)
        end
    end
    lfs.rmdir(path)
end

-- Brings the export in line with the strokes: writes each markup whose ink
-- changed (or whose picture is waiting), and removes those with no ink
-- left. markup.json is always written last.
-- With `all`, every waiting picture is encoded (closing the book, sleep);
-- otherwise one per run, so an idle pause never freezes for long, and the
-- rest follow at later pauses.
function Pencil:syncMarkups(all)
    local dir = self:getMarkupsDir()
    local encoded, more = 0, false
    if not dir or not self.strokes_loaded then return end
    local ids = PencilExport.ids(self.strokes)
    local live = {}
    for _, id in ipairs(ids) do live[id] = true end
    if #ids > 0 and not mkdirs(dir) then
        logger.warn("Pencil: can't create", dir)
        return
    end
    local document = {
        doc_path = self.ui.document and self.ui.document.file,
        partial_md5 = self.ui.doc_settings and self.ui.doc_settings:readSetting("partial_md5_checksum"),
    }
    for _, id in ipairs(ids) do
        local strokes = PencilExport.strokesOf(self.strokes, id)
        local signature = PencilExport.signature(strokes)
        local capture = self.markup_captures[id]
        local picture_waiting = capture and not self.markup_has_image[id]
            and (capture.bb or capture.png_path)
        if picture_waiting and not capture.png_path and encoded > 0 and not all then
            -- Another picture was encoded this run: this one waits.
            more = true
            picture_waiting = false
        end
        if self.markup_written[id] ~= signature or picture_waiting then
            local folder = dir .. "/" .. id
            mkdirs(folder)
            if picture_waiting then
                local png = folder .. "/page.png"
                local ok
                if capture.png_path then
                    -- Another markup on the same page has it encoded: copy.
                    ok = copyFile(capture.png_path, png .. ".part")
                else
                    local encode_started = time.now()
                    encoded = encoded + 1
                    ok = pcall(capture.bb.writePNG, capture.bb, png .. ".part")
                    logger.info(string.format("Pencil: encoded page.png for %s in %d ms",
                        id, time.to_ms(time.now() - encode_started)))
                end
                if ok and os.rename(png .. ".part", png) then
                    capture.has_image = true
                    capture.png_path = capture.png_path or png
                    self.markup_has_image[id] = true
                end
                if capture.bb and capture ~= self.page_capture then
                    capture.bb:free()
                    capture.bb = nil
                elseif capture.bb and capture.png_path then
                    -- Still the page on screen, but encoded once is enough.
                    capture.bb:free()
                    capture.bb = nil
                end
                if capture.words then
                    writeAtomic(folder .. "/words.json", JSON.encode({
                        format = PencilExport.FORMAT, words = capture.words }))
                end
            end
            writeAtomic(folder .. "/ink.json", JSON.encode(PencilExport.ink(strokes)))
            -- Without a capture this session, keep what an earlier one found.
            local previous = not capture and readJSON(folder .. "/markup.json") or nil
            local taken = capture or (previous and {
                page = previous.page, start = previous.start, finish = previous["end"],
                chapter = previous.chapter, screen = previous.screen, layout = previous.layout,
                has_image = previous.has_page_image,
            })
            writeAtomic(folder .. "/markup.json",
                JSON.encode(PencilExport.markup(id, strokes, taken, document, PLUGIN_VERSION)))
            self.markup_written[id] = signature
        end
    end
    if lfs.attributes(dir, "mode") == "directory" then
        for entry in lfs.dir(dir) do
            local path = dir .. "/" .. entry
            if entry:match("^m_") and not live[entry]
                    and lfs.attributes(path, "mode") == "directory" then
                removeDir(path)
                self.markup_written[entry] = nil
                self.markup_captures[entry] = nil
                self.markup_has_image[entry] = nil
            end
        end
    end
    if more then
        self:scheduleIdleExport(2)
    end
end

function Pencil:getStrokesFilePath()
    if not self.ui or not self.ui.doc_settings then
        logger.warn("Pencil: doc_settings not available")
        return nil
    end
    local sidecar_dir = self.ui.doc_settings.doc_sidecar_dir
    if sidecar_dir then
        return sidecar_dir .. "/pencil_strokes.lua"
    end
    logger.warn("Pencil: sidecar_dir not available")
    return nil
end

-- Where this book's ink was last kept, in the book's own settings: when
-- KOReader renames or copies a book, it writes those settings to a new
-- folder but leaves the plugin's files in the old one (from upstream PR #86,
-- by bateast, for issue #84). Everything the plugin keeps beside a book:
local DATA_LOCATION_SETTING = "pencil_data_location"
local DATA_ENTRIES = { "pencil_strokes.lua", "pencil_images", "pencil" }

-- Copies a file or a folder and everything in it.
local function copyTree(from, to)
    if lfs.attributes(from, "mode") ~= "directory" then
        return copyFile(from, to)
    end
    if not mkdirs(to) then return false end
    local ok = true
    for entry in lfs.dir(from) do
        if entry ~= "." and entry ~= ".." then
            ok = copyTree(from .. "/" .. entry, to .. "/" .. entry) and ok
        end
    end
    return ok
end

-- Notes where this book's ink lives, and for which file.
function Pencil:rememberDataLocation()
    local settings = self.ui and self.ui.doc_settings
    local dir = settings and settings.doc_sidecar_dir
    local doc = self.ui and self.ui.document and self.ui.document.file
    if dir and doc then
        settings:saveSetting(DATA_LOCATION_SETTING, { dir = dir, doc = doc })
    end
end

-- Brings the ink to this book's folder when it was left in another: the
-- book was renamed or moved (the old file is gone: the ink moves, and the
-- old folder goes if nothing else is in it), or copied (the original is
-- still there: the ink is copied, and the original keeps its own).
function Pencil:recoverDataAfterRename()
    local settings = self.ui and self.ui.doc_settings
    local dir = settings and settings.doc_sidecar_dir
    if not dir then return end
    local was = settings:readSetting(DATA_LOCATION_SETTING)
    if type(was) ~= "table" or type(was.dir) ~= "string" or was.dir == dir then return end
    if lfs.attributes(dir .. "/pencil_strokes.lua", "mode") == "file"
            or lfs.attributes(was.dir .. "/pencil_strokes.lua", "mode") ~= "file" then
        return
    end
    local copy = type(was.doc) == "string" and lfs.attributes(was.doc, "mode") == "file"
    if not mkdirs(dir) then
        logger.warn("Pencil: can't create", dir, "to bring the ink from", was.dir)
        return
    end
    for _, name in ipairs(DATA_ENTRIES) do
        local from, to = was.dir .. "/" .. name, dir .. "/" .. name
        if lfs.attributes(from) and not lfs.attributes(to) then
            -- A move that fails (another filesystem) copies instead, and
            -- leaves the old files where they were.
            if copy or not os.rename(from, to) then
                if not copyTree(from, to) then
                    logger.warn("Pencil: couldn't copy", from, "to", to)
                end
            end
        end
    end
    if not copy then lfs.rmdir(was.dir) end
    logger.info("Pencil:", copy and "copied" or "moved", "the ink from", was.dir, "to", dir)
end

-- Load strokes from our own file
function Pencil:loadStrokes()
    self:recoverDataAfterRename()
    local filepath = self:getStrokesFilePath()
    logger.info("Pencil: loadStrokes - filepath =", filepath)

    if not filepath then
        logger.warn("Pencil: no filepath available for loading strokes")
        self.strokes = {}
        self.page_strokes = {}
        return
    end

    -- Check if file exists
    local file_exists = io.open(filepath, "r")
    if not file_exists then
        logger.info("Pencil: strokes file does not exist yet:", filepath)
        self.strokes = {}
        self.page_strokes = {}
        self.strokes_loaded = true
        return
    end
    file_exists:close()

    local ok, data = pcall(dofile, filepath)
    if ok and data and data.strokes then
        -- Older files get stable group ids (lib/store); saved as version 4
        -- with the next save.
        PencilStore.upgrade(data)
        -- Convert saved strokes back to usable format
        self.strokes = {}
        for i, saved in ipairs(data.strokes) do
            self.strokes[i] = self:strokeFromSaved(saved)
        end
        self:rebuildPageIndex()

        -- Load annotation groups or bootstrap from v1 data
        if data.annotation_groups and #data.annotation_groups > 0 then
            self.annotation_groups = data.annotation_groups
            logger.info("Pencil: loaded", #self.annotation_groups, "annotation groups")
        else
            -- v1 data or no groups — bootstrap by running grouping on all strokes
            -- skip_bookmark=true because annotation module isn't ready yet during load
            logger.info("Pencil: bootstrapping annotation groups from strokes")
            self.annotation_groups = {}
            local sorted = {}
            for i, stroke in ipairs(self.strokes) do
                table.insert(sorted, { idx = i, dt = stroke.datetime or 0 })
            end
            table.sort(sorted, function(a, b) return a.dt < b.dt end)
            for _, entry in ipairs(sorted) do
                self:assignStrokeToGroup(entry.idx, true)
            end
        end

        self.strokes_loaded = true
        self:rememberDataLocation()
        logger.info("Pencil: loaded", #self.strokes, "strokes from", filepath)
    else
        logger.warn("Pencil: failed to load strokes from", filepath, "error:", data)
        self.strokes = {}
        self.page_strokes = {}
        self.annotation_groups = {}
    end
end

-- Convert stroke for saving (remove non-serializable values)
function Pencil:strokeToSaveable(stroke)
    local saveable = {
        page = stroke.page,
        tool = stroke.tool,
        width = stroke.width,
        alpha = stroke.alpha,
        datetime = stroke.datetime,
        -- v4: points packed as a single "x y x y ..." string instead of an
        -- array of {x=,y=} tables, so the serializer doesn't walk every point.
        p = PencilGeometry.packPoints(stroke.points),
        color_name = stroke.color_name,  -- Save color name for persistence
        anchor = stroke.anchor,
        markup = stroke.markup,
        layout = stroke.layout,
        mark = stroke.mark or nil,
    }
    -- Fields this version doesn't know (from a newer one) are kept.
    for k, v in pairs(stroke.extra or {}) do
        if saveable[k] == nil then saveable[k] = v end
    end
    return saveable
end

-- Stroke fields this version reads; anything else is kept as it was.
local KNOWN_STROKE_FIELDS = {
    page = true, tool = true, width = true, alpha = true, datetime = true,
    points = true, p = true, color_name = true, anchor = true, markup = true,
    layout = true, mark = true,
}

-- Convert saved stroke back to usable format
function Pencil:strokeFromSaved(saved)
    local extra
    for k, v in pairs(saved) do
        if not KNOWN_STROKE_FIELDS[k] then
            extra = extra or {}
            extra[k] = v
        end
    end
    local tool = saved.tool or TOOL_PEN
    local tool_settings = self.tool_settings[tool] or self.tool_settings[TOOL_PEN]

    -- Look up color from color_name
    local color = tool_settings.color
    if saved.color_name then
        for _, color_info in ipairs(self.available_colors) do
            if color_info.name == saved.color_name then
                color = color_info.color
                break
            end
        end
    end

    -- Points: v4 stores a packed "x y ..." string in `p`; v3 and earlier store
    -- an array of {x=,y=} tables in `points`. Reconstruct the in-memory
    -- {x=,y=} array either way.
    local points
    if saved.p ~= nil then
        points = PencilGeometry.unpackPoints(saved.p)
    else
        points = saved.points or {}
    end

    return {
        page = saved.page,
        tool = saved.tool,
        width = saved.width or tool_settings.width,
        color = color,
        color_name = saved.color_name,
        alpha = saved.alpha or tool_settings.alpha,
        datetime = saved.datetime,
        points = points,
        anchor = saved.anchor,
        markup = saved.markup,
        layout = saved.layout,
        mark = saved.mark,
        extra = extra,
    }
end

-- Save strokes to our own file
function Pencil:saveStrokes()
    local filepath = self:getStrokesFilePath()
    logger.info("Pencil: saveStrokes - filepath =", filepath, "strokes count =", #self.strokes)

    if not filepath then
        logger.warn("Pencil: no filepath available for saving strokes")
        return
    end

    -- Safety: don't save empty data if strokes were never successfully loaded
    -- (prevents data loss if a crash causes save before load completes)
    if #self.strokes == 0 and not self.strokes_loaded then
        logger.warn("Pencil: refusing to save empty strokes (strokes never loaded)")
        return
    end

    -- Ensure the directory exists
    local sidecar_dir = self.ui.doc_settings.doc_sidecar_dir
    if sidecar_dir then
        local ok, err = lfs.mkdir(sidecar_dir)
        if not ok and err ~= "File exists" then
            logger.warn("Pencil: failed to create sidecar dir:", err)
        end
    end

    -- Convert strokes to saveable format (remove non-serializable values)
    local saveable_strokes = {}
    for i, stroke in ipairs(self.strokes) do
        saveable_strokes[i] = self:strokeToSaveable(stroke)
    end

    -- Serialize and write. Version 5 (lib/store): each stroke's points packed
    -- into one "x y x y ..." string (field `p`, from upstream PR #77, cutting
    -- serialize time and file size on heavily-annotated books), stable group
    -- ids and anchored strokes. Version 3 and earlier (a `points` array) still
    -- load via strokeFromSaved's fallback.
    local data = {
        version = PencilStore.VERSION,
        strokes = saveable_strokes,
        annotation_groups = self.annotation_groups,
    }

    local f, err = io.open(filepath, "w")
    if f then
        f:write("return " .. require("dump")(data))
        f:close()
        self:rememberDataLocation()
        logger.info("Pencil: saved", #self.strokes, "strokes to", filepath)
    else
        logger.err("Pencil: failed to open file for writing:", filepath, "error:", err)
    end
    -- The markup export follows, once the reader is idle.
    self:scheduleIdleExport()
end

-- Handle document close
function Pencil:onCloseDocument()
    logger.info("Pencil: onCloseDocument called, strokes count =", #self.strokes)

    -- Cancel any pending refresh
    self:cancelPendingRefresh()
    -- Drop any scheduled debounced save - we save unconditionally below.
    self:cancelPendingSave()
    self.dirty_groups = nil

    -- Save any in-progress stroke
    if self.current_stroke and #self.current_stroke.points >= 2 then
        logger.info("Pencil: saving in-progress stroke before close")
        table.insert(self.strokes, self.current_stroke)
        self:indexStroke(#self.strokes, self.current_stroke.page)
        self.current_stroke = nil
    end

    self:teardownPenInput()

    -- Run any pending deferred image captures synchronously before close so
    -- we don't lose a fresh annotation. Must happen before the final save so
    -- new image_path / image_rotation fields land in the strokes file.
    self:flushPendingCaptures()

    -- Final bookmark sync before close
    self:syncAllBookmarks()

    -- Always save strokes on close (even if empty, to clear any previous data)
    logger.info("Pencil: saving strokes on document close")
    self:saveStrokes()
    -- And the export, now rather than at idle.
    self:cancelPageCapture()
    self:cancelIdleExport()
    local ok, err = pcall(self.syncMarkups, self, true)
    if not ok then logger.warn("Pencil: markup export failed:", err) end
    self:releasePageCapture()
    for _, capture in pairs(self.markup_captures) do
        if capture.bb then capture.bb:free(); capture.bb = nil end
    end

    -- Clear state
    self.eraser_deleted = nil
    self.undo_stack = {}

    if _active_pencil == self then _active_pencil = nil end
end

function Pencil:onSuspend()
    -- Same idea as onCloseDocument: don't lose a freshly drawn annotation
    -- across a device sleep.
    self:flushPendingCaptures()
    self:flushDeferredWork()
    self:cancelIdleExport()
    local ok, err = pcall(self.syncMarkups, self, true)
    if not ok then logger.warn("Pencil: markup export failed:", err) end
end

-- Handle reader ready (document fully loaded)
function Pencil:onReaderReady()
    logger.info("Pencil: onReaderReady called")
    logger.info("Pencil: doc_settings available:", self.ui.doc_settings ~= nil)
    if self.ui.doc_settings then
        logger.info("Pencil: sidecar_dir:", self.ui.doc_settings.doc_sidecar_dir)
    end

    -- Force reload strokes (in case they weren't loaded in init)
    if #self.strokes == 0 then
        self:loadStrokes()
    end
    logger.info("Pencil: after loadStrokes, strokes count =", #self.strokes,
        "groups =", #self.annotation_groups)

    -- Ink from before layouts were recorded is taken to be in the layout the
    -- book opens in (true unless the font was changed after writing).
    local key = self:layoutKey()
    if key then
        for _, stroke in ipairs(self.strokes) do
            if stroke.layout == nil then stroke.layout = key end
        end
    end

    -- Sync annotation group bookmarks now that UI modules are ready
    self:syncAllBookmarks()

    -- Re-setup touch zones if enabled
    if self:isEnabled() and not self.touch_zones_registered then
        self:setupPenInput()
    end

    if self:isEnabled() then
        self:schedulePageCapture(PAGE_CAPTURE_DELAY_S)
    end

    -- Lazy backfill: any group on the currently visible page that's missing
    -- an image (e.g. created in an older version, or capture was lost mid-
    -- session) gets re-captured now that ReaderView can paint the page.
    self:backfillMissingImages()
end

-- Handle read settings (document opened) - backup in case onReaderReady not called
function Pencil:onReadSettings(config)
    logger.dbg("Pencil: onReadSettings called")
    -- Only load if not already loaded
    if not self.strokes or #self.strokes == 0 then
        self:loadStrokes()
    end
    -- Re-setup touch zones if enabled (in case they were torn down)
    if self:isEnabled() and not self.touch_zones_registered then
        self:setupPenInput()
    end
end

-- Handle page changes (paging mode)
function Pencil:onPageUpdate(pageno)
    -- Clear any in-progress stroke when page changes
    if self.current_stroke and #self.current_stroke.points >= 2 then
        -- Save the stroke before clearing. The inline saveStrokes below covers
        -- everything in self.strokes, so drop any queued debounced save first.
        self:cancelPendingSave()
        table.insert(self.strokes, self.current_stroke)
        self:indexStroke(#self.strokes, self.current_stroke.page)
        table.insert(self.undo_stack, { type = "add", stroke_idx = #self.strokes })
        self:flushDirtyGroups()
        self:saveStrokes()
    else
        -- No in-progress stroke, but a debounced save may still be queued from
        -- earlier strokes on this page. Persist it before navigating away.
        self:flushDeferredWork()
    end
    self.current_stroke = nil
    self.eraser_deleted = nil
    -- Leaving a page ends its visit: writing here again starts a new markup.
    self.visit = nil
    self:releasePageCapture()
    self:cancelIdleExport()
    if self:isEnabled() then
        self:schedulePageCapture(PAGE_CAPTURE_DELAY_S)
    end
    if next(self.markup_captures) then
        self:scheduleIdleExport()
    end
    -- Re-schedule capture for any group on the newly visible page that's
    -- still missing an image (e.g. user turned past the original page before
    -- the debounce fired).
    self:backfillMissingImages()
end

-- Handle position changes (rolling/scroll mode)
function Pencil:onUpdatePos()
    -- Clear any in-progress stroke when position changes
    if self.current_stroke and #self.current_stroke.points >= 2 then
        self:cancelPendingSave()
        table.insert(self.strokes, self.current_stroke)
        self:indexStroke(#self.strokes, self.current_stroke.page)
        table.insert(self.undo_stack, { type = "add", stroke_idx = #self.strokes })
        self:flushDirtyGroups()
        self:saveStrokes()
    else
        self:flushDeferredWork()
    end
    self.current_stroke = nil
    self.eraser_deleted = nil
    self:backfillMissingImages()
end

-- Device trials only (lib/profile): off in releases.
local PROFILE = false
if PROFILE then
    require("lib/profile").install(Pencil, "Pencil")
end

return Pencil
