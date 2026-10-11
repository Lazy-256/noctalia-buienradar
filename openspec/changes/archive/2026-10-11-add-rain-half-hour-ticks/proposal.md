## Why

The rain outlook in the forecast panel is a row of 24 bars (one per 5 minutes) with only the start and end time printed underneath. Nothing tells the reader when a shower arrives: to find out whether the rain starts at 16:00 or 16:20 they have to count bars. A half-hour scale makes the chart readable at a glance. The bars also carry no scale in mm/h, so the exact intensity of a bar cannot be read at all.

## What Changes

- Replace the start/end labels under the rain bars with a half-hour scale: a short tick mark and a `HH:MM` label at every `:00` and `:30`, aligned to the bar that starts at that time.
- Label the left edge `now` when the first tick is at least three bars away from the left edge. Remove the start/end labels.
- Skip the label (not the bar) of a tick that has fewer than three bars between it and the right edge, so the text is never cut off or pushed outside the panel.
- Add a hover tooltip to every bar with its time and rain intensity, for example `15:25 - 0.2 mm/h`.
- The widget publishes the tick positions and per-bar tooltip text in the shared plugin state next to the existing rain values; the panel stays pure presentation.

## Capabilities

### New Capabilities
- `rain-outlook`: how the 2-hour rain outlook is presented in the forecast panel: the bars, the half-hour time scale, the `now` marker, the summary note and the per-bar tooltips.

### Modified Capabilities

None. The project has no specs yet (`openspec/specs/` is empty); the existing rain bars and note are captured as part of the new capability.

## Impact

- `widget.luau`: `parse_rain` additionally returns the tick list and per-bar tooltip text.
- `panel.luau`: `rain_section` / `rain_bars` render the tick row and bar tooltips; the `start`/`stop` labels go away.
- `test/run.lua`: new checks for tick positions, the `now` marker, the skipped last label and the tooltip text.
- `samples/rain.txt`: may need an extra fixture to cover a tick at the very end of the chart.
- `plugin.toml`: the panel height (`530`) may need a few pixels more; manifest changes only apply after disabling and re-enabling the plugin.
- No new settings, dependencies, network requests or breaking changes. The shared state gains optional fields; an older panel script ignores them.
