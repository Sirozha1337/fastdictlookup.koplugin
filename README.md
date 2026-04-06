# Fast Dictionary Lookup (fastdictlookup.koplugin)

A [KOReader](https://github.com/koreader/koreader) plugin for fast dictionary lookup that mimics Kindle default dictionary behavior:
- move typewriter-like cursor with arrow buttons
- instantly see word definition
- press enter to open full dictionary lookup window


## 💾 Installation

1. Copy the plugin folder (`fastdictlookup.koplugin`) to your KOReader plugins directory:
   - `koreader/plugins/fastdictlookup.koplugin`
2. Make sure the folder contains:
   - `_meta.lua`
   - `main.lua`
   - `fastlookupwidget.lua`
   - `stardictlookup.lua`

## ▶️ Enabling the plugin

1. Start **KOReader**.
2. Open the **Top Settings menu**
3. Go to **Tools** (icon with tools) -> **Plugin management**
4. Find **Fast Dictionary Lookup** in the list and enable it
5. Restart **KOReader** if required
6. Open the book
7. Open the **Top Settings menu**
8. Go to **Search** (icon with magnifying glass)
9. Enable **Typewriter Cursor Mode**
10. Enter **Fast Dictionary Lookup** to setup dictionary
11. Wait for the dictionary to load (usually less than 30 seconds, depends on the size of the dictionary)
12. Use **Up/Down** arrow keys to enter **Typewriter Cursor Mode**
13. Move cursor with arrows and instantly see word definitions from your selected dictionary
14. Move cursor to the end/beginning of the page or press **Back** button to exit 

**Note**: dictionaries are read from the default KOReader's dictionary folder: `koreadeader/data/dict/`

## 📱 Compatibility

- Device: Kindle 4 NonTouch (confirmed)
- Possibly other devices that have buttons

## 🗂️ Dictionary requirements

The plugin uses StarDict dictionary files in a plain (uncompressed) format. 

Notes for consideration:
- Only one dictionary at a time is supported
- Dictionaries bigger than 2GB are not supported
- Compressed dictionaries (`.dz`) are not supported. You can unzip them manually: 
    ```bash
    mv dictionary.dict.dz dictionary.dict.gz
    gunzip dictionary.dict.gz
    ```
- Synonyms (`.syn` files) are not supported. Use `pyglossary` to merge dictionaries with synonyms (`.syn` files):
  ```bash
    pip install pyglossary
    pyglossary --write-format=StardictMergeSyns dictionary_with_syns.ifo dictionary_merged.ifo
  ```
- HTML rendering not supported. If dictionary definitions contain HTML entities, they will be removed, only the text content will be displayed

## 📝 Further work and improvements

Since the plugin targets mainly my Kindle (which is Kindle 4 NonTouch from 2012), those features would need careful consideration as to whether the device is powerful enough handle it.

- Replace default lookup menu opened on tap/enter with fastlookup
- Use multiple dictionaries at the same time
- Load dictionary depending on book language
- Handle html/markdown data in dictionary

## 💻 Implementation notes

The plugin consists of three core Lua modules:

- `main.lua` implements the `Typewriter` helper for cursor-based word navigation and fast lookup trigger:
  - `typewriter_mode_enabled` checkbox toggles cursor mode.
  - `typewriter_fast_lookup_enabled` toggles live dictionary preview.
  - `typewriter_fast_lookup_dict` stores the selected dictionary `.ifo` file path. It saves uniquely per-book (`self.ui.doc_settings`) and falls back to the global default (`G_reader_settings`). There is an option to set the current dictionary as the global default.
  - `setupKeyEvents()` binds arrow keys and `Press`/`Back` while cursor is active.
  - `activateCursor()` / `deactivateCursor()` manage state, overlay and key suppression.
  - `showFastLookup(word, y)` calls StarDict lookup and spawns `FastLookupWidget`.

- `stardictlookup.lua` supports StarDict dictionary discovery and fast lookups:
  - `getAvailableDicts(data_dir)` recursively scans `data/dict` (and `data/dict_ext`) for `.ifo` files with uncompressed `.dict`.
  - `hasUncompressedDict(ifo_path)` requires `.dict` and rejects `.dict.dz`.
  - `DictInstance.open(meta)` mmap's `.idx` and parses a compact in-memory index table for O(log n) binary search.
  - `DictInstance:lookup(word)` binary-searches the mmaped `.idx`, compares lowercase entries, and returns offset/size.
  - `DictInstance:getDefinition(entry)` reads raw `.dict` bytes and extracts text from type-prefixed fields.
  - `getDefinitionPreview(entry)` strips HTML, decodes entities.

- `fastlookupwidget.lua` renders floating Word+Definition overlay:
  - Shows current word, first lines of definition, and dictionary source name.
  - Picks top/bottom placement based on on-screen word position.

- `_meta.lua` declares plugin name, title, and description for KOReader plugin discovery.

### Fast lookup flow

1. Plugin enabled and dictionary selected from plugin menu (`Typewriter Fast Dictionary Lookup Settings`).
2. `openFastLookupDict()` loads metadata, verifies `.dict`, opens `DictInstance`.
3. Cursor mode navigates words; on each position update, `Typewriter:updateCursorDisplay()` finds the word with `doc:getWordFromPosition()`.
4. `showFastLookup()` obtains `DictInstance:lookup(word)` and `getDefinitionPreview()` and displays it in `FastLookupWidget`.
