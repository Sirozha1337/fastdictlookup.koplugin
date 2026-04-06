local InputContainer = require("ui/widget/container/inputcontainer")
local DataStorage = require("datastorage")
local Device = require("device")
local Geom = require("ui/geometry")
local Screen = Device.screen
local Size = require("ui/size")
local UIManager = require("ui/uimanager")
local Blitbuffer = require("ffi/blitbuffer")
local logger = require("logger")
local time = require("ui/time")
local _ = require("gettext")

local Typewriter = InputContainer:extend{
    name = "typewriter",
    is_doc_only = true,

    -- State
    enabled = false,
    cursor_active = false,
    current_word_xp = nil,      -- xpointer to current word start
    current_word_end_xp = nil,  -- xpointer to current word end

    -- Fast dictionary lookup
    fast_lookup_enabled = false,
    fast_lookup_dict_ifo = nil, -- ifo_path of selected dictionary
    _dict_instance = nil,       -- opened StarDictLookup.DictInstance
    _fast_lookup_widget = nil,  -- currently shown FastLookupWidget
}

function Typewriter:init()
    logger.dbg("Typewriter: init")

    self.ui.menu:registerToMainMenu(self)

    -- Hook the top menu creation to dismiss our custom widgets
    local orig_onShowMenu = self.ui.menu.onShowMenu
    self.ui.menu.onShowMenu = function(menu_self, tab_index, do_not_show)
        self:deactivateCursor()
        self:dismissFastLookup()
        return orig_onShowMenu(menu_self, tab_index, do_not_show)
    end

    self.enabled = G_reader_settings:isTrue("typewriter_mode_enabled")

    -- Fast lookup settings
    self.fast_lookup_enabled = G_reader_settings:isTrue("typewriter_fast_lookup_enabled")
    local doc_dict = self.ui.doc_settings and self.ui.doc_settings:readSetting("typewriter_fast_lookup_dict")
    self.fast_lookup_dict_ifo = doc_dict or G_reader_settings:readSetting("typewriter_fast_lookup_dict")
    if self.fast_lookup_enabled and self.fast_lookup_dict_ifo then
        self:openFastLookupDict()
    end

    -- Overlay widget registered as a view module for drawing on the page
    self._cursor_overlay = {
        visible = false,
        cursor_rect = nil, -- {x, y, h} vertical cursor line
        word_rect = nil,   -- {x, y, w, h} word underline
        paintTo = function(overlay, bb, x, y)
            if not overlay.visible then return end
            if overlay.word_rect then
                local r = overlay.word_rect
                bb:paintRect(r.x, r.y + r.h - Size.border.thick,
                    r.w, Size.border.thick, Blitbuffer.COLOR_DARK_GRAY)
            end
            if overlay.cursor_rect then
                local r = overlay.cursor_rect
                bb:paintRect(r.x, r.y, Screen:scaleBySize(2), r.h,
                    Blitbuffer.COLOR_BLACK)
            end
        end,
    }

    if self.ui.view then
        self.ui.view:registerViewModule("typewriter_cursor", self._cursor_overlay)
    end

    self:setupKeyEvents()
