## Context

See proposal.md for the motivation and the specs for the observable behaviour.

- `widget.luau` fetches the Buienradar feed and the rain outlook every `refresh_minutes`, picks the station (`station_id`, or the nearest one to `latitude`/`longitude`), formats everything into strings (`temp_text`, `feels_text`, `wind_text`, ...) and publishes one snapshot to `noctalia.state`. `panel.luau` only renders that snapshot; it builds its link from the `page_url` setting.
- Facts from the documentation that the design relies on: plugin settings are declared in `plugin.toml` (`select` with `options`, `visible_when`, `advanced`, entry-level `[[widget.setting]]`); widgets and panels are rebuilt when a setting changes and then read the new `noctalia.getConfig` values; `noctalia.state` lives as long as the process, is plain data only and is shared by the entries of one plugin; the manifest is only re-read after disable/enable.
- Measured facts: all four IP geolocation services that were tried put the user's IP in Amsterdam, 143 km from Emmen. The Open-Meteo geocoder returns an `id` that is the GeoNames id used in `buienradar.nl/weer/<name>/<cc>/<id>`; the name in that path does not matter to the site. With `language=en` the query "Den Haag" finds a place in South Africa, with `language=nl` both "Den Haag" and "The Hague" find the Dutch city; an empty `countryCode=` parameter returns no results; the rain endpoint wants two decimals.
- There is no real Luau here; `test/run.lua` runs the entries under LuaJIT with a mocked runtime. Entries are separate scripts; sharing code between them is not known to work.

## Goals / Non-Goals

**Goals:**
- One place-resolution path for all three modes that ends in the same `place` record, so everything downstream (station, rain outlook, link, labels) has one input.
- Never show weather for a place other than the configured one.
- Display settings apply instantly: formatting happens at draw time from raw numbers.
- Defaults reproduce today's behaviour exactly.

**Non-Goals:**
- No localisation of the plugin (an `ru.json` is a separate piece of work), no new units for temperature, no gusts.
- No persistent cache on disk: resolving again after a restart is one cheap request.
- No retry/backoff beyond "try again at the next refresh".
- No attempt to improve the accuracy of IP geolocation.

## Decisions

### D1. One `place` record, resolved once and cached in the state

All modes produce `place = { name, region, cc, lat, lon, geoid, label, source }` (`geoid` and `region` may be absent):

```
 location_mode
      |
      +-- city ---------> geocode(city, country) ---------+
      |                                                    |
      +-- auto ---------> ip lookup -> city,cc,lat,lon     |
      |                       |  has city?                 +--> place --> station
      |                       +-- yes --> geocode(city,cc)-+          +-> rain outlook (lat,lon)
      |                       +-- no / not found: use the |          +-> label in the panel
      |                           IP coordinates          |          +-> link (geoid)
      +-- coordinates --> lat/lon from settings ----------+
```

The result is cached in the state under `buienradar.place` as `{ sig, place, at }`, where `sig` is a string made of the mode and the settings that matter for it (`city|Emmen|NL`, `coords|52.78|6.91`, `auto`). A cached place is reused while `sig` matches; `city` and `coordinates` entries never expire, an `auto` entry expires after one hour (the laptop may have moved). Every widget instance resolves on its own at start (one request per monitor at worst); a shared "in flight" marker is possible later and is not worth the complexity now.

Alternative: resolve in a `[[service]]` entry. Rejected: widgets are rebuilt on every setting change anyway, services have different start rules (`onEnable` does not run at normal startup) and a rebuilt widget is the simplest trigger for "settings changed, resolve again".

### D2. Geocoder request

`https://geocoding-api.open-meteo.com/v1/search?name=<urlEncode(city)>&count=1&language=nl&format=json` plus `&countryCode=<CC>` only when the country setting is not empty (an empty parameter yields no results). `language=nl` because it accepts Dutch and English names and returns Dutch names, matching the Dutch Buienradar site; `count=1` because the best match is what a user means and the region in the label makes a wrong guess visible. The answer without a `results` key means "not found" and becomes the reported error.

### D3. IP lookup for `auto`

One hard-coded HTTPS provider without a key, `https://ipwho.is/`, which returns city, country code and coordinates. Its city and country are fed back into D2 so that the id, the region and the Dutch name come from the same source as in `city` mode; when the city is missing or the geocoder does not know it, the IP's own coordinates are used and the label is the coordinates. The lookup is only made in `auto` mode and at most once an hour.

Alternatives: `ipapi.co` (fastest in the test, but a rate limit that is easy to hit with several monitors), `ipinfo.io` (needs a token for volume), `geojs.io` (no city name). All four returned the same wrong answer for this user, which is a property of the IP address, so the choice is not critical and can be changed by editing one constant.

### D4. Raw numbers in the snapshot, formatting when drawing

The snapshot keeps the existing text fields and adds `temp`, `feels`, `wind_dir`, `wind_bft`, `wind_ms`, `rain_expected` (any step of the outlook at or above the wet threshold), `place`, `station_km` and `sig`. The widget (bar text, tooltip) and the panel (wind figure, header) format from the raw fields with the current settings, so a changed unit or bar text only needs a redraw: the rebuilt widget redraws from the cached snapshot at once. When a raw field is missing (a snapshot published by an older script during a hot reload) the old text field is used instead.

