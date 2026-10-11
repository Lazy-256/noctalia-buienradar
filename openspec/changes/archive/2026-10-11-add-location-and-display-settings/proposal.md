## Why

The plugin is hard-wired to one place: the coordinates in the settings default to Emmen, and the link to the Buienradar page is a full URL that has to be copied by hand. Changing the city means finding coordinates and a new URL, and nothing shows which place the data is actually for. Detecting the place from the IP address looks like the obvious alternative, but for this setup every IP geolocation service puts the user in Amsterdam (143 km from the real location), so it can only be an explicit opt-in, never the default.

The bar text and the wind speed are also fixed: temperature only, wind always in Beaufort. Some people want the feels-like temperature or a rain hint in the bar, and wind in m/s or km/h.

## What Changes

- Add a location mode setting with three choices: `city` (default, "Emmen"), `auto` (from the IP address, off by default) and `coordinates` (latitude/longitude as today).
- In `city` mode the place is resolved from a city name and an optional country code with the Open-Meteo geocoder; the station choice, the 2-hour rain outlook and the link to buienradar.nl all follow the resolved place.
- In `auto` mode the place is resolved from the IP address with an external lookup, then snapped to a named city; it is only used when the user explicitly selects it, and the IP lookup is never made otherwise.
- The panel shows which place the data is for (name and region) next to the station, and says so when the nearest station is far away.
- A failed lookup (unknown city, no network) is reported and never replaced silently by other coordinates.
- The link to buienradar.nl is built from the resolved city; the radar parameters after the `?` become their own setting with the current value as default; the full-URL setting stays as an optional override.
- Add a bar text setting: temperature only (default), temperature with feels-like, or temperature with a ☂ when rain is expected within the next 2 hours.
- Add a wind unit setting: Beaufort (default), m/s or km/h, applied in the bar tooltip and in the panel.
- The widget keeps raw numbers in the shared state and formats them when it draws, so changing a unit or the bar text takes effect without a new download.

## Capabilities

### New Capabilities
- `location`: which place the weather is for: the three location modes, how a place is resolved and shown, how the weather station is chosen, how failures are reported and how the link to buienradar.nl is built.
- `display-settings`: how values are presented according to user settings: the bar text modes (including the rain hint) and the wind unit.

### Modified Capabilities

None. The existing `rain-outlook` requirements do not change; the rain hint in the bar only reuses its definition of a wet step.

## Impact

- `plugin.toml`: new settings (`location_mode`, `city`, `country`, `page_query`, `wind_unit`, widget-level `bar_text`) with conditional visibility; `page_url` default becomes empty; `latitude`/`longitude` are shown only in `coordinates` mode.
- `translations/en.json`: labels and descriptions for the new settings, including a privacy note for `auto`.
- `widget.luau`: place resolution (geocoder, IP lookup, caching in the shared state), place and distance in the snapshot, raw numbers next to the formatted text, bar text modes.
- `panel.luau`: place line, far-station note, wind formatting by unit, link built from the resolved place.
- `test/run.lua` and `samples/`: fixtures for geocoder and IP responses, tests for modes, failures, link building, wind units and bar text.
- `README.md`: new settings, privacy notes for the IP mode, attribution for the geocoder data (Open-Meteo, GeoNames).
- New network calls: `geocoding-api.open-meteo.com` (city modes) and one IP lookup service (only in `auto` mode). No new dependencies and no breaking changes for the current configuration: the defaults reproduce today's behaviour (Emmen, temperature only, Beaufort).
