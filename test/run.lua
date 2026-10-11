-- Offline smoke test for widget.luau and panel.luau.
--
-- Runs both entry scripts under LuaJIT with a mock of the Noctalia runtime and
-- real Buienradar samples (samples/feed.lua, samples/rain.txt).
--
--   luajit test/run.lua
--
-- It cannot catch Luau- or Noctalia-specific problems (real API behaviour,
-- unknown ui props); it checks the data handling and the shape of the output.

local function read(path)
  local f = assert(io.open(path, "rb"))
  local s = f:read("*a")
  f:close()
  return s
end

local failures = 0
local function check(cond, msg)
  if cond then
    print("ok    " .. msg)
  else
    failures = failures + 1
    print("FAIL  " .. msg)
  end
end

local feed = dofile("samples/feed.lua")
local rain_body = read("samples/rain.txt")

-- A fixed clock keeps the day/night decision deterministic.
local NOW = "15:10"

local function make_runtime(settings, rain_override)
  local rt = { state = {}, watchers = {}, requests = {}, bar = {}, logs = {} }

  rt.noctalia = {
    json = {
      decode = function(body)
        if body == "FEED" then return feed end
        return nil, "bad json"
      end,
    },
    http = function(req, cb)
      rt.requests[#rt.requests + 1] = req.url
      if req.url:find("data.buienradar.nl", 1, true) then
        cb({ ok = true, status = 200, body = "FEED" })
      else
        cb({ ok = true, status = 200, body = rain_override or rain_body })
      end
      return true
    end,
    state = {
      get = function(k) return rt.state[k] end,
      set = function(k, v)
        rt.state[k] = v
        for _, fn in ipairs(rt.watchers[k] or {}) do fn(v) end
      end,
      watch = function(k, fn)
        rt.watchers[k] = rt.watchers[k] or {}
        table.insert(rt.watchers[k], fn)
      end,
    },
    getConfig = function(k) return settings[k] end,
    formatTime = function(pattern)
      if pattern == "%H:%M" then return NOW end
      return "2026-10-10"
    end,
    log = function(m) rt.logs[#rt.logs + 1] = m end,
    setUpdateInterval = function(ms) rt.interval = ms end,
    togglePanel = function(id) rt.toggled = id end,
    nowMs = function() return 1234 end,
    runAsync = function(cmd) rt.ran = cmd return true end,
  }

  rt.barWidget = {
    setText = function(t) rt.bar.text = t end,
    setGlyph = function(g) rt.bar.glyph = g end,
    setTooltip = function(t) rt.bar.tooltip = t end,
  }

  return rt
end

local function load_entry(path, env)
  setmetatable(env, { __index = _G })
  local chunk = assert(loadfile(path))
  setfenv(chunk, env)
  chunk()
  return env
end

-- Builds a raintext body ("087|15:25\r\n...") in 5-minute steps from `start` ("HH:MM").
-- `raws` maps bar number -> raw value; every other bar is dry (0).
local function build_rain(start, count, raws)
  raws = raws or {}
  local h, m = start:match("(%d%d):(%d%d)")
  local minutes = tonumber(h) * 60 + tonumber(m)
  local lines = {}
  for i = 1, count do
    local t = minutes % (24 * 60)
    lines[#lines + 1] = string.format("%03d|%02d:%02d", raws[i] or 0, math.floor(t / 60), t % 60)
    minutes = minutes + 5
  end
  return table.concat(lines, "\r\n") .. "\r\n"
end

-- true when `v` only holds data that can travel through noctalia.state.
local function plain_data(v)
  local t = type(v)
  if t == "string" or t == "number" or t == "boolean" then return true end
  if t ~= "table" then return false end
  for _, x in pairs(v) do
    if not plain_data(x) then return false end
  end
  return true
end

-- Runs the widget once against `rain` (default: the fixture) and returns its runtime.
local function run_widget(rain)
  local r = make_runtime({ station_id = 0, latitude = 52.78, longitude = 6.90, refresh_minutes = 10 }, rain)
  local e = load_entry("widget.luau", { noctalia = r.noctalia, barWidget = r.barWidget })
  e.update()
  return r
end

local function find_text(node, needle, acc)
  acc = acc or {}
  if type(node) == "table" then
    if type(node.text) == "string" and node.text:find(needle, 1, true) then acc[#acc + 1] = node.text end
    for _, v in pairs(node) do
      if type(v) == "table" then find_text(v, needle, acc) end
    end
  end
  return acc
end

---------------------------------------------------------------------------
-- widget
---------------------------------------------------------------------------

local rt = make_runtime({ station_id = 0, latitude = 52.7792, longitude = 6.9006, refresh_minutes = 10 })
local env = load_entry("widget.luau", { noctalia = rt.noctalia, barWidget = rt.barWidget })

check(rt.bar.text == "--", "before the first fetch the bar shows a placeholder")

env.update()
check(rt.interval == 10 * 60 * 1000, "update interval is refresh_minutes in ms")
check(#rt.requests == 2, "one feed request and one rain request")
check(rt.requests[2] and rt.requests[2]:find("lat=52.78&lon=6.90", 1, true) ~= nil,
  "rain request uses two decimals (" .. tostring(rt.requests[2]) .. ")")

local d = rt.state.buienradar
check(type(d) == "table", "snapshot published to state")
check(d and d.station == "Hoogeveen", "nearest station to Emmen is Hoogeveen (got " .. tostring(d and d.station) .. ")")
check(d and d.temp_text == "11°", "temperature rounded (got " .. tostring(d and d.temp_text) .. ")")
check(d and d.glyph == "cloud-rain", "rain description maps to cloud-rain (got " .. tostring(d and d.glyph) .. ")")
check(d and d.wind_text == "W 4 Bft", "wind text (got " .. tostring(d and d.wind_text) .. ")")
check(d and #d.days == 5, "five forecast days")
check(d and d.days[5] and d.days[5].min_text == "9°", "min temperature '9/12' is parsed (got " .. tostring(d and d.days[5] and d.days[5].min_text) .. ")")
check(d and d.days[1] and d.days[1].label == "Sun", "2026-10-11 is a Sunday (got " .. tostring(d and d.days[1] and d.days[1].label) .. ")")
check(d and d.rain and #d.rain.values >= 20, "rain outlook parsed")
check(d and d.rain and d.rain.note:find("Rain", 1, true) ~= nil, "rain note (got " .. tostring(d and d.rain and d.rain.note) .. ")")
check(rt.bar.text == "11°" and rt.bar.glyph == "cloud-rain", "bar updated through the state watcher")
check(type(rt.bar.tooltip) == "table" and #rt.bar.tooltip >= 5, "tooltip has rows")

-- half-hour scale and bar tooltips (fixture: 15:10 .. 17:05, 24 bars)
local rain = d and d.rain
local function tick_summary(r)
  local out = {}
  for _, t in ipairs(r.ticks or {}) do out[#out + 1] = t.label .. "@" .. t.index end
  return table.concat(out, " ")
end
check(rain and tick_summary(rain) == "15:30@5 16:00@11 16:30@17 17:00@23",
  "ticks at every :00/:30 with their bar index (got " .. tostring(rain and tick_summary(rain)) .. ")")
check(rain and #rain.tips == #rain.values and #rain.values == 24, "one tooltip text per bar")
check(rain and rain.tips[1] == "15:10 - 2.5 mm/h", "wet bar tooltip (got " .. tostring(rain and rain.tips[1]) .. ")")
check(rain and rain.tips[4] == "15:25 - dry", "dry bar tooltip (got " .. tostring(rain and rain.tips[4]) .. ")")
check(rain and rain.tips[19] == "16:40 - 0.1 mm/h", "raw 77 is the 0.1 mm/h wet boundary (got " .. tostring(rain and rain.tips[19]) .. ")")
check(rain and rain.start == "15:10" and rain.stop == "17:05" and rain.note == "Rain until 15:25",
  "start, stop and note are unchanged (got " .. tostring(rain and rain.note) .. ")")
check(plain_data(rt.state.buienradar), "the published snapshot only holds plain data")

local edge = run_widget(build_rain("15:30", 3, { [1] = 76, [2] = 77 })).state.buienradar.rain
check(edge.tips[1] == "15:30 - dry" and edge.tips[2] == "15:35 - 0.1 mm/h", "raw 76 is dry, raw 77 is wet in the tooltip")
check(tick_summary(edge) == "15:30@1", "a tick on the very first bar")
local midnight = run_widget(build_rain("23:50", 6)).state.buienradar.rain
check(tick_summary(midnight) == "00:00@3", "the scale follows the clock across midnight (got " .. tick_summary(midnight) .. ")")

env.onClick()
check(rt.toggled == "lazy/buienradar:forecast", "click toggles the panel by its full id")

-- explicit station id wins over coordinates
local rt2 = make_runtime({ station_id = 6280, latitude = 52.78, longitude = 6.90, refresh_minutes = 10 })
local env2 = load_entry("widget.luau", { noctalia = rt2.noctalia, barWidget = rt2.barWidget })
env2.update()
check(rt2.state.buienradar and rt2.state.buienradar.station == "Groningen", "station_id overrides nearest lookup")

-- night turns the sun into a moon
NOW = "23:30"
local rt3 = make_runtime({ station_id = 6278, latitude = 52.78, longitude = 6.90, refresh_minutes = 10 })
local env3 = load_entry("widget.luau", { noctalia = rt3.noctalia, barWidget = rt3.barWidget })
env3.update()
check(rt3.state.buienradar and rt3.state.buienradar.glyph == "moon-stars", "clear sky at night shows moon-stars (got " .. tostring(rt3.state.buienradar and rt3.state.buienradar.glyph) .. ")")
NOW = "15:10"

-- network failure keeps the previous data and reports staleness
local rt4 = make_runtime({ station_id = 0, latitude = 52.78, longitude = 6.90, refresh_minutes = 10 })
local env4 = load_entry("widget.luau", { noctalia = rt4.noctalia, barWidget = rt4.barWidget })
env4.update()
rt4.noctalia.http = function(_, cb) cb({ ok = false, status = 500, body = "" }) return true end
env4.update()
check(rt4.bar.text == "11°", "failed refresh keeps the last temperature")
local stale = false
for _, row in ipairs(rt4.bar.tooltip) do if row.value:find("stale", 1, true) then stale = true end end
check(stale, "tooltip marks stale data")

---------------------------------------------------------------------------
-- panel
---------------------------------------------------------------------------

local ui = setmetatable({}, { __index = function(_, name)
  return function(props, children) return { kind = name, props = props, children = children, text = props and props.text } end
end })
-- flatten props so find_text can see label text
for _, name in ipairs({ "label", "button" }) do
  local orig = ui[name]
  ui[name] = function(props, children)
    local n = orig(props, children)
    n.text = props and props.text
    return n
  end
end

local rendered
local panel_api = { render = function(tree) rendered = tree end, close = function() rendered = "closed" end }
local penv = load_entry("panel.luau", { noctalia = rt.noctalia, ui = ui, panel = panel_api })

check(rendered == nil, "panel does not render while closed")
penv.onOpen({})
check(rendered ~= nil and rendered ~= "closed", "panel renders on open")
check(#find_text(rendered, "Station Hoogeveen") >= 1, "header names the weather station")
check(#find_text(rendered, "buienradar.nl") >= 1, "footer has the link to the site")
check(#find_text(rendered, "Rain") >= 1, "rain section is present")
check(#find_text(rendered, "Sun") >= 1 and #find_text(rendered, "Thu") >= 1, "forecast weekday labels are present")

penv.onCloseClicked()
check(rendered == "closed", "close button closes the panel")

rt.noctalia.getConfig = function(k) if k == "page_url" then return "https://example.test/emmen?a=1&b=2" end end
penv.onOpenSiteClicked()
check(type(rt.ran) == "table" and rt.ran[1] == "xdg-open" and rt.ran[2] == "https://example.test/emmen?a=1&b=2",
  "link button runs xdg-open with the configured URL as a separate argv entry")
rt.noctalia.getConfig = function(k) return nil end
penv.onOpenSiteClicked()
check(rt.ran[2] == "https://www.buienradar.nl", "link falls back to the default URL")

penv.onRefreshClicked()
check(rt.state["buienradar.refresh"] == 1234, "refresh button publishes a refresh request")
check(#rt.requests == 4, "widget refetches on a refresh request (requests: " .. #rt.requests .. ")")

---------------------------------------------------------------------------
-- rain scale, "now" marker and bar tooltips
---------------------------------------------------------------------------

local function open_panel(r)
  local tree
  local pe = load_entry("panel.luau", {
    noctalia = r.noctalia,
    ui = ui,
    panel = { render = function(t) tree = t end, close = function() end },
  })
  pe.onOpen({})
  return tree
end

-- The bars row is the row made only of boxes; the scale row is its next sibling.
local function find_chart(node)
  if type(node) ~= "table" or type(node.children) ~= "table" then return nil end
  for i, child in ipairs(node.children) do
    if type(child) == "table" and child.kind == "row" and type(child.children) == "table"
        and #child.children >= 3 then
      local all_boxes = true
      for _, c in ipairs(child.children) do
        if c.kind ~= "box" then all_boxes = false end
      end
      if all_boxes then return child, node.children[i + 1] end
    end
    local bars, scale = find_chart(child)
    if bars then return bars, scale end
  end
  return nil
end

-- "4:now 6:15:30 2:|" = cell weight, then its label; "|" mark only, "-" empty cell.
local function scale_summary(scale)
  local out, total = {}, 0
  for _, cell in ipairs(scale.children) do
    local weight = cell.props.flexGrow
    total = total + weight
    local what
    if cell.kind == "row" then
      what = "-"
    elseif cell.children[2] then
      what = cell.children[2].text
    else
      what = "|"
    end
    out[#out + 1] = weight .. ":" .. what
  end
  return table.concat(out, " "), total
end

local function count_exact(node, text, n)
  n = n or 0
  if type(node) ~= "table" then return n end
  if node.kind == "label" and node.text == text then n = n + 1 end
  for _, v in pairs(node) do
    if type(v) == "table" then n = count_exact(v, text, n) end
  end
  return n
end

local function show(summary) return tostring(summary) end

-- fixture: 15:10 .. 17:05, ticks 15:30@5 16:00@11 16:30@17 17:00@23
local tree = open_panel(rt)
local bars, scale = find_chart(tree)
check(bars ~= nil and scale ~= nil and #bars.children == 24, "panel has 24 bars and a scale row")
local summary, total = scale_summary(scale)
check(total == #bars.children, "scale cell weights sum to the number of bars (" .. total .. ")")
check(summary == "4:now 6:15:30 6:16:00 6:16:30 2:|",
  "start 15:10: 'now' shown, last tick (two bars left) is a mark without a label (got " .. show(summary) .. ")")
check(count_exact(tree, "15:10") == 0 and count_exact(tree, "17:05") == 0, "no separate start/end time labels")
local mark = scale.children[2].children[1]
check(mark.kind == "box" and mark.props.width == 1 and mark.props.height == 4, "tick mark is a 1x4 px box")
check(scale.children[2].props.align == "start", "tick cells are left-aligned")

-- start 15:25: one bar before the first tick, so no "now"; five bars left for 17:00
local late = open_panel(run_widget(build_rain("15:25", 24)))
local _, late_scale = find_chart(late)
local late_summary, late_total = scale_summary(late_scale)
check(late_summary == "1:- 6:15:30 6:16:00 6:16:30 5:17:00", "start 15:25: no 'now', 17:00 keeps its label (got " .. show(late_summary) .. ")")
check(late_total == 24 and count_exact(late, "now") == 0, "start 15:25: weights add up and no 'now' text")

-- start 15:35: the last bar is a tick (17:30); the label would be cut off
local tail = open_panel(run_widget(build_rain("15:35", 24)))
local _, tail_scale = find_chart(tail)
local tail_summary, tail_total = scale_summary(tail_scale)
check(tail_summary == "5:now 6:16:00 6:16:30 6:17:00 1:|", "tick on the last bar keeps its mark but not its label (got " .. show(tail_summary) .. ")")
check(tail_total == 24 and count_exact(tail, "17:30") == 0 and count_exact(tail, "17:00") == 1, "the previous tick keeps its label")
check(count_exact(tail, "15:30") == 0, "after a later refresh the passed 15:30 tick is gone")

-- summary scenarios and bar heights
local later = run_widget(build_rain("15:30", 24, { [7] = 100, [8] = 100 }))
check(later.state.buienradar.rain.note == "Rain from 16:00", "summary: rain starts later (got " .. tostring(later.state.buienradar.rain.note) .. ")")
check(run_widget(build_rain("15:30", 24)).state.buienradar.rain.note == "Dry for the next 2 hours", "summary: dry for 2 hours")
local later_bars = find_chart(open_panel(later))
check(later_bars.children[7].props.height > later_bars.children[1].props.height and later_bars.children[7].props.fill == "primary",
  "a bar with rain is taller and highlighted compared to a dry one")

-- no outlook: bars and scale are replaced by one line of text
local no_rain = run_widget()
no_rain.state.buienradar.rain = nil
local no_rain_tree = open_panel(no_rain)
check(count_exact(no_rain_tree, "Rain outlook unavailable") == 1 and find_chart(no_rain_tree) == nil,
  "without an outlook the panel says so and shows no bars")

-- the bar highlight matches the 0.1 mm/h wet threshold (raw 76 dry, raw 77 wet)
local edge_tree = open_panel(run_widget(build_rain("15:30", 3, { [1] = 76, [2] = 77 })))
local edge_bars = find_chart(edge_tree)
check(edge_bars.children[1].props.fill == "on_surface/0.2", "raw 76 is drawn as a dry bar")
check(edge_bars.children[2].props.fill == "primary", "raw 77 is drawn as a wet bar")

-- tooltips
local fixture_tips = rt.state.buienradar.rain.tips
local tips_ok = #bars.children == #fixture_tips
for i, bar in ipairs(bars.children) do
  if bar.props.tooltip ~= fixture_tips[i] then tips_ok = false end
end
check(tips_ok, "every bar carries its tooltip text")
check(bars.children[1].props.tooltip == "15:10 - 2.5 mm/h", "bar 1 tooltip (got " .. tostring(bars.children[1].props.tooltip) .. ")")

-- state from an older widget script: no ticks, no tips
local old = make_runtime({})
local function copy(v)
  if type(v) ~= "table" then return v end
  local c = {}
  for k, x in pairs(v) do c[k] = copy(x) end
  return c
end
old.state.buienradar = copy(rt.state.buienradar)
old.state.buienradar.rain.ticks = nil
old.state.buienradar.rain.tips = nil
local old_ok, old_tree = pcall(open_panel, old)
check(old_ok and old_tree ~= nil, "panel renders state without ticks and tips")
local old_bars, old_scale
if old_ok then old_bars, old_scale = find_chart(old_tree) end
check(old_bars ~= nil and old_scale == nil, "old state: bars without a scale row")
check(old_bars ~= nil and old_bars.children[1].props.tooltip == nil, "old state: bars without tooltips")

-- empty state
local rt5 = make_runtime({})
local rendered5
local penv5 = load_entry("panel.luau", { noctalia = rt5.noctalia, ui = ui, panel = { render = function(t) rendered5 = t end, close = function() end } })
penv5.onOpen({})
check(#find_text(rendered5, "Waiting") >= 1, "panel shows a waiting message without data")

print(failures == 0 and "\nall checks passed" or ("\n" .. failures .. " check(s) failed"))
os.exit(failures == 0 and 0 or 1)
