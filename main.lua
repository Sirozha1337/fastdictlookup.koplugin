local InputContainer = require("ui/widget/container/inputcontainer")
local Device = require("device")
local Screen = Device.screen
local UIManager = require("ui/uimanager")
local logger = require("logger")
local _ = require("gettext")

local CursorNavigator = require("cursor")
local HighlightController = require("highlighting")
local FastLookupController = require("fastlookup")

local Typewriter = InputContainer:extend{
    name = "typewriter",
    is_doc_only = true,
    enabled = false,
}

function Typewriter:init()
    logger.dbg("Typewriter: init")

    -- Compose sub-modules
    self.cursor = CursorNavigator:new(self.ui)
    self.highlight = HighlightController:new(self.ui)
    self.lookup = FastLookupController:new(self.ui)

    self.ui.menu:registerToMainMenu(self)

    -- Hook the top menu creation to dismiss our custom widgets
    local orig_onShowMenu = self.ui.menu.onShowMenu
    self.ui.menu.onShowMenu = function(menu_self, tab_index, do_not_show)
        self:deactivateCursor()
        self.lookup:dismissWidget()
        return orig_onShowMenu(menu_self, tab_index, do_not_show)
    end

    self.enabled = G_reader_settings:isTrue("typewriter_mode_enabled")

    -- Fast lookup settings
    self.lookup.fast_lookup_enabled = G_reader_settings:isTrue("typewriter_fast_lookup_enabled")
    local doc_dict = self.ui.doc_settings and self.ui.doc_settings:readSetting("typewriter_fast_lookup_dict")
    self.lookup.fast_lookup_dict_ifo = doc_dict or G_reader_settings:readSetting("typewriter_fast_lookup_dict")
    if self.lookup.fast_lookup_enabled and self.lookup.fast_lookup_dict_ifo then
        self.lookup:openDict()
    end

    self:setupKeyEvents()
end

-- Key event suppression ------------------------------------------------------

-- Check if a key_event sequence entry matches a bare (unmodified) press
-- of any key in the given set. Sequences with modifiers (e.g. {"Shift","Right"})
-- are left alone.
local function seq_matches_bare_key(seq, key_set)
    if #seq ~= 1 then return false end
    local k = seq[1]
    if type(k) == "string" then
        return key_set[k] or false
    elseif type(k) == "table" then
        for _, v in ipairs(k) do
            if key_set[v] then return true end
        end
    end
    return false
end