end

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
    logger.dbg("Typewriter: setupKeyEvents, cursor_active=", self.cursor_active)

    if self.cursor_active then
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
                checked_func = function() return self.fast_lookup_enabled end,
                callback = function()
                    self.fast_lookup_enabled = not self.fast_lookup_enabled
                    G_reader_settings:saveSetting("typewriter_fast_lookup_enabled", self.fast_lookup_enabled)
                    if self.fast_lookup_enabled and self.fast_lookup_dict_ifo then
                        self:openFastLookupDict()
                    elseif not self.fast_lookup_enabled then
                        self:closeFastLookupDict()
                    end
                end,
            },
            {
                text_func = function()
                    if self._dict_instance then
                        return _("Dictionary: ") .. self._dict_instance.bookname
                    elseif self.fast_lookup_dict_ifo then
                        return _("Dictionary: ") .. self.fast_lookup_dict_ifo
                    else
                        return _("Select dictionary")
                    end
                end,
                callback = function(touchmenu_instance)
                    self:showDictSelectionDialog(touchmenu_instance)
                end,
                keep_menu_open = true,
            },
            {
                text = _("Set as default dictionary"),
                callback = function()
                    if self.fast_lookup_dict_ifo then
                        G_reader_settings:saveSetting("typewriter_fast_lookup_dict", self.fast_lookup_dict_ifo)
                        local InfoMessage = require("ui/widget/infomessage")
                        UIManager:show(InfoMessage:new{
                            text = _("Dictionary set as default for all books"),
                            timeout = 3,
                        })
                    end
                end,
                show_func = function()
                    return self.fast_lookup_dict_ifo ~= nil and self.fast_lookup_dict_ifo ~= G_reader_settings:readSetting("typewriter_fast_lookup_dict")
                end,
                keep_menu_open = true,
            },
        },
    }
end

-- Fast dictionary lookup methods -----------------------------------------------

function Typewriter:getDataDir()
    return G_defaults:readSetting("STARDICT_DATA_DIR")
        or os.getenv("STARDICT_DATA_DIR")
        or DataStorage:getDataDir() .. "/data/dict"
end

function Typewriter:openFastLookupDict()
    self:closeFastLookupDict()
    if not self.fast_lookup_dict_ifo then return end

    local StarDictLookup = require("stardictlookup")
    local meta = StarDictLookup.parseIfo(self.fast_lookup_dict_ifo)
    if not meta then
        logger.warn("Typewriter: failed to parse ifo:", self.fast_lookup_dict_ifo)
        return
    end
    local has_dict, dict_path = StarDictLookup.hasUncompressedDict(self.fast_lookup_dict_ifo)
    if not has_dict then
        logger.warn("Typewriter: no uncompressed .dict for:", self.fast_lookup_dict_ifo)
        return
    end
    meta.dict_path = dict_path
    meta.idx_path = self.fast_lookup_dict_ifo:gsub("%.ifo$", ".idx")

    local instance, err = StarDictLookup.open(meta)
    if not instance then
        logger.warn("Typewriter: failed to open dict:", err)
        return
    end
    self._dict_instance = instance
    logger.dbg("Typewriter: fast lookup dict opened:", instance.bookname, "#entries:", instance.entry_count)
end

function Typewriter:closeFastLookupDict()
    if self._dict_instance then
        self._dict_instance:close()
        self._dict_instance = nil
    end
end

function Typewriter:showDictSelectionDialog(touchmenu_instance)
    local StarDictLookup = require("stardictlookup")
    local ButtonDialog = require("ui/widget/buttondialog")
    local InfoMessage = require("ui/widget/infomessage")

    local data_dir = self:getDataDir()
    local dicts = StarDictLookup.getAvailableDicts(data_dir)

    if #dicts == 0 then
        UIManager:show(InfoMessage:new{
            text = _("No uncompressed StarDict dictionaries found.\nOnly dictionaries with .dict files (not .dict.dz) are supported."),
        })
        return
    end

    local buttons = {}
    for _, dict in ipairs(dicts) do
        local is_selected = self.fast_lookup_dict_ifo == dict.ifo_path
        local label = dict.bookname
        if is_selected then
            label = "★ " .. label
        end
        if dict.wordcount then
            label = label .. " (" .. dict.wordcount .. ")"
        end
        table.insert(buttons, {{
            text = label,
            callback = function()
                self.fast_lookup_dict_ifo = dict.ifo_path
                if self.ui.doc_settings then
                    self.ui.doc_settings:saveSetting("typewriter_fast_lookup_dict", dict.ifo_path)
                end
                if self.fast_lookup_enabled then
                    self:openFastLookupDict()
                end
                UIManager:close(self._dict_select_dialog)
                self._dict_select_dialog = nil
                if touchmenu_instance then touchmenu_instance:updateItems() end
            end,
        }})
    end

    self._dict_select_dialog = ButtonDialog:new{
        title = _("Select dictionary for fast lookup"),
        buttons = buttons,
    }
    UIManager:show(self._dict_select_dialog)
