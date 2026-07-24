# AGENTS.md — Project Reference

## Overview

**fastdictlookup.koplugin** is a [KOReader](https://github.com/koreader/koreader) plugin for hardware-key-driven word navigation and instant dictionary lookup. It targets CRE (EPUB/FB2) documents on e-ink devices with physical buttons (primarily Kindle 4 NonTouch).

## Architecture

The plugin follows a **composition pattern**: a thin orchestrator (`Typewriter` in `main.lua`) composes three independent controller modules — cursor navigation, text highlighting, and dictionary lookup. Each controller is a plain Lua class receiving a `ui` reference.

```
main.lua  (Typewriter — orchestrator)
  ├── cursor.lua        (CursorNavigator)
  ├── highlighting.lua  (HighlightController)
  └── fastlookup.lua    (FastLookupController)
        └── htmlutil.lua      (shared utility)
        └── stardictlookup.lua (StarDict binary reader)
              └── htmlutil.lua
fastlookupwidget.lua    (floating UI widget)
_meta.lua               (plugin metadata for KOReader discovery)
```

## File Responsibilities

### main.lua — Typewriter (orchestrator)

- **InputContainer** subclass — the only module that handles key events
- Composes `CursorNavigator`, `HighlightController`, `FastLookupController` in `init()`
- Owns: menu registration, key event setup/suppression, cursor lifecycle (`activateCursor`/`deactivateCursor`)
- `updateCursorDisplay()` orchestrates overlay rendering, highlight box computation, and lookup content
- `updateLookupContent()` tries footnote detection first, then dictionary lookup
- Delegates navigation to cursor module; handles page-turn fallback and deactivation logic

### cursor.lua — CursorNavigator

- Manages: `cursor_active`, `current_word_xp`, `current_word_end_xp`, `_turning_page_direction`
- Owns the `_overlay` object registered as a view module (`"typewriter_cursor"`) for painting cursor line and word underlines/inversion
- Word finding: `findFirstWordOnPage()`, `findLastWordOnPage()` (walks forward from first word, bounded by `MAX_WORD_SCAN_ITERATIONS`)
- Navigation: `moveToWordOnSameLine(direction)`, `moveToWordOnNextLine(direction)` — return `"moved"` or `nil` so the caller decides page-turn vs deactivation
- `moveToWordOnNextLine` uses `VERTICAL_PROBE_MULTIPLIERS` to probe progressively larger vertical offsets
- Page turns: `goToNextPage(direction)` fires a `GotoPage` event; `recoverAfterPageTurn()` recovers cursor on the new page
- Overlay: `updateOverlay()`, `hideOverlay()`, `getOverlayGeom()` for targeted dirty-region redraws

### highlighting.lua — HighlightController

- Manages: `highlighting_active`, `highlight_start_xp`
- `getHighlightRange(current_word_xp, current_word_end_xp)` — normalizes start/end xpointers so start always comes before end in document order (using `compareXPointers`)
- `getWordScreenBoxes(word_info, ...)` — computes screen boxes for highlighted range or single word
- `openSelectionContextMenu(cursor)` — populates KOReader's `self.ui.highlight.selected_text` and calls `onShowHighlightMenu()`
- `openWordContextMenu(cursor)` — simulates hold+release gesture to trigger the native word context menu

### fastlookup.lua — FastLookupController

- Manages: `fast_lookup_enabled`, `fast_lookup_dict_ifo`, `_dict_instance`, `_fast_lookup_widget`
- Dictionary lifecycle: `openDict()`, `closeDict()`, `showDictSelectionDialog()`
- `lookupWord(word)` — pure query, trims punctuation, returns `(cleaned_word, definition)` or `(nil, nil)`. No side effects.
- `getFootnoteText(link_xpointer, a_xpointer)` — uses CRE `isLinkToFootnote()` with `FOOTNOTE_FLAGS` bitmask, extracts HTML, strips via `HtmlUtil`
- Widget lifecycle: `showWidget()`, `dismissWidget()`
- Named constants (with inline documentation of each flag bit):
  - `FOOTNOTE_FLAGS` — bitmask for CRE footnote detection
  - `MAX_FOOTNOTE_TEXT_SIZE` — character limit for extracted footnote text
  - `FOOTNOTE_HTML_FLAGS` — flags for `getHTMLFromXPointer(s)`

### fastlookupwidget.lua — FastLookupWidget

- Floating toast-like widget showing word, definition preview, and dictionary name
- Positions itself at top or bottom of screen based on `word_box_bottom_y` (avoids obscuring the highlighted word)
- Marked as `toast = true` so it never blocks event propagation

### stardictlookup.lua — StarDictLookup + DictInstance

- `StarDictLookup` (static methods): `.parseIfo()`, `.hasUncompressedDict()`, `.getAvailableDicts()`, `.open()`
- `DictInstance` (opened dictionary): mmap-based `.idx` reader with compact `uint32_t` offset table
  - Uses single-pass index build when `wordcount` is available from `.ifo` metadata; falls back to two-pass otherwise
  - `lookup(word)` — O(log n) binary search, case-insensitive, reads words directly from mmap'd memory
  - `getDefinition(entry)` — reads raw bytes from `.dict` file, handles `sametypesequence` and per-field type markers
  - `getDefinitionPreview(entry)` — strips HTML via `HtmlUtil.stripHtml()` for HTML-type dictionaries
  - `close()` — unmaps index, closes file handle

### htmlutil.lua — HtmlUtil

- Single function: `HtmlUtil.stripHtml(html)` — converts HTML to plain text
- Handles: `<div>`, `<p>`, `<br>` → newlines; all other tags → spaces; entity decoding (`&amp;`, `&lt;`, `&#NNN;`, etc.); whitespace normalization

## Settings & State

All settings use the `typewriter_` prefix (legacy naming preserved for backward compatibility):

| Setting Key                      | Scope             | Description                        |
| -------------------------------- | ----------------- | ---------------------------------- |
| `typewriter_mode_enabled`        | Global            | Cursor mode on/off                 |
| `typewriter_highlighting_enabled` | Global            | Text highlighting mode on/off (default: true) |
| `typewriter_override_lookup_menu` | Global            | Direct full definition view on single word lookup (default: false) |
| `typewriter_fast_lookup_enabled` | Global            | Live dictionary preview on/off     |
| `typewriter_fast_lookup_dict`    | Global + per-book | `.ifo` path of selected dictionary |

Per-book settings override global defaults (read from `self.ui.doc_settings`, written back on selection).

## Key Event Flow

1. **Inactive cursor**: `Down` → `activateCursor(true)` (first word), `Up` → `activateCursor(false)` (last word)
2. **Active cursor**: Arrow keys navigate word-by-word; `Back` deactivates; `Press` toggles highlighting mode
3. **Highlighting active**: Arrow keys extend selection; `Press` opens context menu (selection or single word)
4. Key suppression: `suppressConflictingKeys()` marks sibling modules' arrow/press/back bindings as `is_inactive` while cursor is active; `restoreConflictingKeys()` reverses this on deactivation

## Development & Testing

- Copy folder contents to `koreader/plugins/fastdictlookup.koplugin` and start KOReader
- Plugin targets Kindle 4 NT (low RAM, e-ink) — avoid large allocations, prefer targeted screen updates over full redraws
