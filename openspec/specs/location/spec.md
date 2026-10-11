# location Specification

## Purpose

Defines which place the weather is for and how that place is chosen, resolved, shown and checked, so the user can switch to another city without looking up coordinates, always sees where the data comes from, and is never shown another place's weather by accident.

## Requirements

### Requirement: Location mode
The plugin SHALL offer a location mode setting with the choices `city`, `auto` and `coordinates`. The default SHALL be `city` with the city "Emmen" and the country code "NL". The settings of the other modes SHALL be hidden while a mode is not selected: `city` and `country` in `city` mode, `latitude` and `longitude` in `coordinates` mode. Changing a location setting SHALL take effect without restarting the shell or reinstalling the plugin.

#### Scenario: Fresh installation
- **WHEN** the plugin is enabled with default settings
- **THEN** the weather is shown for Emmen (Drenthe, NL)

#### Scenario: Settings follow the mode
- **WHEN** the user selects the `coordinates` mode in the plugin settings
- **THEN** the latitude and longitude fields are shown and the city and country fields are hidden

#### Scenario: Changing the city
- **WHEN** the user changes the city from "Emmen" to "Groningen"
- **THEN** within moments the bar, the panel and the rain outlook show data for Groningen, without a restart

### Requirement: City resolution
In `city` mode the plugin SHALL resolve the city name, together with the optional country code, to a place with a name, a region, a country, coordinates and a GeoNames identifier. When several places match, the best match SHALL be used. The name SHALL be accepted in Dutch or English. When the country code is empty, no country restriction SHALL be applied. When no place matches (unknown city or a country code that does not exist), the plugin SHALL report that the city was not found.

#### Scenario: City with country
- **WHEN** the city is "Emmen" and the country code is "NL"
- **THEN** the place is Emmen in Drenthe at about 52.78 N, 6.91 E

#### Scenario: Dutch and English names
- **WHEN** the city is "The Hague" or "Den Haag" and the country code is "NL"
- **THEN** both resolve to the same place, Den Haag in Zuid-Holland

#### Scenario: Country code left empty
- **WHEN** the city is "Groningen" and the country code is empty
- **THEN** the search covers all countries and the best match is used

#### Scenario: Unknown city
- **WHEN** the city is "Emmmen" and the country code is "NL"
- **THEN** the plugin reports that the city was not found and does not guess another place

### Requirement: Automatic location is an explicit opt-in
The `auto` mode SHALL NOT be the default. In any other mode the plugin SHALL NOT contact an IP geolocation service. In `auto` mode the plugin SHALL determine an approximate place from the IP address with one external lookup, and SHALL use the city that the lookup reports, resolved like a city in `city` mode, falling back to the coordinates from the lookup when no city is reported. The setting's description SHALL say that the IP address is sent to an external service and that the result is approximate. In `auto` mode the place SHALL be determined again at least once an hour, so that a laptop that moves follows its location.

#### Scenario: Default configuration makes no IP lookup
- **WHEN** the plugin runs with default settings for a full refresh period
- **THEN** no request to an IP geolocation service is made

#### Scenario: Automatic mode selected
- **WHEN** the user selects `auto` and the lookup reports the city Amsterdam
- **THEN** the place is Amsterdam and the panel shows it, so the user can see what was detected

#### Scenario: Lookup reports only coordinates
- **WHEN** the lookup returns coordinates but no city
- **THEN** the place is shown by its coordinates, for example "52.38, 4.90", and the weather is for those coordinates

#### Scenario: Privacy note
- **WHEN** the user looks at the location mode setting
- **THEN** its description states that choosing `auto` sends the IP address to an external service

### Requirement: Coordinates mode
In `coordinates` mode the plugin SHALL use the latitude and longitude from the settings as they are, and SHALL show the place by its coordinates.

#### Scenario: Manual coordinates
- **WHEN** the mode is `coordinates` with latitude 52.78 and longitude 6.91
- **THEN** the weather and the rain outlook are for 52.78 N, 6.91 E and the place is shown as "52.78, 6.91"

