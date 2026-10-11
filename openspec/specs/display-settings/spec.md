# display-settings Specification

## Purpose

Lets the user choose how values are presented: what the bar widget prints next to the weather icon and in which unit the wind speed is given, with defaults that keep the plugin's original look.

## Requirements

### Requirement: Bar text mode
Each bar widget SHALL have a text mode setting with the choices `temperature` (default), `temperature and feels-like` and `temperature and rain`. Different bar widgets MAY use different modes. The temperature SHALL be printed rounded to whole degrees with a degree sign. Changing the mode SHALL change the bar text without waiting for a new download.

#### Scenario: Temperature only
- **WHEN** the mode is `temperature`, the temperature is 10.6 degrees
- **THEN** the bar text is "11°"

#### Scenario: Temperature with feels-like
- **WHEN** the mode is `temperature and feels-like`, the temperature is 10.6 degrees and the feels-like temperature is 7.6 degrees
- **THEN** the bar text is "11° (8°)"

#### Scenario: Feels-like unavailable
- **WHEN** the mode is `temperature and feels-like` and the station reports no feels-like temperature
- **THEN** the bar text is the temperature only

#### Scenario: Two bars, two modes
- **WHEN** one bar widget is set to `temperature` and another to `temperature and rain`
- **THEN** each shows its own text for the same data

### Requirement: Rain hint in the bar
In the `temperature and rain` mode the bar text SHALL be the temperature followed by a space and the symbol ☂ when rain is expected within the next 2 hours, that is when at least one step of the rain outlook, including the current one, has an intensity of at least 0.1 mm/h. Otherwise, and also when the rain outlook is unavailable, the bar text SHALL be the temperature only.

#### Scenario: Rain expected
- **WHEN** the mode is `temperature and rain`, the temperature is 11° and the outlook has a step of 0.3 mm/h at 16:10
- **THEN** the bar text is "11° ☂"

#### Scenario: Raining right now
- **WHEN** the mode is `temperature and rain` and only the current step has rain
- **THEN** the bar text includes ☂

#### Scenario: Dry outlook
- **WHEN** the mode is `temperature and rain` and every step is below 0.1 mm/h
- **THEN** the bar text is "11°" without the symbol

#### Scenario: Outlook unavailable
- **WHEN** the mode is `temperature and rain` and the rain outlook could not be fetched
- **THEN** the bar text is the temperature only

### Requirement: Wind unit
The plugin SHALL have a wind unit setting with the choices Beaufort (default), metres per second and kilometres per hour. The wind SHALL be written as the compass direction in English letters, a space, the value and the unit: `W 4 Bft`, `W 7.3 m/s`, `W 26 km/h`. Metres per second SHALL be shown with one decimal; kilometres per hour SHALL be rounded to a whole number, converted from metres per second with the factor 3.6. The unit SHALL apply wherever the wind is shown: the bar tooltip and the panel. When the wind is not reported, the value SHALL be shown as "-".

#### Scenario: Default unit
- **WHEN** the wind unit is not changed and the station reports force 4 from the west
- **THEN** the wind reads "W 4 Bft"

#### Scenario: Metres per second
- **WHEN** the unit is metres per second and the wind is 7.3 m/s from the west
- **THEN** the wind reads "W 7.3 m/s"

#### Scenario: Kilometres per hour
- **WHEN** the unit is kilometres per hour and the wind is 7.3 m/s from the west
- **THEN** the wind reads "W 26 km/h"

#### Scenario: Everywhere at once
- **WHEN** the user switches the unit to kilometres per hour
- **THEN** both the bar tooltip and the panel show the wind in kilometres per hour

#### Scenario: No wind data
- **WHEN** the station reports no wind
- **THEN** the wind reads "-"

### Requirement: Display settings apply instantly
Changing the bar text mode or the wind unit SHALL update what is shown without a new request to Buienradar.

#### Scenario: Switching the unit
- **WHEN** the user changes the wind unit and no refresh is due
- **THEN** the displayed wind changes unit and no network request is made
