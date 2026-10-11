## Context

See proposal.md for the motivation.

- `widget.luau` fetches the Buienradar rain text (`HHMM|raw` lines in 5-minute steps, about 24 of them), turns it into `rain = { values, start, stop, note }` and publishes the whole snapshot to the plugin state. `values` are intensities scaled to 0..1 with `sqrt(mm/5)`.
- `panel.luau` is pure presentation. `rain_bars` renders one `ui.box` per value inside a `ui.row` (`gap = 2`, `flexGrow = 1` per bar); the labels below are a `space_between` row with `rain.start` and `rain.stop`.
- The panel is declared 380 px wide in `plugin.toml` with 16 px padding, so a bar is about 12 px wide. `plugin_api = 32` is already set, which includes `tooltip` on `ui.box`.
- Only plain data may travel through `noctalia.state`, and the panel runs in its own script context: it cannot call functions of the widget.
- There is no real Luau interpreter on the dev machine; `test/run.lua` runs both scripts under LuaJIT with a mocked runtime, and real behaviour (label clipping, tooltips) can only be seen in the live shell.

## Goals / Non-Goals

**Goals:**
- Tick marks and `HH:MM` labels at every :00 and :30, aligned to the bar that starts at that time, plus a `now` marker when there is room.
- A tooltip with time and mm/h on every bar.
- Keep the panel free of parsing and time arithmetic: everything it needs arrives in the state.
- Be robust to the number of bars varying (23 to 25) and to any start minute.

**Non-Goals:**
- No mm/h axis and no change of the bar height scale.
- No new settings, no new network requests, no localisation of the labels.
- No interval other than 30 minutes (not configurable).

## Decisions

### D1. A separate tick row built from cells weighted by bar count

Under the bars the panel renders a second `ui.row` (`gap = 0`) of cells. Every cell has `flexGrow` equal to the number of bars it covers: an optional leading cell (the bars before the first tick) and one cell per tick (from that tick to the next tick, or to the end of the chart). Inside a tick cell the content is left-aligned: a 1x4 px `ui.box` mark followed by the label.

Because cell widths are proportional to bar counts, a cell starts at `i / N` of the width, while bar `i` starts at `i * (W + gap) / N`. The difference is at most the 2 px bar gap, invisible next to a 12 px bar. No pixel arithmetic and no dependency on the panel width.

Alternatives considered:
- *Spacers with fixed pixel widths*: exact, but hard-codes the 380 px panel width and the padding in the script, which breaks silently when the manifest changes.
- *Grouping bars by half hour with a wider gap between groups*: gives a natural look, but the bars of a short first group get about 1.5 px wider than the others (inner gaps are not proportional to the weights), so the chart looks uneven.
- *Putting labels on the bars (overlay)*: the declarative UI has no documented absolute positioning or layering.

### D2. The widget computes ticks and tooltip texts; the panel decides how to show them

`parse_rain` already walks the times and raw values, so it additionally returns:
- `ticks`: a list of `{ index = <1-based bar index>, label = "HH:MM" }` for every bar whose minute is 00 or 30, in order;
- `tips`: one string per bar, such as `"15:25 - 0.2 mm/h"` or `"15:30 - dry"`.

mm/h is computed with the same formula as for `values` and the same 0.1 mm/h wet threshold that drives the summary note, so the tooltip and the note never disagree. `start` and `stop` stay in the state for the bar tooltip and the stale-state case, but are no longer rendered.

The panel owns the presentation rules, as named constants: the minimum of three bars for a `now` marker, and the minimum of three bars (counting the tick's own bar) for showing a label. A tick that fails the rule keeps its mark and loses its label. This keeps the layout rules where the layout is, and the widget free of UI concerns.

Alternative: the widget outputs ready-made cells (`{ span, label }`). Rejected because it would move the "does the text fit" decision, which depends on the panel width and font size, into the data layer.

### D3. Bar tooltips use `ui.box`'s `tooltip` prop

`plugin_api = 32` already covers it. The bar texts come from `tips[i]`, so the panel has no formatting logic.

### D4. Align the bar highlight threshold with the 0.1 mm/h wet threshold

The panel highlights a bar when its scaled value is above 0.12, which is about 0.07 mm/h, while the summary note and the new tooltip treat 0.1 mm/h as wet. With tooltips the mismatch becomes visible (a highlighted bar described as dry). The panel threshold becomes `sqrt(0.1 / 5)`, about 0.141, defined once next to the scaling constants with a comment pointing to the widget's wet threshold.

### D5. Backwards-compatible state

All new fields are optional. A panel that finds no `ticks` or `tips` (state published by an older widget script during a hot reload) renders the bars without scale and without tooltips instead of failing. Likewise a newer widget with an older panel simply has fields that nobody reads.

## Risks / Trade-offs

- [The behaviour of `ui.label` when it is wider than its cell is undocumented (clip, wrap or overflow)] -> The three-bar rule keeps a label inside a cell that is about 38 px wide for a text of about 26 px. Verify in the live panel with the fixture that has a tick at the very end, and tune the minimum if needed.
- [The panel may need more height: the footer row had about 12 px of slack at 530 px] -> The scale row replaces the start/stop row at about the same height; if the mark makes it taller, raise `height` in the manifest and re-enable the plugin (manifest changes are not hot-reloaded).
- [The tick-row alignment error of up to 2 px] -> Accepted, see D1.
- [The chart length is not fixed, the first step may be any 5-minute slot] -> Ticks are found by the minute value of each bar and cells are derived from indices, so no assumption about N or the start time is made. If Buienradar ever skipped a step the scale would still match the bars, only the time labels would then show the real times.
- [A previous snapshot lacks the new fields after a hot reload] -> See D5.
- [LuaJIT tests cannot show clipping or tooltip rendering] -> Tests assert the data and the structure of the tree; the visual check stays a manual step in the task list.

## Migration Plan

1. Change `widget.luau` and `panel.luau`; both hot-reload. Until the widget runs once more the old state lacks the new fields, which D5 handles; the panel also refreshes on the widget's next update or on the panel's refresh button.
2. If the panel height changes in `plugin.toml`: `noctalia msg plugins disable lazy/buienradar` then `enable`.
3. Rollback: revert the commit; no data or configuration is migrated.

## Open Questions

- The exact tick mark colour and label opacity (start with the existing muted colour `on_surface/0.6`); a purely visual choice to settle while looking at the live panel.
