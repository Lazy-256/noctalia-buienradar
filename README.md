# noctalia-buienradar

A [Noctalia](https://noctalia.dev) (v5) plugin that shows weather from
[Buienradar.nl](https://www.buienradar.nl): a bar widget with glyph and temperature, and a
forecast panel with current conditions, a 2-hour rain outlook and a 5-day forecast.

The rain outlook is a row of bars, one per 5 minutes, with a half-hour scale underneath
(a tick and an `HH:MM` label at every :00 and :30, and `now` at the left edge when there is room).
Hover a bar to see its time and intensity, e.g. `15:25 - 0.2 mm/h` (below 0.1 mm/h: `dry`).

- `plugin.toml` - manifest and settings
- `widget.luau` - bar widget; fetches the data and publishes it to plugin state
- `panel.luau` - forecast panel; renders the published state
- `translations/en.json` - labels for the settings UI
- `test/run.lua` - offline smoke test with a mocked Noctalia runtime (`luajit test/run.lua`)
- `samples/` - small trimmed snapshots of the Buienradar, geocoder and IP-service answers used by the test (see [Data and attribution](#data-and-attribution))

## Data and attribution

Weather data comes from [buienradar.nl](https://www.buienradar.nl). This is an unofficial plugin and is
not affiliated with or endorsed by Buienradar or RTL.

| What | URL | Status |
| --- | --- | --- |
| Station measurements + 5-day forecast | `https://data.buienradar.nl/2.0/feed/json` | Public feed with usage terms (below) |
| Rain outlook, 5-minute steps for ~2 h | `https://gpsgadget.buienradar.nl/data/raintext?lat=..&lon=..` | **Unofficial**: widely used by the community, but not documented or guaranteed by Buienradar; it may change or disappear |
| City name -> coordinates and GeoNames id | `https://geocoding-api.open-meteo.com/v1/search` | [Open-Meteo geocoding](https://open-meteo.com/en/docs/geocoding-api): free for non-commercial use; the data comes from [GeoNames](https://www.geonames.org) (CC BY 4.0) |
| IP address -> approximate place (only in `auto` mode) | `https://ipwho.is/` | Third-party service, no key; see [Location](#location) for the privacy note |

No API key is needed. The rain endpoint wants at most two decimals in `lat`/`lon`; more precision
answers with a redirect.

The feed carries this notice (translated): *"(C) Buienradar / RTL. All rights reserved. This feed may be
used freely, provided the source buienradar.nl is credited, including a hyperlink to
https://www.buienradar.nl."* The panel therefore names the source and links to the site
(`buienradar.nl` button). If you fork or redistribute this plugin, keep that credit and link.

`samples/feed.lua` is a small trimmed snapshot of the feed (5 stations, forecast only, with the
notice kept) that exists solely for the offline test, as are `samples/geocode.lua` (trimmed Open-Meteo/GeoNames
answers, CC BY 4.0) and `samples/ip.lua` (made-up values in the shape of an `ipwho.is` answer). The weather data
itself remains the property of its owners.

## Settings

Open them in the Noctalia settings under Plugins, or with `noctalia msg settings-open-plugin lazy/buienradar`.
Changes apply without a restart.

| Key | Default | |
| --- | --- | --- |
| `location_mode` | `city` | `city`, `auto` or `coordinates`; see [Location](#location). |
| `city` / `country` | `Emmen` / `NL` | City name (Dutch or English: `Den Haag` and `The Hague` both work) and an optional two-letter country code, `city` mode only. Empty country = search all countries. |
| `latitude` / `longitude` | Emmen (52.7792, 6.9006) | `coordinates` mode only. |
| `station_id` | `0` | Advanced. Buienradar station id (6279 = Hoogeveen). `0` = nearest to the place. |
| `page_query` | `radarType=rain&radarLocationVariant=NL&radarOffset=8H` | Added after the `?` of the link to the city page on buienradar.nl: which radar layer and time window the page opens with. Empty = plain city page. |
| `page_url` | empty | Advanced. A full address that replaces the built link. |
| `refresh_minutes` | `10` | Fetch interval. |
| `wind_unit` | `bft` | `bft` (Beaufort), `ms` (m/s, one decimal) or `kmh` (km/h, whole numbers). Applies to the bar tooltip and the panel. |
| `bar_text` (per bar widget) | `temperature` | `temperature` (`11°`), `temperature_feels` (`11° (8°)`) or `temperature_rain` (`11° ☂` when any 5-minute step of the next 2 hours has at least 0.1 mm/h, including right now). |

### Location

The panel shows which place the data is for and which weather station supplied the measurements
(with the distance when the station is more than 60 km away).

- **`city`** (default): the name is looked up with the Open-Meteo geocoder. The best match is used, so for
  ambiguous names add the country code; the region in the panel shows what was found.
  The link to buienradar.nl is built from the result: `https://www.buienradar.nl/weer/<city>/<country>/<GeoNames id>`.
- **`coordinates`**: the latitude and longitude as given; the link opens the buienradar.nl home page.
- **`auto`**: an approximate place from your IP address (one request to `ipwho.is`, repeated at most once an hour).
  **Off by default.** It sends your IP address to that service and is only as good as the IP database: for
  VPNs, company networks and some providers it points to a city far away (tested here: four different services
  all placed an IP 143 km from its real location). The panel shows what was detected, so you can tell.

If the place cannot be determined (unknown city, no network), the bar tooltip and the panel say why. The plugin
never falls back to other coordinates, and data fetched for a different place is not shown.

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
- The scale under the bars is a row of cells weighted by the number of bars they cover, so it needs no pixel
  maths; a tick label is only printed when at least three bars remain to the right edge (otherwise just the tick).
- Changes to `plugin.toml` (panel size, api level) are only picked up after
  `noctalia msg plugins disable lazy/buienradar && noctalia msg plugins enable lazy/buienradar`;
  `.luau` edits hot-reload.
- Runtime errors end up in `~/.cache/noctalia/noctalia.log` (look for `[ERR] [luau]`).

- Units and the bar text are applied when drawing, from raw numbers in the shared state, so changing them does not
  trigger a download. Widget-level settings (`bar_text`) are read with `noctalia.getConfig` inside the widget;
  `barWidget.getConfig` no longer exists at this API level.
- The `☂` in `temperature_rain` is a plain character (U+2602); it needs a font that has it (most do, e.g. DejaVu Sans).
- Conditions are shown in Buienradar's own Dutch wording; the glyph is chosen from keywords in that text.
- Day/night (sun vs. moon glyph) comes from the feed's sunrise/sunset, not from icon codes.
- Clicking the widget toggles the panel, right click refreshes.

## License

[MIT](LICENSE) for the plugin code. This does not cover Buienradar's data; see
[Data and attribution](#data-and-attribution).