end

function Typewriter:dismissFastLookup()
    if self._fast_lookup_widget then
        UIManager:close(self._fast_lookup_widget)
        self._fast_lookup_widget = nil
    end
end

function Typewriter:showFastLookup(word, word_box_bottom_y)
    if not self.fast_lookup_enabled or not self._dict_instance then return end
    if not word or word == "" then
        self:dismissFastLookup()
        return
    end

    -- Clean the word: trim whitespace and punctuation
    word = word:gsub("^[%s%p]+", ""):gsub("[%s%p]+$", "")
    if word == "" then
        self:dismissFastLookup()
        return
    end

    local entry = self._dict_instance:lookup(word)
    local definition, position
    if entry then
        definition = self._dict_instance:getDefinitionPreview(entry)
    end

    -- Determine position based on word location
    local screen_h = Screen:getHeight()
    if word_box_bottom_y and word_box_bottom_y > screen_h / 2 then
        position = "top"
    else
        position = "bottom"
    end

    -- Dismiss previous widget if any
    self:dismissFastLookup()

    local FastLookupWidget = require("fastlookupwidget")
    self._fast_lookup_widget = FastLookupWidget:new{
        word = word,
        definition = definition,
        dict_name = self._dict_instance.bookname,
        position = position,
        word_box_bottom_y = word_box_bottom_y,
    }
    UIManager:show(self._fast_lookup_widget)
end

-- Only CRE (EPUB/FB2) documents support xpointer-based word navigation
function Typewriter:isCREDocument()
    return self.ui.rolling ~= nil
end

function Typewriter:getVisibleHeight()
    if self.ui.view and self.ui.view.visible_area then
        return self.ui.view.visible_area.h
    end
    return Screen:getHeight()
end

function Typewriter:isXPointerOnScreen(xp)
    if not xp then return false end
    return self.ui.document:isXPointerInCurrentPage(xp)
end

function Typewriter:findFirstWordOnPage()
    local doc = self.ui.document
    local top_xp = doc:getXPointer()
    logger.dbg("Typewriter: findFirstWordOnPage, top_xp=", top_xp)
    if not top_xp then return nil end

    -- Step one char before page start so getNextVisibleWordStart
    -- will find a word that begins exactly at the page top
    local before = doc:getPrevVisibleChar(top_xp)
    local word_xp
    if before then
        word_xp = doc:getNextVisibleWordStart(before)
    end
    if word_xp and self:isXPointerOnScreen(word_xp) then
        return word_xp
    end

    -- Fallback: search forward from the page-start xpointer
    word_xp = doc:getNextVisibleWordStart(top_xp)
    if word_xp and self:isXPointerOnScreen(word_xp) then
        return word_xp
    end
    return nil
end

function Typewriter:findLastWordOnPage()
    logger.dbg("Typewriter: findLastWordOnPage")
    local doc = self.ui.document

    -- getPrevVisibleWordStart always moves strictly backward, so if pos1 from
    -- getTextFromPositions snaps to an early position on the last line (because the
    -- bottom-right coordinate falls outside the text area), it returns the wrong word.
    -- Walk forward from the first visible word instead to reliably find the last one.
    local cur_xp = self:findFirstWordOnPage()
    if not cur_xp then return nil end

    local last_xp = cur_xp
    for _ = 1, 2000 do
        local next_xp = doc:getNextVisibleWordStart(cur_xp)
        if not next_xp then
            logger.dbg("Typewriter: findLastWordOnPage no more words after", cur_xp)
            break
        end
        -- compareXPointers returns 1 if xp2 is after xp1; stop if no forward progress
        if doc:compareXPointers(cur_xp, next_xp) ~= 1 then
            logger.dbg("Typewriter: findLastWordOnPage no forward progress from", cur_xp)
            break
        end
        if not self:isXPointerOnScreen(next_xp) then
            logger.dbg("Typewriter: findLastWordOnPage isXPointerOnScreen returned false for", next_xp)
            break
        end
        last_xp = next_xp
        cur_xp = next_xp
    end
    logger.dbg("Typewriter: findLastWordOnPage', last_xp=", last_xp, "isXPointerOnScreen=", self:isXPointerOnScreen(last_xp))
    return last_xp