### Requirement: The place and the station are shown
The panel SHALL show the name of the place that the data is for (name and region when known) and the name of the weather station that supplied the measurements. When the station is more than 60 km away from the place, the panel SHALL state its distance.

#### Scenario: Station near the place
- **WHEN** the place is Emmen and the nearest station is Hoogeveen, 26 km away
- **THEN** the panel shows "Emmen, Drenthe" and the station "Hoogeveen", without a distance

#### Scenario: Station far from the place
- **WHEN** the place is Berlin and the nearest station reporting a temperature is 520 km away
- **THEN** the panel shows that station together with its distance, "520 km"

### Requirement: Weather station choice
When the station setting is 0 the plugin SHALL use the nearest station that reports a temperature. When it holds a station number, that station SHALL be used instead, regardless of the place.

#### Scenario: Nearest station
- **WHEN** the station setting is 0 and the place is Emmen
- **THEN** the measurements come from the nearest station that reports a temperature, Hoogeveen

#### Scenario: Explicit station
- **WHEN** the station setting is the number of the Groningen station
- **THEN** the measurements come from Groningen, whatever place is selected

### Requirement: Rain outlook follows the place
The 2-hour rain outlook SHALL be for the resolved place, whatever mode is used.

#### Scenario: Another city
- **WHEN** the city is "Groningen"
- **THEN** the rain outlook is requested for the coordinates of Groningen (about 53.22 N, 6.57 E)

### Requirement: Failed lookups are reported, never replaced
When the place cannot be determined (unknown city, no network, service error), the plugin SHALL tell the user why in the bar tooltip and in the panel, and SHALL retry at the next refresh. It SHALL NOT silently use other coordinates. Data for the same place that was fetched earlier SHALL stay visible and be marked as stale. Data that was fetched for a different place SHALL NOT be shown.

#### Scenario: Network failure for the same place
- **WHEN** weather for Emmen was shown and a later refresh fails because the network is down
- **THEN** the Emmen data stays visible, marked stale, and the tooltip names the failure

#### Scenario: New city cannot be found
- **WHEN** weather for Emmen was shown and the user changes the city to "Emmmen"
- **THEN** the bar shows a placeholder instead of the Emmen weather and the tooltip says that the city "Emmmen" was not found

#### Scenario: No data yet
- **WHEN** the place cannot be determined at the first refresh
- **THEN** the bar shows a placeholder and the tooltip names the reason

### Requirement: Link to buienradar.nl
The panel SHALL link to the Buienradar page of the resolved city, built as `https://www.buienradar.nl/weer/<name>/<country>/<id>`, where `<name>` is the city name in lower case with every run of characters other than letters and digits replaced by one hyphen and trimmed at both ends, `<country>` is the lower case country code and `<id>` is the GeoNames identifier. When the link parameters setting is not empty it SHALL be appended after a `?`. Its default SHALL be `radarType=rain&radarLocationVariant=NL&radarOffset=8H`. When the full-URL setting is not empty it SHALL be used instead of the built link. When the place has no GeoNames identifier (the `coordinates` mode, or an `auto` result without a city), the link SHALL point to `https://www.buienradar.nl`.

#### Scenario: Default link for Emmen
- **WHEN** the place is Emmen (NL, identifier 2756136) with default settings
- **THEN** the link is `https://www.buienradar.nl/weer/emmen/nl/2756136?radarType=rain&radarLocationVariant=NL&radarOffset=8H`

#### Scenario: Name with an apostrophe
- **WHEN** the place is 's-Hertogenbosch (NL, identifier 2747351)
- **THEN** the link path is `/weer/s-hertogenbosch/nl/2747351`

#### Scenario: Link parameters cleared
- **WHEN** the link parameters setting is emptied
- **THEN** the link is the plain page of the city, without a `?`

#### Scenario: Full URL given
- **WHEN** the full-URL setting is set to an address
- **THEN** that address is opened, whatever the place and the link parameters are

#### Scenario: No city
- **WHEN** the mode is `coordinates` and the full-URL setting is empty
- **THEN** the link opens `https://www.buienradar.nl`
