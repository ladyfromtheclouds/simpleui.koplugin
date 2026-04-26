# Simple UI Bento Grid

A companion plugin for [Simple UI](https://github.com/doctorhetfield-cmd/simpleui.koplugin) that transforms the homescreen from full-width rows into a configurable bento grid. Multiple modules can share a row side-by-side.

## Installation

1. Copy the `simpleui_bento.koplugin` folder into your KOReader `plugins/` directory.
2. Restart KOReader (or go to **Settings → Plugins** and enable *Simple UI Bento Grid*).
3. Simple UI must already be installed and active.

## Usage

Each module that appears on the homescreen gains a new **Bento Grid Width** option in its settings menu (long-press the module to open it).

| Setting | Effect |
|---------|--------|
| 100% (default) | Module occupies the full row — identical to standard Simple UI |
| 50% | Module shares the row with another 50% module |
| 33% | Three modules fit side by side (use 35% + 35% + 30% for three columns) |
| 20–95% | Any other width; modules are packed left-to-right until the row is full |

### Example

Configure clock = 50%, reading stats = 50%, currently reading = 100%, recent = 50%, TBR = 50%:

```
┌──────────────────┬──────────────────┐
│  Clock (50%)     │  Stats (50%)     │
├──────────────────────────────────────┤
│     Currently Reading (100%)         │
├──────────────────┬──────────────────┤
│  Recent (50%)    │  TBR (50%)       │
└──────────────────┴──────────────────┘
```

## How it works

The plugin hooks `Homescreen.show()` to wrap the homescreen instance's `_updatePage()` method. After the original method runs (so all caches are warm), it rebuilds the portrait layout using `HorizontalGroup` rows for any modules configured below 100%. Modules are rebuilt at the correct column width — no widget re-parenting or dimension mutation.

Landscape mode is left untouched (Simple UI already uses a two-column layout there).

## Settings keys

Settings are stored in `G_reader_settings` with the prefix `simpleui_bento_width_`:

```
simpleui_bento_width_clock
simpleui_bento_width_quote
simpleui_bento_width_currently
simpleui_bento_width_recent
simpleui_bento_width_coverdeck
simpleui_bento_width_new_books
simpleui_bento_width_tbr
simpleui_bento_width_collections
simpleui_bento_width_reading_goals
simpleui_bento_width_reading_stats
simpleui_bento_width_quick_actions
```

Values are integers 20–100, snapped to multiples of 5. Default is 100.

## Compatibility

- **Simple UI**: 1.4.0 and later
- **KOReader**: any version that supports Simple UI
- **Appearance plugin**: fully compatible — background images are unaffected
- **Screen rotation**: portrait grid is applied only in portrait mode; landscape uses Simple UI's native two-column layout

## Troubleshooting

**Grid doesn't appear after changing a width**  
Long-press any module and tap **Refresh** (or close and reopen the homescreen). The layout updates automatically on the next full refresh.

**Modules overlap or look squished**  
Make sure the percentages of all modules intended for the same row add up to exactly 100 (e.g. 50 + 50, 33 + 33 + 34, 40 + 60). If they exceed 100 the overflow module starts a new row.

**Plugin disabled itself after an update**  
Simple UI module caches are cleared on version change. Re-enable the plugin from **Settings → Plugins**.

## License

Same as Simple UI — see the repository root `LICENSE` file.