end

function Typewriter:activateCursor(from_top)
    logger.dbg("Typewriter: activateCursor, from_top=", from_top)
    if not self:isCREDocument() then
        logger.dbg("Typewriter: not a CRE document, skipping")
        return false
    end

    local doc = self.ui.document
    local word_xp = from_top
        and self:findFirstWordOnPage()
        or  self:findLastWordOnPage()
    if not word_xp then return false end

    self.current_word_xp = word_xp
    self.current_word_end_xp = doc:getNextVisibleWordEnd(word_xp)
    self.cursor_active = true
    logger.dbg("Typewriter: cursor activated, word_xp=", word_xp)
    self:setupKeyEvents()
    self:suppressConflictingKeys()
    self:updateCursorDisplay()
    return true
end

function Typewriter:deactivateCursor()
    if not self.cursor_active then return end
    logger.dbg("Typewriter: deactivateCursor")
    self.cursor_active = false
    self.current_word_xp = nil
    self.current_word_end_xp = nil
    self._cursor_overlay.visible = false
    self._cursor_overlay.cursor_rect = nil
    self._cursor_overlay.word_rect = nil
    self:dismissFastLookup()
    self:restoreConflictingKeys()
    self:setupKeyEvents()
    UIManager:setDirty(self.ui, "ui")
end

function Typewriter:updateCursorDisplay()
    if not self.cursor_active or not self.current_word_xp then
        self._cursor_overlay.visible = false
        return
    end

    local doc = self.ui.document
    local screen_y, screen_x = doc:getScreenPositionFromXPointer(self.current_word_xp)
    logger.dbg("Typewriter: updateCursorDisplay, screen_x=", screen_x, "screen_y=", screen_y, "word_xp=", self.current_word_xp, "word=", doc:getTextFromXPointer(self.current_word_xp))
    if not screen_y or not screen_x then
        self._cursor_overlay.visible = false
        return
    end

    local word_info = doc:getWordFromPosition({x = screen_x, y = screen_y}, true)
    if word_info and word_info.sbox then
        local s = word_info.sbox
        logger.dbg("Typewriter: updateCursorDisplay word=", word_info.word,
            "box x=", s.x, "y=", s.y, "w=", s.w, "h=", s.h)
        self._cursor_overlay.cursor_rect = { x = s.x, y = s.y, h = s.h }
        self._cursor_overlay.word_rect   = { x = s.x, y = s.y, w = s.w, h = s.h }
        -- Trigger fast lookup for the word under cursor
        self:showFastLookup(word_info.word, s.y + s.h)
    else
        logger.dbg("Typewriter: updateCursorDisplay no word at screen pos", screen_x, screen_y)
        local h = Screen:scaleBySize(20)
        self._cursor_overlay.cursor_rect = { x = screen_x, y = screen_y, h = h }
        self._cursor_overlay.word_rect = nil
        self:dismissFastLookup()
    end

    self._cursor_overlay.visible = true
    UIManager:setDirty(self.ui, "ui")
end

