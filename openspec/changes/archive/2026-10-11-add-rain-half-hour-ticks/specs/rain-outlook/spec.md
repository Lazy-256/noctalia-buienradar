## Purpose

Describes how the 2-hour rain outlook is shown in the forecast panel: a row of bars with a one-line summary, a half-hour time scale and per-bar details, so the reader can tell at a glance when rain starts and stops and how hard it falls.

## ADDED Requirements

### Requirement: Rain outlook bars
The panel SHALL show the rain outlook as one bar per 5-minute step, in chronological order from left to right, covering the period returned by Buienradar (about two hours). A bar's height SHALL increase with the rain intensity of its step, and every bar SHALL stay visible, even when it is dry.

#### Scenario: Outlook with rain
- **WHEN** Buienradar returns 24 five-minute steps and some of them have rain
- **THEN** the panel shows 24 bars, and the bars with rain are visibly taller and highlighted compared to the dry ones

#### Scenario: Outlook unavailable
- **WHEN** the rain outlook could not be fetched or parsed
- **THEN** the panel shows the text "Rain outlook unavailable" instead of bars and scale

### Requirement: Rain summary
The panel SHALL show a one-line summary above the bars. A step counts as wet when its intensity is at least 0.1 mm/h. The summary SHALL say that it stays dry for the next 2 hours, that rain falls until a given time, that rain falls for the next 2 hours, or that rain starts from a given time.

#### Scenario: Rain starts later
- **WHEN** the first wet step is 16:00 and the current step is dry
- **THEN** the summary reads "Rain from 16:00"

#### Scenario: Raining now
- **WHEN** the current step is wet and the first dry step is 15:30
- **THEN** the summary reads "Rain until 15:30"

### Requirement: Half-hour time scale
Under the bars the panel SHALL show a time scale with a tick mark and an `HH:MM` label at every full and half hour covered by the outlook. Each tick SHALL sit at the left edge of the bar whose step starts at that time, and its label SHALL start at that tick. The panel SHALL NOT show separate start and end time labels.

#### Scenario: Ticks follow the clock
- **WHEN** the outlook starts at 15:25 and ends at 17:20
- **THEN** ticks with labels 15:30, 16:00, 16:30 and 17:00 are shown, each under the bar of that time

#### Scenario: Ticks stay aligned after a refresh
- **WHEN** the outlook is refreshed ten minutes later and now starts at 15:35
- **THEN** the tick labels are still under the bars of exactly those times and the label 15:30 is no longer shown

### Requirement: Now marker
When at least three bars precede the first tick, the panel SHALL label the left edge of the chart `now`. Otherwise it SHALL NOT show a `now` label, so that it cannot overlap the first tick label.

#### Scenario: Room for the marker
- **WHEN** the outlook starts at 15:10 and the first tick is 15:30
- **THEN** four bars precede the tick and the label `now` is shown at the left edge

#### Scenario: No room for the marker
- **WHEN** the outlook starts at 15:25 and the first tick is 15:30
- **THEN** only one bar precedes the tick and no `now` label is shown

### Requirement: Labels never leave the panel
A tick near the right edge of the chart SHALL show its label only when at least three bars, counting the bar at the tick, remain up to the end of the chart. A tick with fewer bars SHALL be shown without a label. Labels SHALL NOT be cut off, wrapped or placed outside the panel.

#### Scenario: Tick at the very end
- **WHEN** the outlook ends at 17:05 and a tick belongs to 17:00, so only two bars remain
- **THEN** the tick mark at 17:00 is drawn without a label and the previous tick (16:30) keeps its label

#### Scenario: Enough room at the end
- **WHEN** the outlook ends at 17:20 and a tick belongs to 17:00, so five bars remain
- **THEN** the tick at 17:00 is drawn with its label

### Requirement: Bar tooltips
Hovering a bar SHALL show a tooltip with the bar's time and its rain intensity in mm/h with one decimal, for example `15:25 - 0.2 mm/h`. A step with an intensity below 0.1 mm/h SHALL be described as dry, for example `15:30 - dry`.

#### Scenario: Wet step
- **WHEN** the user hovers the bar of the 15:25 step with an intensity of 0.2 mm/h
- **THEN** the tooltip reads "15:25 - 0.2 mm/h"

#### Scenario: Dry step
- **WHEN** the user hovers the bar of a step whose intensity is 0
- **THEN** the tooltip reads "15:30 - dry"