-- When cursor is active, mark conflicting key_events on sibling modules
-- as inactive so they don't consume Left/Right/Up/Down/Press before us.
function Typewriter:suppressConflictingKeys()
    local dominated = { Left = true, Right = true, Up = true, Down = true, Press = true }
    -- Also suppress Back keys so we handle exit ourselves
    if Device.input.group.Back then
        for _, k in ipairs(Device.input.group.Back) do
            dominated[k] = true
        end
    end

    self._suppressed_events = {}

    -- Check children of ReaderUI (sibling modules)
    for _, module in ipairs(self.ui) do
        if module ~= self and module.key_events then
            for _, ev in pairs(module.key_events) do
                if not ev.is_inactive then
                    for _, seq in ipairs(ev) do
                        if seq_matches_bare_key(seq, dominated) then
                            ev.is_inactive = true
                            table.insert(self._suppressed_events, ev)
                            break
                        end
                    end
                end
            end
        end
    end

    -- Also check ReaderUI's own key_events (e.g. StartHighlightIndicator)
    if self.ui.key_events then
        for _, ev in pairs(self.ui.key_events) do
            if not ev.is_inactive then
                for _, seq in ipairs(ev) do
                    if seq_matches_bare_key(seq, dominated) then
                        ev.is_inactive = true
                        table.insert(self._suppressed_events, ev)
                        break
                    end
                end
            end
        end
    end

    logger.dbg("Typewriter: suppressed", #self._suppressed_events, "conflicting key bindings")
end

function Typewriter:restoreConflictingKeys()
    if self._suppressed_events then
        for _, ev in ipairs(self._suppressed_events) do
            ev.is_inactive = nil
        end
        logger.dbg("Typewriter: restored", #self._suppressed_events, "key bindings")
        self._suppressed_events = nil
    end
end

function Typewriter:setupKeyEvents()
    self.key_events = {}
    if not self.enabled or not Device:hasKeys() then return end
    logger.dbg("Typewriter: setupKeyEvents, cursor_active=", self.cursor.cursor_active)

    if self.cursor.cursor_active then
        self.key_events = {
            TypewriterLeft  = { { "Left" } },
            TypewriterRight = { { "Right" } },
            TypewriterUp    = { { "Up" } },
            TypewriterDown  = { { "Down" } },
            TypewriterBack  = { { Device.input.group.Back } },
            TypewriterPress = { { "Press" } },
        }
    else
        self.key_events = {
            TypewriterDown = { { "Down" } },
            TypewriterUp   = { { "Up" } },
        }
    end
end

-- Menu -----------------------------------------------------------------------

function Typewriter:addToMainMenu(menu_items)
    menu_items.typewriter = {
        text = _("Typewriter Cursor Mode"),
        checked_func = function() return self.enabled end,
        sorting_hint = "search",
        callback = function()
            self.enabled = not self.enabled
            G_reader_settings:saveSetting("typewriter_mode_enabled", self.enabled)
            if not self.enabled then
                self:deactivateCursor()
            end
            self:setupKeyEvents()
        end,
    }
    menu_items.typewriter_fast_lookup = {
        text = _("Fast Dictionary Lookup Settings"),
        sorting_hint = "search",
        sub_item_table = {
            {
                text = _("Enable Fast Dictionary Lookup"),
                checked_func = function() return self.lookup.fast_lookup_enabled end,
                callback = function()
                    self.lookup.fast_lookup_enabled = not self.lookup.fast_lookup_enabled
                    G_reader_settings:saveSetting("typewriter_fast_lookup_enabled", self.lookup.fast_lookup_enabled)
                    if self.lookup.fast_lookup_enabled and self.lookup.fast_lookup_dict_ifo then
                        self.lookup:openDict()
                    elseif not self.lookup.fast_lookup_enabled then
                        self.lookup:closeDict()
                    end
                end,
            },
            {
                text_func = function()
                    if self.lookup._dict_instance then
                        return _("Dictionary: ") .. self.lookup._dict_instance.bookname
                    elseif self.lookup.fast_lookup_dict_ifo then
                        return _("Dictionary: ") .. self.lookup.fast_lookup_dict_ifo
                    else
                        return _("Select dictionary")
                    end
                end,
                callback = function(touchmenu_instance)
                    self.lookup:showDictSelectionDialog(touchmenu_instance)
                end,
                keep_menu_open = true,
            },
            {
                text = _("Set as default dictionary"),
                callback = function()
                    if self.lookup.fast_lookup_dict_ifo then
                        G_reader_settings:saveSetting("typewriter_fast_lookup_dict", self.lookup.fast_lookup_dict_ifo)
                        local InfoMessage = require("ui/widget/infomessage")
                        UIManager:show(InfoMessage:new{
                            text = _("Dictionary set as default for all books"),
                            timeout = 3,
                        })
                    end
                end,
                show_func = function()
                    return self.lookup.fast_lookup_dict_ifo ~= nil
                       and self.lookup.fast_lookup_dict_ifo ~= G_reader_settings:readSetting("typewriter_fast_lookup_dict")
                end,
                keep_menu_open = true,
            },
        },
    }
end

-- Cursor lifecycle -----------------------------------------------------------

function Typewriter:activateCursor(from_top)
    if not self.cursor:activate(from_top) then return false end
    self:setupKeyEvents()
    self:suppressConflictingKeys()
    self:updateCursorDisplay()
    return true
end

function Typewriter:deactivateCursor()
    if not self.cursor.cursor_active then return end
    self.cursor:deactivate()
    self.highlight:reset()
    self.lookup:dismissWidget()
    self:restoreConflictingKeys()
    self:setupKeyEvents()
end

-- Display update (orchestrates cursor, highlight, and lookup) ----------------

function Typewriter:updateCursorDisplay()
    local old_geom = self.cursor:getOverlayGeom()

    if not self.cursor.cursor_active or not self.cursor.current_word_xp then
        self.cursor:hideOverlay(old_geom)
        return
    end

    local word_info, screen_x, screen_y = self.cursor:getWordInfoAtCursor()
    if not word_info or not word_info.sbox then
        self.cursor:updateOverlay(nil, nil, old_geom, false)
        self.lookup:dismissWidget()
        return
    end

    -- Compute screen boxes (respects highlight range if active)
    local sboxes = self.highlight:getWordScreenBoxes(
        word_info,
        self.cursor.current_word_xp,
        self.cursor.current_word_end_xp
    )
    self.cursor:updateOverlay(word_info, sboxes, old_geom, self.highlight.highlighting_active)

    -- Hide fast lookup while highlighting
    if self.highlight.highlighting_active then
        self.lookup:dismissWidget()
        return
    end

    self:updateLookupContent(word_info, screen_x, screen_y, sboxes)
end

--- Update the fast lookup widget content based on the word under cursor.
function Typewriter:updateLookupContent(word_info, screen_x, screen_y, sboxes)
    local doc = self.ui.document
    local first_rect = sboxes and sboxes[1] or word_info.sbox
    local bottom_y = first_rect.y + first_rect.h

    -- Try footnote text first
    local link_xpointer, a_xpointer = doc:getLinkFromPosition({x = screen_x, y = screen_y})
    if link_xpointer and link_xpointer ~= "" and a_xpointer and a_xpointer ~= "" then
        local footnote_text = self.lookup:getFootnoteText(link_xpointer, a_xpointer)
        if footnote_text then
            logger.dbg("Typewriter: footnote found")
            self.lookup:showWidget(_("Footnote"), footnote_text, nil, bottom_y)
            return
        end
    end

    -- Try dictionary lookup
    if not self.lookup.fast_lookup_enabled or not self.lookup._dict_instance then
        return
    end

    local entry, definition = self.lookup:lookupWord(word_info.word)
    if not entry or not definition then
        self.lookup:dismissWidget()
        return
    end

    self.lookup:showWidget(entry, definition, self.lookup._dict_instance.bookname, bottom_y)
end

-- Navigation helpers (delegate to cursor, handle page turns & deactivation) --

function Typewriter:moveOnSameLine(direction)
    if not self.cursor.cursor_active then return end

    local result = self.cursor:moveToWordOnSameLine(direction)
    if result == "moved" then
        self:updateCursorDisplay()
        return
    end

    -- Off-screen: try page turn during highlighting, otherwise deactivate
    if self.highlight.highlighting_active and self.cursor:goToNextPage(direction) then
        return
    end
    logger.dbg("Typewriter: moveOnSameLine off-screen, deactivating")
    self:deactivateCursor()
end

function Typewriter:moveOnNextLine(direction)
    if not self.cursor.cursor_active then return end

    local result = self.cursor:moveToWordOnNextLine(direction)
    if result == "moved" then
        self:updateCursorDisplay()
        return
    end

    -- No next-line word: try page turn during highlighting, otherwise deactivate
    if self.highlight.highlighting_active and self.cursor:goToNextPage(direction) then
        return
    end
    logger.dbg("Typewriter: moveOnNextLine no target, deactivating")
    self:deactivateCursor()
end

-- Key event handlers ---------------------------------------------------------

function Typewriter:onTypewriterDown()
    logger.dbg("Typewriter: onTypewriterDown, cursor_active=", self.cursor.cursor_active)
    if not self.cursor.cursor_active then
        return self:activateCursor(true) -- cursor at first word
    end
    self:moveOnNextLine("down")
    return true
end

function Typewriter:onTypewriterUp()
    logger.dbg("Typewriter: onTypewriterUp, cursor_active=", self.cursor.cursor_active)
    if not self.cursor.cursor_active then
        return self:activateCursor(false) -- cursor at last word
    end
    self:moveOnNextLine("up")
    return true
end

function Typewriter:onTypewriterLeft()
    if self.cursor.cursor_active then
        self:moveOnSameLine("left")
        return true
    end
    return false
end

function Typewriter:onTypewriterRight()
    if self.cursor.cursor_active then
        self:moveOnSameLine("right")
        return true
    end
    return false
end

function Typewriter:onTypewriterBack()
    logger.dbg("Typewriter: onTypewriterBack")
    if self.cursor.cursor_active then
        self:deactivateCursor()
        return true
    end
    return false
end

function Typewriter:onTypewriterPress()
    if not self.cursor.cursor_active then
        return false
    end

    if not self.highlight.highlighting_active then
        self.highlight:startAt(self.cursor.current_word_xp)
        self:updateCursorDisplay()
        return true
    end

    if self.highlight:openSelectionContextMenu(self.cursor) then
        self:deactivateCursor()
        return true
    end

    self.highlight:openWordContextMenu(self.cursor)
    self:deactivateCursor()
    return true
end

-- Page/position change handlers ----------------------------------------------

function Typewriter:onPageUpdate()
    if self.cursor._turning_page_direction then
        if self.cursor:recoverAfterPageTurn() then
            self:updateCursorDisplay()
        else
            self:deactivateCursor()
        end
    elseif self.cursor.cursor_active then
        self:deactivateCursor()
    end
end

function Typewriter:onUpdatePos()
    if self.cursor._turning_page_direction then return end
    if self.cursor.cursor_active then
        self:deactivateCursor()
    end
end

function Typewriter:onCloseDocument()
    self:deactivateCursor()
    self.lookup:closeDict()
end

return Typewriter