The few formatting functions (rounded degrees, wind text) are needed by both entries and are duplicated; a test table feeds the same cases to both so they cannot drift apart.

Alternative: format once at fetch time and refetch when a unit changes. Rejected: slower, wasteful and makes "apply instantly" impossible when offline.

### D5. Data for another place is never shown

The widget publishes the signature it is currently configured for in `buienradar.sig`; a snapshot carries the `sig` it was built for. The bar widget and the panel draw a snapshot only when its `sig` equals the current one, otherwise they behave as if there were no data (placeholder, "waiting"). A failed refresh for the same `sig` keeps the old snapshot and marks it stale; the error text goes to `buienradar.error` so that the panel can show it as well as the tooltip.

### D6. Link built by the panel when it is clicked

The panel assembles the link at click time from `place` (`name`, `cc`, `geoid`) and the `page_query` / `page_url` settings, so a changed setting needs no refetch and no stored link can be stale. Order: a non-empty `page_url` wins; no `geoid` means `https://www.buienradar.nl`; otherwise the built link with `?<page_query>` when the query is not empty. The name is slugged by lower-casing and replacing every run of characters other than ASCII letters and digits with one hyphen, then trimming hyphens.

### D7. Station and distance

`find_station` is unchanged; it additionally returns the distance in km (the same flat approximation that already picks the nearest station). With an explicit `station_id` the distance is computed too. The panel shows the distance when it exceeds `FAR_STATION_KM = 60`, a constant of the panel.

### D8. Settings in the manifest

| Key | Scope | Type | Default | Notes |
| --- | --- | --- | --- | --- |
| `location_mode` | plugin | select `city`/`auto`/`coordinates` | `city` | description carries the privacy note for `auto` |
| `city` | plugin | string | `Emmen` | `visible_when location_mode = city` |
| `country` | plugin | string | `NL` | same visibility; empty = any country |
| `latitude`, `longitude` | plugin | double | as today | `visible_when location_mode = coordinates` |
| `station_id` | plugin | int | `0` | now `advanced` |
| `page_query` | plugin | string | `radarType=rain&radarLocationVariant=NL&radarOffset=8H` | |
| `page_url` | plugin | string | empty (was the Emmen URL) | `advanced`; overrides the built link |
| `refresh_minutes` | plugin | int | `10` | unchanged |
| `wind_unit` | plugin | select `bft`/`ms`/`kmh` | `bft` | |
| `bar_text` | widget | select `temperature`/`temperature_feels`/`temperature_rain` | `temperature` | read with `noctalia.getConfig` (inside a widget it returns that widget's own value; `barWidget.getConfig` is removed at this API level, which `noctalia plugins lint` reported) |

Existing keys keep their names, so a saved configuration stays valid. The only default that changes is `page_url`: an unchanged default now means "built link", which for Emmen is the same address as before; a customised value is kept and still wins. Every label, description and option needs a key in `translations/en.json`.

### D9. The rain hint is a text symbol

`temperature_rain` appends the character U+2602 to the text. It exists in 30 installed fonts here (e.g. DejaVu Sans), so fallback fonts will find it. If it ever shows as a missing-glyph box on another system, the fallback is `barWidget.render` with the bundled Tabler `umbrella` glyph; that switch is deferred because `render` disables `setText`/`setGlyph` and its effect on the tooltip has not been checked.

## Risks / Trade-offs

- [A setting change might not rebuild the widget as documented] -> Verify first in the live shell (change the city, watch for the new data) before building on it; if not, add a cheap poll of a settings signature in `update()` with a short interval.
- [The geocoder returns the wrong "best" match for an ambiguous name] -> The label shows name and region and the country field can narrow it; documented in the settings text.
- [Dutch names for foreign places ("Londen")] -> Acceptable for a Dutch weather site; the link slug does not matter to Buienradar.
- [Geocoder or IP service down, rate-limited or changed] -> Reported through the failure path (D5); the geocoder data licence (GeoNames, CC BY 4.0) and Open-Meteo's non-commercial terms are noted in the README next to the Buienradar attribution.
- [`auto` is useless for some networks (VPN, hosting blocks)] -> It is opt-in, shows the place it found and the settings text says it is approximate.
- [Several monitors resolve the place several times] -> At most one request per widget instance at start; accepted.
- [The two copies of the formatting functions drift apart] -> One shared table of cases tests both (D4).
- [A far station gives plausible but irrelevant measurements for a foreign city] -> The distance note in the panel (D7).

## Migration Plan

1. Implement behind unchanged defaults: with no saved settings the plugin resolves "Emmen / NL" and looks as before, apart from the new place line.
2. The manifest change needs `noctalia msg plugins disable lazy/buienradar` and `enable`; `.luau` edits hot-reload.
3. Rollback: revert the commit; no stored data or configuration is migrated, saved values of existing keys stay valid.

## Open Questions

- Whether a sibling script can be loaded with `require` in a plugin script; if it can, the duplicated formatting functions move into one module (a refactor that changes no behaviour).
- Whether the feels-like text `11° (8°)` looks good in the bar; a purely visual choice to settle in the live bar.