function Typewriter:moveToNextWord()
    if not self.cursor_active or not self.current_word_xp then return end
    local doc = self.ui.document
    logger.dbg("Typewriter: moveToNextWord from", self.current_word_xp, "word=", doc:getTextFromXPointer(self.current_word_xp))

    local next_xp = doc:getNextVisibleWordStart(self.current_word_xp)
    logger.dbg("Typewriter: moveToNextWord got next_xp=", next_xp, "word=", doc:getTextFromXPointer(next_xp))

    -- If stuck at same position, try advancing from word end
    if next_xp and self.current_word_end_xp
       and doc:compareXPointers(self.current_word_xp, next_xp) ~= 1 then
        logger.dbg("Typewriter: moveToNextWord stuck at same word, trying from word end")
        next_xp = doc:getNextVisibleWordStart(self.current_word_end_xp)
    end

    local is_on_screen = self:isXPointerOnScreen(next_xp)
    if next_xp then
        logger.dbg("Typewriter: moveToNextWord next_xp=", next_xp, "word=",
            doc:getTextFromXPointer(next_xp), "is_on_screen=", is_on_screen)
    end

    if not next_xp or not is_on_screen then
        logger.dbg("Typewriter: moveToNextWord off-screen or nil, deactivating")
        self:deactivateCursor()
        return
    end

    logger.dbg("Typewriter: moveToNextWord to", next_xp, "word=", doc:getTextFromXPointer(next_xp))
    self.current_word_xp = next_xp
    self.current_word_end_xp = doc:getNextVisibleWordEnd(next_xp)
    self:updateCursorDisplay()
end

function Typewriter:moveToPrevWord()
    if not self.cursor_active or not self.current_word_xp then return end
    logger.dbg("Typewriter: moveToPrevWord from", self.current_word_xp)

    local doc = self.ui.document
    local prev_xp = doc:getPrevVisibleWordStart(self.current_word_xp)

    local is_on_screen = self:isXPointerOnScreen(prev_xp)
    if prev_xp then
        logger.dbg("Typewriter: moveToPrevWord prev_xp=", prev_xp, "word=",
            doc:getTextFromXPointer(prev_xp), "is_on_screen=", is_on_screen)
    end

    if not prev_xp or not self:isXPointerOnScreen(prev_xp) then
        logger.dbg("Typewriter: moveToPrevWord off-screen or nil, deactivating")
        self:deactivateCursor()
        return
    end

    logger.dbg("Typewriter: moveToPrevWord to", prev_xp, "word=", doc:getTextFromXPointer(prev_xp))
    self.current_word_xp = prev_xp
    self.current_word_end_xp = doc:getNextVisibleWordEnd(prev_xp)
    self:updateCursorDisplay()
end

function Typewriter:openWordContextMenu()
    if not self.cursor_active or not self.current_word_xp then return end
    logger.dbg("Typewriter: openWordContextMenu")

    local doc = self.ui.document
    local screen_y, screen_x = doc:getScreenPositionFromXPointer(self.current_word_xp)
    if not screen_y or not screen_x then
        logger.dbg("Typewriter: openWordContextMenu no screen pos")
        return
    end

    local word_info = doc:getWordFromPosition({x = screen_x, y = screen_y}, true)
    if not word_info or not word_info.sbox then
        logger.dbg("Typewriter: openWordContextMenu no word at pos")
        return
    end
    logger.dbg("Typewriter: opening context menu for word:", word_info.word)

    local cx = word_info.sbox.x + word_info.sbox.w / 2
    local cy = word_info.sbox.y + word_info.sbox.h / 2
    local pos = Geom:new{x = cx, y = cy, w = 0, h = 0}

    -- Deactivate cursor before showing the menu
    self:deactivateCursor()

    -- Simulate hold + release to trigger the default word context menu
    self.ui.highlight:onHold(nil, {
        ges = "hold", pos = pos, time = time.realtime(),
    })
    self.ui.highlight:onHoldRelease(nil, {
        ges = "hold_release", pos = pos, time = time.realtime(),
    })
end

