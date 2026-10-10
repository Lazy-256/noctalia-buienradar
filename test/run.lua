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

local function make_runtime(settings)
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
        cb({ ok = true, status = 200, body = rain_body })
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

-- empty state
local rt5 = make_runtime({})
local rendered5
local penv5 = load_entry("panel.luau", { noctalia = rt5.noctalia, ui = ui, panel = { render = function(t) rendered5 = t end, close = function() end } })
penv5.onOpen({})
check(#find_text(rendered5, "Waiting") >= 1, "panel shows a waiting message without data")

print(failures == 0 and "\nall checks passed" or ("\n" .. failures .. " check(s) failed"))
os.exit(failures == 0 and 0 or 1)
