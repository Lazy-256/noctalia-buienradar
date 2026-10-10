# noctalia-buienradar

A [Noctalia](https://noctalia.dev) (v5) plugin that shows weather from
[Buienradar.nl](https://www.buienradar.nl): a bar widget with glyph and temperature, and a
forecast panel with current conditions, a 2-hour rain outlook and a 5-day forecast.

- `plugin.toml` - manifest and settings
- `widget.luau` - bar widget; fetches the data and publishes it to plugin state
- `panel.luau` - forecast panel; renders the published state
- `translations/en.json` - labels for the settings UI
- `test/run.lua` - offline smoke test with a mocked Noctalia runtime (`luajit test/run.lua`)
- `samples/` - small trimmed Buienradar snapshots used by the test (see [Data and attribution](#data-and-attribution))

## Data and attribution

Weather data comes from [buienradar.nl](https://www.buienradar.nl). This is an unofficial plugin and is
not affiliated with or endorsed by Buienradar or RTL.

| What | URL | Status |
| --- | --- | --- |
| Station measurements + 5-day forecast | `https://data.buienradar.nl/2.0/feed/json` | Public feed with usage terms (below) |
| Rain outlook, 5-minute steps for ~2 h | `https://gpsgadget.buienradar.nl/data/raintext?lat=..&lon=..` | **Unofficial**: widely used by the community, but not documented or guaranteed by Buienradar; it may change or disappear |

No API key is needed. The rain endpoint wants at most two decimals in `lat`/`lon`; more precision
answers with a redirect.

The feed carries this notice (translated): *"(C) Buienradar / RTL. All rights reserved. This feed may be
used freely, provided the source buienradar.nl is credited, including a hyperlink to
https://www.buienradar.nl."* The panel therefore names the source and links to the site
(`buienradar.nl` button). If you fork or redistribute this plugin, keep that credit and link.

`samples/feed.lua` is a small trimmed snapshot of the feed (5 stations, forecast only, with the
notice kept) that exists solely for the offline test. The weather data itself remains the property of its
owners.

## Settings

| Key | Default | |
| --- | --- | --- |
| `station_id` | `0` | Buienradar station id (6279 = Hoogeveen). `0` = nearest to the coordinates. |
| `latitude` / `longitude` | Emmen (52.7792, 6.9006) | Used for the nearest station and the rain outlook. |
| `page_url` | Emmen page on buienradar.nl | Opened by the `buienradar.nl` link in the panel. |
| `refresh_minutes` | `10` | Fetch interval. |

## Install for development

Plugins live in `$XDG_DATA_HOME/noctalia/plugins/<plugin>/` (usually `~/.local/share/noctalia/plugins/`);
a local copy takes precedence over other sources. Symlinking the project keeps edits live
(`.luau` files hot-reload):

```bash
mkdir -p ~/.local/share/noctalia/plugins
ln -s "$PWD" ~/.local/share/noctalia/plugins/buienradar
noctalia msg plugins enable lazy/buienradar
```

Then add the widget to a bar from the widget picker (or set `type = "lazy/buienradar:weather"`).

Checks:

```bash
noctalia plugins lint .        # manifest vs. settings
luajit test/run.lua            # logic against real Buienradar samples
noctalia msg panel-toggle lazy/buienradar:forecast
```

## Notes

- `plugin_api = 32` (Noctalia 5.2.0+): with a lower level `ui.box` was nil inside the panel
  (`call to 'onOpen' failed ... attempt to call a nil value`), and `tooltip` on rows needs 32 anyway.
- The rain outlook is drawn with `ui.box` bars: `ui.graph` did not show the values as expected.
- Changes to `plugin.toml` (panel size, api level) are only picked up after
  `noctalia msg plugins disable lazy/buienradar && noctalia msg plugins enable lazy/buienradar`;
  `.luau` edits hot-reload.
- Runtime errors end up in `~/.cache/noctalia/noctalia.log` (look for `[ERR] [luau]`).

- Conditions are shown in Buienradar's own Dutch wording; the glyph is chosen from keywords in that text.
- Day/night (sun vs. moon glyph) comes from the feed's sunrise/sunset, not from icon codes.
- Clicking the widget toggles the panel, right click refreshes.

## License

[MIT](LICENSE) for the plugin code. This does not cover Buienradar's data; see
[Data and attribution](#data-and-attribution).
