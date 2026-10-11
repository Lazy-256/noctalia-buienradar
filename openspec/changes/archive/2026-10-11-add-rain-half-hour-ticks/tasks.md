## 1. Widget: data for the scale and tooltips

- [x] 1.1 In `parse_rain` (`widget.luau`) build `ticks`: a list of `{ index, label }` for every bar whose minute is 00 or 30. Verify with a `test/run.lua` check on `samples/rain.txt` (starts 15:10, 24 bars): ticks `15:30@5`, `16:00@11`, `16:30@17`, `17:00@23`.
- [x] 1.2 In `parse_rain` build `tips`: one `"HH:MM - X.X mm/h"` or `"HH:MM - dry"` string per bar, using the existing mm/h formula and the existing 0.1 mm/h wet threshold. Verify with tests: the first bar of `samples/rain.txt` reads `15:10 - 2.5 mm/h`, a dry bar reads `... - dry`, and a bar with raw value 77 reads `0.1 mm/h` while raw value 76 reads `dry`.
- [x] 1.3 Publish `ticks` and `tips` in `rain` next to the existing fields and keep `values`, `start`, `stop` and `note` unchanged. Verify with `luajit test/run.lua` that the existing rain checks (note text, value count) still pass and that the published state contains only plain data.

## 2. Panel: scale, marker and tooltips

- [x] 2.1 Replace the panel's bar highlight threshold (`v > 0.12`) with a named constant `sqrt(0.1 / 5)` and a comment that it matches the widget's wet threshold. Verify with a test that the bar of raw value 76 is rendered with the dry colour and raw value 77 with the highlight colour.
- [x] 2.2 Replace the `start`/`stop` label row in `rain_section` with the tick row: an optional leading cell plus one cell per tick, each with `flexGrow` equal to the number of bars it covers, holding a 1x4 px mark and a left-aligned label. Verify with a test that the cell weights sum to the number of bars and that no `start`/`stop` text is rendered.
- [x] 2.3 Apply the presentation rules as named constants: show `now` in the leading cell only when at least three bars precede the first tick; show a tick label only when at least three bars (the tick's own bar included) remain to the end. Verify with tests for the spec scenarios: start 15:10 shows `now`; start 15:25 shows no `now`; a tick at the second-to-last bar keeps its mark and loses its label; a tick with five bars left keeps its label.
- [x] 2.4 Give every bar the matching `tips[i]` as its `tooltip`. Verify with a test that the number of tooltips equals the number of bars and that bar 1 carries the text from task 1.2.
- [x] 2.5 Make the panel tolerate a `rain` table without `ticks` or `tips` (state from an older widget script): render the bars without scale and tooltips and without errors. Verify with a test that feeds the old state shape and still gets a rendered tree.

## 3. Test helpers

- [x] 3.1 Add a helper to `test/run.lua` that builds a rain body from a start time, a bar count and a list of raw values, and use it for the scenarios above (start 15:10 / 15:25 / 15:35, end 17:05 / 17:20, tick at the last bar). Verify that `luajit test/run.lua` reports every check as passed and that each spec scenario of `rain-outlook` is covered by at least one check.

## 4. Verification in the live shell and docs

- [x] 4.1 Reload the plugin, open the panel (`noctalia msg panel-open lazy/buienradar:forecast`) and take a screenshot with `grim`. Verify that the ticks and labels sit under the correct bars, that nothing is cut off or outside the panel, and that the footer row is still fully visible. If it is not, raise `height` in `plugin.toml` and re-enable the plugin (`noctalia msg plugins disable` / `enable lazy/buienradar`).
- [x] 4.2 Check the tail-of-chart case in the live panel at a time when the last tick falls on one of the final two bars (or by temporarily serving such data), and hover a bar. Verify that the last tick has a mark without a label and that the tooltip shows the expected text; if the user has to hover, report what is visible.
- [x] 4.3 Run `noctalia plugins lint .` and verify `0 errors, 0 warnings`; check the log (`rg '\[ERR\]' ~/.cache/noctalia/noctalia.log`) for no new Luau errors from `lazy/buienradar`.
- [x] 4.4 Update `README.md` so that the feature list mentions the half-hour scale and the bar tooltips, and check that no text still refers to start/end labels under the chart.