function Typewriter:moveToWordOnNextLine()
    if not self.cursor_active or not self.current_word_xp then return end
    local doc = self.ui.document

    local screen_y, screen_x = doc:getScreenPositionFromXPointer(self.current_word_xp)
    if not screen_y or not screen_x then return end

    local cur_info = doc:getWordFromPosition({x = screen_x, y = screen_y}, true)
    if not cur_info or not cur_info.sbox then return end

    local s = cur_info.sbox
    local cx = s.x + math.floor(s.w / 2)

    -- Try progressively larger downward steps until the probe lands on a
    -- word whose sbox.y is clearly below the current line.
    local next_info
    for _, dy in ipairs({s.h, math.floor(s.h * 1.5), s.h * 2, math.floor(s.h * 2.5), s.h * 3 }) do
        local probe = doc:getWordFromPosition({x = cx, y = s.y + dy}, true)
        if probe and probe.sbox and probe.pos0 and
           probe.sbox.y > s.y and
           self:isXPointerOnScreen(probe.pos0) then
            next_info = probe
            break
        end
    end

    if not next_info then
        logger.dbg("Typewriter: moveToWordOnNextLine no next-line word found, deactivating")
        self:deactivateCursor()
        return
    end

    logger.dbg("Typewriter: moveToWordOnNextLine to", next_info.pos0, "word=", next_info.word)
    self.current_word_xp = next_info.pos0
    self.current_word_end_xp = doc:getNextVisibleWordEnd(next_info.pos0)
    self:updateCursorDisplay()
end

function Typewriter:moveToWordOnPrevLine()
    if not self.cursor_active or not self.current_word_xp then return end
    local doc = self.ui.document

    local screen_y, screen_x = doc:getScreenPositionFromXPointer(self.current_word_xp)
    if not screen_y or not screen_x then return end

    local cur_info = doc:getWordFromPosition({x = screen_x, y = screen_y}, true)
    if not cur_info or not cur_info.sbox then return end

    local s = cur_info.sbox
    local cx = s.x + math.floor(s.w / 2)

    -- Try progressively larger upward steps until the probe lands on a
    -- word whose sbox.y is clearly above the current line.
    local prev_info
    for _, dy in ipairs({s.h, math.floor(s.h * 1.5), s.h * 2, math.floor(s.h * 2.5), s.h * 3 }) do
        local probe = doc:getWordFromPosition({x = cx, y = s.y - dy}, true)
        if probe and probe.sbox and probe.pos0 and
           probe.sbox.y < s.y and
           self:isXPointerOnScreen(probe.pos0) then
            prev_info = probe
            break
        end
    end

    if not prev_info then
        logger.dbg("Typewriter: moveToWordOnPrevLine no prev-line word found, deactivating")
        self:deactivateCursor()
        return
    end

    logger.dbg("Typewriter: moveToWordOnPrevLine to", prev_info.pos0, "word=", prev_info.word)
    self.current_word_xp = prev_info.pos0
    self.current_word_end_xp = doc:getNextVisibleWordEnd(prev_info.pos0)
    self:updateCursorDisplay()
end

-- Key event handlers -------------------------------------------------------

function Typewriter:onTypewriterDown()
    logger.dbg("Typewriter: onTypewriterDown, cursor_active=", self.cursor_active)
    if not self.cursor_active then
        return self:activateCursor(true) -- cursor at first word
    end
    self:moveToWordOnNextLine()
    return true
end

function Typewriter:onTypewriterUp()
    logger.dbg("Typewriter: onTypewriterUp, cursor_active=", self.cursor_active)
    if not self.cursor_active then
        return self:activateCursor(false) -- cursor at last word
    end
    self:moveToWordOnPrevLine()
    return true
end

function Typewriter:onTypewriterLeft()
    if self.cursor_active then
        self:moveToPrevWord()
        return true
    end
    return false
end

function Typewriter:onTypewriterRight()
    if self.cursor_active then
        self:moveToNextWord()
        return true
    end
    return false
end

function Typewriter:onTypewriterBack()
    logger.dbg("Typewriter: onTypewriterBack")
    if self.cursor_active then
        self:deactivateCursor()
        return true
    end
    return false
end

function Typewriter:onTypewriterPress()
    if self.cursor_active then
        self:openWordContextMenu()
        return true
    end
    return false
end

-- Deactivate on page/position changes -------------------------------------

function Typewriter:onPageUpdate()
    if self.cursor_active then
        self:deactivateCursor()
    end
end

function Typewriter:onUpdatePos()
    if self.cursor_active then
        self:deactivateCursor()
    end
end

function Typewriter:onCloseDocument()
    self:deactivateCursor()
    self:closeFastLookupDict()
end

return Typewriter
