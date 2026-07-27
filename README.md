# Fast Dictionary Lookup (fastdictlookup.koplugin)

![GitHub release (latest by date)](https://img.shields.io/github/v/release/Sirozha1337/fastdictlookup.koplugin?style=for-the-badge&color=orange) ![GitHub all releases](https://img.shields.io/github/downloads/Sirozha1337/fastdictlookup.koplugin/total?style=for-the-badge&color=yellow) ![Platform](https://img.shields.io/badge/Platform-KOReader-success?style=for-the-badge&logo=koreader)

A [KOReader](https://github.com/koreader/koreader) plugin for fast dictionary lookup that mimics Kindle default dictionary behavior:

- move typewriter-like cursor with arrow buttons
- instantly see word definition
- moving a cursor over a footnote link, immediately displays its content
- highlighting mode: press button to start highlighting, press again to open context menu and save your notes

## ⚠️ Versions & Compatibility

- Versions prior to 1.5 are not compatible with KOReader 2026.07 and newer

## 💾 Installation

1. Download latest release from [Releases](https://github.com/Sirozha1337/fastdictlookup.koplugin/releases/latest)
2. Unzip `fastdictlookup.koplugin-vX.X.X.zip`
3. Copy the plugin folder (`fastdictlookup.koplugin`) to your KOReader plugins directory:
   - `koreader/plugins/fastdictlookup.koplugin`
4. Make sure the folder contains:
   - `_meta.lua`
   - `main.lua`
   - `fastlookupwidget.lua`
   - `stardictlookup.lua`

You can use [UpdatesManager](https://github.com/advokatb/updatesmanager.koplugin) plugin to update this plugin from KOReader directly.

## ⚙️ Enabling the plugin

1. Start **KOReader**.
2. Open the **Top Settings menu**
3. Go to **Tools** (icon with tools) -> **Plugin management**
4. Find **Fast Dictionary Lookup** in the list and enable it
5. Restart **KOReader** if required
6. Open the book
7. Open the **Top Settings menu**
8. Go to **Search** (icon with magnifying glass)
9. Enter **Fast Dictionary Lookup** to configure the plugin

- **Enable Typewriter Cursor Mode**: Enables or disables hardware key word-by-word cursor navigation mode.
- **Enable Highlighting**: Enables text range selection mode when pressing **OK** on a word. If disabled, pressing **OK** directly opens the word definition or context menu.
- **Override Default Lookup Menu**: When enabled, pressing **OK** opens the full dictionary definition in a scrollable view instead of KOReader's native word context menu.
- **Enable Fast Dictionary Lookup**: Toggles the live preview widget showing word definitions or footnotes while moving the cursor.
- **Select dictionary**: Choose the active StarDict dictionary for word lookups.
- **Set as default dictionary**: Set the current dictionary as default across all books.

**Note**: Dictionaries are loaded from KOReader's standard dictionary folder: `koreader/data/dict/`

## ▶️ Usage

1. Use **Up/Down** arrow keys to enter **Typewriter Cursor Mode**
2. Move cursor with arrows and instantly see word definitions from your selected dictionary
3. Move cursor to the end/beginning of the page or press **Back** button to exit

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

- Use multiple dictionaries at the same time
- Load dictionary depending on book language
- Handle html/markdown data in dictionary
