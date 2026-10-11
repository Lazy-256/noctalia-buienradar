-- Offline smoke test for widget.luau and panel.luau.
--
-- Runs both entry scripts under LuaJIT with a mock of the Noctalia runtime and
-- real samples (samples/feed.lua, samples/rain.txt, samples/geocode.lua, samples/ip.lua).
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
local geocode = dofile("samples/geocode.lua")
local ip_answers = dofile("samples/ip.lua")

-- A fixed clock keeps the day/night decision deterministic.
local NOW = "15:10"

local function url_encode(str)
  return (tostring(str):gsub("[^%w%-_.~]", function(c) return string.format("%%%02X", c:byte()) end))
end

local function url_decode(str)
  return (str:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end))
end

-- `settings` is what noctalia.getConfig returns (tests may change it to
-- simulate a changed setting); `rain_override` replaces the rain outlook body.
local function make_runtime(settings, rain_override)
  local rt = {
    settings = settings, state = {}, watchers = {}, requests = {}, hosts = {}, bar = {}, logs = {},
    now = 10 * 3600 * 1000, ip = "amsterdam", failing = {},
  }

  local function respond(host, url)
    if rt.failing[host] then return { ok = false, status = 500, body = "" } end
    if host == "data.buienradar.nl" then return { ok = true, status = 200, body = "FEED" } end
    if host == "gpsgadget.buienradar.nl" then return { ok = true, status = 200, body = rain_override or rain_body } end
    if host == "geocoding-api.open-meteo.com" then
      local name = url_decode(url:match("[?&]name=([^&]*)") or "")
      local cc = url_decode(url:match("[?&]countryCode=([^&]*)") or "")
      return { ok = true, status = 200, body = "GEO:" .. name:lower() .. "|" .. cc:upper() }
    end
    if host == "ipwho.is" then return { ok = true, status = 200, body = "IP:" .. rt.ip } end
    return { ok = false, status = 404, body = "" }
  end

  rt.noctalia = {
    json = {
      decode = function(body)
        if body == "FEED" then return feed end
        local key = body:match("^GEO:(.*)$")
        if key then return geocode[key] or { generationtime_ms = 0.1 } end
        key = body:match("^IP:(.*)$")
        if key then return ip_answers[key] end
        return nil, "bad json"
      end,
    },
    string = { urlEncode = url_encode },
    http = function(req, cb)
      local host = req.url:match("^https?://([^/?]+)")
      rt.requests[#rt.requests + 1] = req.url
      rt.hosts[host] = (rt.hosts[host] or 0) + 1
      cb(respond(host, req.url))
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
    nowMs = function() return rt.now end,
    runAsync = function(cmd) rt.ran = cmd return true end,
  }

  rt.barWidget = {
    setText = function(t) rt.bar.text = t end,
    setGlyph = function(g) rt.bar.glyph = g end,
    setTooltip = function(t) rt.bar.tooltip = t end,
  }

  return rt
end

-- Last request URL sent to `host` (or nil).
local function request_to(r, host)
  for i = #r.requests, 1, -1 do
    if r.requests[i]:find(host, 1, true) then return r.requests[i] end
  end
  return nil
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
check(#rt.requests == 3 and rt.hosts["geocoding-api.open-meteo.com"] == 1 and rt.hosts["data.buienradar.nl"] == 1
    and rt.hosts["gpsgadget.buienradar.nl"] == 1, "one geocoder, one feed and one rain request")
check(request_to(rt, "gpsgadget") and request_to(rt, "gpsgadget"):find("lat=52.78&lon=6.91", 1, true) ~= nil,
  "rain request uses the place's coordinates with two decimals (" .. tostring(request_to(rt, "gpsgadget")) .. ")")

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
-- place resolution, caching, failures and display settings (widget)
---------------------------------------------------------------------------

-- Settings as a real runtime returns them (defaults filled in), plus overrides.
local function settings_with(extra)
  local t = {
    location_mode = "city", city = "Emmen", country = "NL", latitude = 52.7792, longitude = 6.9006,
    station_id = 0, page_query = "radarType=rain&radarLocationVariant=NL&radarOffset=8H", page_url = "",
    refresh_minutes = 10, wind_unit = "bft", bar_text = "temperature",
  }
  for k, v in pairs(extra or {}) do t[k] = v end
  return t
end

-- (Re)loads the widget script on a runtime, like the shell does after a setting change.
local function load_widget(r)
  return load_entry("widget.luau", { noctalia = r.noctalia, barWidget = r.barWidget })
end

local function widget_for(extra, rain)
  local r = make_runtime(settings_with(extra), rain)
  local e = load_widget(r)
  e.update()
  return r, e
end

local function tooltip_value(r, key)
  for _, row in ipairs(type(r.bar.tooltip) == "table" and r.bar.tooltip or {}) do
    if row.key == key then return row.value end
  end
  return nil
end

-- 2.2 city resolution
local emmen = widget_for()
check(request_to(emmen, "geocoding") ==
    "https://geocoding-api.open-meteo.com/v1/search?name=Emmen&count=1&language=nl&format=json&countryCode=NL",
  "geocoder request: name, best match only, Dutch, country code (got " .. tostring(request_to(emmen, "geocoding")) .. ")")
local ep = emmen.state.buienradar.place
check(ep.name == "Emmen" and ep.region == "Drenthe" and ep.cc == "NL" and ep.geoid == 2756136
    and math.abs(ep.lat - 52.78) < 0.01 and math.abs(ep.lon - 6.91) < 0.01 and ep.label == "Emmen, Drenthe",
  "Emmen/NL resolves to Emmen, Drenthe with its GeoNames id")
local any_country = widget_for({ city = "Groningen", country = "" })
check(not request_to(any_country, "geocoding"):find("countryCode", 1, true), "an empty country leaves out countryCode")
check(any_country.state.buienradar.place.name == "Groningen", "city without a country restriction")
local hague = widget_for({ city = "The Hague" }).state.buienradar.place
local denhaag = widget_for({ city = "Den Haag" }).state.buienradar.place
check(hague.geoid == 2747373 and denhaag.geoid == 2747373 and hague.name == "Den Haag",
  "'The Hague' and 'Den Haag' resolve to the same place")
local typo = widget_for({ city = "Emmmen" })
check(typo.bar.text == "--" and typo.bar.tooltip == "Buienradar: City 'Emmmen' not found" and typo.hosts["data.buienradar.nl"] == nil,
  "unknown city: reported, no weather fetched for a guessed place (got " .. tostring(typo.bar.tooltip) .. ")")
check(typo.state["buienradar.error"] == "City 'Emmmen' not found", "the error text is published for the panel")
local no_city = widget_for({ city = "  " })
check(no_city.bar.tooltip == "Buienradar: No city set", "empty city name is reported")

-- 2.3 coordinates mode
local coords = widget_for({ location_mode = "coordinates", latitude = 52.78, longitude = 6.91 })
check(coords.hosts["geocoding-api.open-meteo.com"] == nil and coords.hosts["ipwho.is"] == nil,
  "coordinates mode needs no geocoder and no IP lookup")
check(coords.state.buienradar.place.label == "52.78, 6.91" and coords.state.buienradar.place.geoid == nil,
  "coordinates mode: the place is shown by its coordinates")
check(request_to(coords, "gpsgadget"):find("lat=52.78&lon=6.91", 1, true) ~= nil, "coordinates mode: rain outlook for those coordinates")

-- 2.4 automatic mode is an explicit opt-in
check(emmen.hosts["ipwho.is"] == nil and any_country.hosts["ipwho.is"] == nil, "default mode never contacts the IP service")
local auto_r, auto_e = widget_for({ location_mode = "auto" })
check(auto_r.hosts["ipwho.is"] == 1 and auto_r.hosts["geocoding-api.open-meteo.com"] == 1, "auto mode: one IP lookup, then the geocoder")
check(request_to(auto_r, "geocoding"):find("name=Amsterdam&", 1, true) ~= nil and request_to(auto_r, "geocoding"):find("countryCode=NL", 1, true) ~= nil,
  "auto mode: the city and country from the IP lookup go to the geocoder")
check(auto_r.state.buienradar.place.label == "Amsterdam, Noord-Holland" and auto_r.state.buienradar.place.geoid == 2759794,
  "auto mode: the place is the detected city")
check(tooltip_value(auto_r, "Place") == "Amsterdam, Noord-Holland", "the bar tooltip names the detected place")
local auto_c = widget_for({ location_mode = "auto" }, nil)
local coords_only = make_runtime(settings_with({ location_mode = "auto" }))
coords_only.ip = "coordinates_only"
load_widget(coords_only).update()
check(coords_only.state.buienradar.place.label == "52.38, 4.90" and coords_only.hosts["geocoding-api.open-meteo.com"] == nil,
  "auto mode with a coordinates-only answer: place shown by coordinates, no geocoder")
check(request_to(coords_only, "gpsgadget"):find("lat=52.38&lon=4.90", 1, true) ~= nil, "auto mode: the outlook follows the IP coordinates")
local ip_down = make_runtime(settings_with({ location_mode = "auto" }))
ip_down.failing["ipwho.is"] = true
load_widget(ip_down).update()
check(ip_down.bar.tooltip == "Buienradar: IP lookup failed (500)" and ip_down.hosts["data.buienradar.nl"] == nil,
  "auto mode: a failed IP lookup is reported and no other place is assumed (got " .. tostring(ip_down.bar.tooltip) .. ")")

-- an IP place is reused for an hour, then looked up again
auto_e.update()
check(auto_r.hosts["ipwho.is"] == 1, "auto mode: no new IP lookup within the hour")
auto_r.now = auto_r.now + 61 * 60 * 1000
auto_e.update()
check(auto_r.hosts["ipwho.is"] == 2, "auto mode: looked up again after an hour")

-- 2.5 the place is cached for city mode
local cache_r, cache_e = widget_for()
cache_e.update()
check(cache_r.hosts["geocoding-api.open-meteo.com"] == 1, "same settings: the geocoder is not asked again")
cache_r.settings.city = "Groningen"
local cache_e2 = load_widget(cache_r)
cache_e2.update()
check(cache_r.hosts["geocoding-api.open-meteo.com"] == 2 and cache_r.state.buienradar.place.name == "Groningen",
  "a changed city is resolved once")
cache_r.now = cache_r.now + 48 * 3600 * 1000
cache_e2.update()
check(cache_r.hosts["geocoding-api.open-meteo.com"] == 2, "a city place does not expire")

-- 2.6 station, distance and rain outlook follow the place
local gron = widget_for({ city = "Groningen" })
check(request_to(gron, "gpsgadget"):find("lat=53.22&lon=6.57", 1, true) ~= nil, "Groningen: rain outlook for its coordinates")
check(gron.state.buienradar.station == "Groningen" and gron.state.buienradar.station_km <= 12, "Groningen: the nearest station is its own, about 10 km out")
local es = emmen.state.buienradar
check(es.station == "Hoogeveen" and es.station_km >= 25 and es.station_km <= 28, "Emmen: Hoogeveen at about 26 km (got " .. tostring(es.station_km) .. ")")
local pinned = widget_for({ station_id = 6280 }).state.buienradar
check(pinned.station == "Groningen" and pinned.station_km > 40, "an explicit station id wins over the place")
local berlin = widget_for({ city = "Berlin", country = "DE" }).state.buienradar
check(berlin.place.cc == "DE" and berlin.station_km > 300, "far away: the distance is recorded (got " .. tostring(berlin.station_km) .. " km)")
check(es.v == 2 and es.sig == "city|emmen|NL|s0" and plain_data(es), "the snapshot has its signature and only plain data")

-- 3.1 failures and wrong-place protection
local stale_r, stale_e = widget_for()
stale_r.failing["data.buienradar.nl"] = true
stale_e.update()
check(stale_r.bar.text == "11°" and tooltip_value(stale_r, "Problem") == "Feed request failed (500)",
  "same place, refresh fails: old data stays and the failure is named")
check(tooltip_value(stale_r, "Updated"):find("(stale)", 1, true) ~= nil, "same place, refresh fails: the data is marked stale")
check(stale_r.state["buienradar.error"] == "Feed request failed (500)", "the failure is published for the panel")
stale_r.failing["data.buienradar.nl"] = nil
stale_e.update()
check(stale_r.state["buienradar.error"] == "" and tooltip_value(stale_r, "Problem") == nil, "a good refresh clears the failure")

local wrong_r, wrong_e = widget_for()
wrong_r.settings.city = "Emmmen"
local wrong_e2 = load_widget(wrong_r)
check(wrong_r.bar.text == "--", "after changing the city the old city's weather is not shown")
wrong_e2.update()
check(wrong_r.bar.text == "--" and wrong_r.bar.tooltip == "Buienradar: City 'Emmmen' not found",
  "new city not found: placeholder and the reason, not the weather of the old city")
local first_fail = make_runtime(settings_with())
first_fail.failing["geocoding-api.open-meteo.com"] = true
load_widget(first_fail).update()
check(first_fail.bar.text == "--" and first_fail.bar.tooltip == "Buienradar: Geocoder request failed (500)",
  "failure at the first refresh: placeholder and the reason")
check(wrong_r.state["buienradar.sig"] == "city|emmmen|NL|s0", "the widget publishes the signature it is configured for")

-- 4.1 bar text modes
local function bar_for(extra, rain, mutate)
  local r = make_runtime(settings_with(extra), rain)
  local e = load_widget(r)
  e.update()
  if mutate then
    local snap = r.state.buienradar
    mutate(snap)
    r.noctalia.state.set("buienradar", snap)
  end
  return r
end
check(bar_for({ bar_text = "temperature" }).bar.text == "11°", "bar text: temperature only")
check(bar_for({ bar_text = "temperature_feels" }).bar.text == "11° (8°)", "bar text: temperature and feels-like")
check(bar_for({ bar_text = "temperature_feels" }, nil, function(s) s.feels = nil end).bar.text == "11°",
  "bar text: no feels-like available leaves the temperature only")
check(bar_for({ bar_text = "temperature_rain" }).bar.text == "11° ☂", "bar text: rain now or soon adds the umbrella")
check(bar_for({ bar_text = "temperature_rain" }, build_rain("15:30", 24)).bar.text == "11°", "bar text: dry outlook has no umbrella")
check(bar_for({ bar_text = "temperature_rain" }, build_rain("15:30", 24, { [1] = 100 })).bar.text == "11° ☂",
  "bar text: only the current step wet still adds the umbrella")
check(bar_for({ bar_text = "temperature_rain" }, build_rain("15:30", 24, { [24] = 90 })).bar.text == "11° ☂",
  "bar text: a wet step at the end of the 2 hours counts")
check(bar_for({ bar_text = "temperature_rain" }, build_rain("15:30", 24, { [3] = 76 })).bar.text == "11°",
  "bar text: raw 76 (below 0.1 mm/h) is not rain")
local no_outlook = make_runtime(settings_with({ bar_text = "temperature_rain" }))
no_outlook.failing["gpsgadget.buienradar.nl"] = true
load_widget(no_outlook).update()
check(no_outlook.bar.text == "11°" and no_outlook.state.buienradar.rain == nil, "bar text: outlook unavailable gives the temperature only")

-- two bar widgets, two modes, one data set
local two = make_runtime(settings_with())
local second = { text = nil }
local second_bar = { setText = function(t) second.text = t end, setGlyph = function() end, setTooltip = function() end }
-- inside a widget noctalia.getConfig returns that widget's own value for widget-level settings
local second_noctalia = setmetatable({
  getConfig = function(k) if k == "bar_text" then return "temperature_rain" end return two.noctalia.getConfig(k) end,
}, { __index = two.noctalia })
load_entry("widget.luau", { noctalia = second_noctalia, barWidget = second_bar })
load_widget(two).update()
check(two.bar.text == "11°" and second.text == "11° ☂", "two bar widgets show their own text for the same data")

-- wind units (tooltip row)
local function wind_for(unit, mutate) return tooltip_value(bar_for({ wind_unit = unit }, nil, mutate), "Wind") end
check(wind_for("bft") == "W 4 Bft", "wind: Beaufort (got " .. tostring(wind_for("bft")) .. ")")
check(wind_for("ms") == "W 7.3 m/s", "wind: metres per second (got " .. tostring(wind_for("ms")) .. ")")
check(wind_for("kmh") == "W 26 km/h", "wind: kilometres per hour (got " .. tostring(wind_for("kmh")) .. ")")
check(wind_for("bogus") == "W 4 Bft", "wind: an unknown unit falls back to Beaufort")
check(wind_for("kmh", function(s) s.wind_dir, s.wind_ms, s.wind_bft = nil, nil, nil end) == "-", "wind: not reported shows a dash")

-- 4.2 snapshots from before the raw numbers existed still draw
local legacy = {
  station = "Hoogeveen", updated = "15:00", desc = "Zwaar bewolkt en regen", glyph = "cloud-rain",
  temp_text = "11°", feels_text = "8°", wind_text = "W 4 Bft", humidity_text = "89%", pressure_text = "1008 hPa",
  rain_hour_text = "3.3 mm", sunrise = "07:53", sunset = "18:54", days = {},
}
local old_r = make_runtime(settings_with({ bar_text = "temperature_feels", wind_unit = "kmh" }))
old_r.state.buienradar = legacy
load_widget(old_r)
check(old_r.bar.text == "11° (8°)" and tooltip_value(old_r, "Wind") == "W 4 Bft", "an older snapshot draws from its text fields")

-- 4.3 display settings apply without a request
local live = make_runtime(settings_with())
local live_e = load_widget(live)
live_e.update()
local live_requests = #live.requests
live.settings.wind_unit = "kmh"
live.settings.bar_text = "temperature_feels"
load_widget(live)
check(live.bar.text == "11° (8°)" and tooltip_value(live, "Wind") == "W 26 km/h" and #live.requests == live_requests,
  "changed unit and bar text apply at once, with no request")

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

local before_refresh = #rt.requests
penv.onRefreshClicked()
check(rt.state["buienradar.refresh"] == rt.now, "refresh button publishes a refresh request")
check(#rt.requests == before_refresh + 2, "widget refetches feed and rain, not the place (new requests: " .. (#rt.requests - before_refresh) .. ")")

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

---------------------------------------------------------------------------
-- panel: place, wind units, link, wrong-place protection, errors
---------------------------------------------------------------------------

-- Opens the panel on a runtime; returns a function giving the tree drawn last.
local function open_live(r)
  local tree
  local pe = load_entry("panel.luau", {
    noctalia = r.noctalia,
    ui = ui,
    panel = { render = function(t) tree = t end, close = function() end },
  })
  pe.onOpen({})
  return function() return tree end, pe
end

do -- 5.1 place and station
  local tree = open_live(emmen)()
  check(count_exact(tree, "Emmen, Drenthe · Station Hoogeveen") == 1, "panel names the place and the station (got "
    .. tostring(find_text(tree, "Station")[1]) .. ")")
  check(#find_text(tree, "km away") == 0, "a near station (27 km) comes without a distance")

  local far_tree = open_live(widget_for({ city = "Berlin", country = "DE" }))()
  local far_text = find_text(far_tree, "km away")[1]
  check(far_text ~= nil and far_text:find("Berlijn, Deelstaat Berlijn", 1, true) ~= nil and far_text:match(", %d+ km away$") ~= nil,
    "a far station is shown with its distance (got " .. tostring(far_text) .. ")")
end

do -- 5.2 wind units: the same cases through the widget tooltip and the panel
  local cases = {
    { unit = "bft", ms = 7.3, bft = 4, dir = "W", text = "W 4 Bft" },
    { unit = "ms", ms = 7.3, bft = 4, dir = "W", text = "W 7.3 m/s" },
    { unit = "kmh", ms = 7.3, bft = 4, dir = "W", text = "W 26 km/h" },
    { unit = "kmh", ms = 0, bft = 0, dir = "ZW", text = "SW 0 km/h" },
    { unit = "ms", ms = 12.5, bft = 6, dir = "OZO", text = "ESE 12.5 m/s" },
    { unit = "bft", ms = nil, bft = nil, dir = "W", text = "W -" },
    { unit = "kmh", ms = nil, bft = nil, dir = nil, text = "-" },
    { unit = "ms", ms = 7.3, bft = 4, dir = nil, text = "7.3 m/s" },
  }
  local agree = true
  for _, c in ipairs(cases) do
    local r = make_runtime(settings_with({ wind_unit = c.unit }))
    load_widget(r)
    local snap = copy(emmen.state.buienradar)
    snap.wind_ms, snap.wind_bft, snap.wind_dir = c.ms, c.bft, c.dir
    r.noctalia.state.set("buienradar", snap)
    local bar_side = tooltip_value(r, "Wind")
    local panel_side = count_exact(open_live(r)(), c.text)
    if bar_side ~= c.text or panel_side < 1 then
      agree = false
      print("      wind case " .. c.unit .. ": bar=" .. tostring(bar_side) .. " panel hits=" .. panel_side .. " wanted " .. c.text)
    end
  end
  check(agree, "bar tooltip and panel format the wind identically in all " .. #cases .. " cases")

  local switched = make_runtime(settings_with({ wind_unit = "bft" }))
  load_widget(switched)
  switched.noctalia.state.set("buienradar", copy(emmen.state.buienradar))
  local get_tree = open_live(switched)
  switched.settings.wind_unit = "kmh"
  local live_tree = open_live(switched)()
  check(count_exact(live_tree, "W 26 km/h") >= 1, "a panel opened after switching the unit shows the new unit")
end

do -- 4.2 (panel) snapshots from before the raw numbers existed
  local tree = open_live(old_r)()
  check(tree ~= nil and count_exact(tree, "W 4 Bft") >= 1 and count_exact(tree, "11°") >= 1 and #find_text(tree, "Station Hoogeveen") >= 1,
    "an older snapshot is drawn from its text fields, without a place")
end

do -- 5.3 link to buienradar.nl
  local function link(extra, rain, mutate)
    local r = make_runtime(settings_with(extra), rain)
    load_widget(r).update()
    if mutate then mutate(r) end
    local _, pe = open_live(r)
    pe.onOpenSiteClicked()
    return r.ran
  end
  local default = link()
  check(type(default) == "table" and #default == 2 and default[1] == "xdg-open"
      and default[2] == "https://www.buienradar.nl/weer/emmen/nl/2756136?radarType=rain&radarLocationVariant=NL&radarOffset=8H",
    "default link for Emmen, as one argument of xdg-open (got " .. tostring(default and default[2]) .. ")")
  check(link({ city = "'s-Hertogenbosch" })[2]:find("^https://www%.buienradar%.nl/weer/s%-hertogenbosch/nl/2747351%?") ~= nil,
    "an apostrophe in the name becomes a clean path segment")
  check(link({ page_query = "" })[2] == "https://www.buienradar.nl/weer/emmen/nl/2756136", "empty parameters: plain city page, no '?'")
  check(link({ page_url = "https://example.test/emmen?a=1&b=2" })[2] == "https://example.test/emmen?a=1&b=2",
    "a full URL overrides everything")
  check(link({ location_mode = "coordinates" })[2] == "https://www.buienradar.nl", "coordinates mode opens the home page")
  local coords_only = make_runtime(settings_with({ location_mode = "auto" }))
  coords_only.ip = "coordinates_only"
  load_widget(coords_only).update()
  local _, coords_pe = open_live(coords_only)
  coords_pe.onOpenSiteClicked()
  check(coords_only.ran[2] == "https://www.buienradar.nl", "an IP place without a city opens the home page")
  check(link({ location_mode = "auto" })[2]:find("/weer/amsterdam/nl/2759794", 1, true) ~= nil, "an IP place with a city gets the city page")
  check(link({ page_query = "x=1&y=2" })[2]:sub(-8) == "?x=1&y=2", "the link parameters come from the setting")
  local no_data = make_runtime(settings_with())
  load_widget(no_data)
  local _, nd_pe = open_live(no_data)
  nd_pe.onOpenSiteClicked()
  check(no_data.ran[2] == "https://www.buienradar.nl", "without data the link opens the home page")
end

do -- 5.4 wrong-place protection and errors
  local r = widget_for()
  r.settings.city = "Groningen"
  load_widget(r) -- the setting changed: the widget publishes the new signature
  local tree = open_live(r)()
  check(count_exact(tree, "Waiting for Buienradar...") == 1 and #find_text(tree, "Hoogeveen") == 0,
    "a snapshot for another city is not shown, the panel waits")

  r.settings.city = "Emmmen"
  local e = load_widget(r)
  local get_tree = open_live(r)
  e.update()
  check(count_exact(get_tree(), "City 'Emmmen' not found") == 1 and count_exact(get_tree(), "Waiting for Buienradar...") == 1,
    "the waiting panel redraws itself with the reason when the lookup fails")

  local s = widget_for()
  s.failing["data.buienradar.nl"] = true
  local live, _ = open_live(s)
  local s_e = load_widget(s)
  s_e.update()
  check(count_exact(live(), "Feed request failed (500)") == 1 and count_exact(live(), "Updated 15:10 (stale)") == 1,
    "same place, refresh failed: the data stays, marked stale, with the reason")
  s.failing["data.buienradar.nl"] = nil
  s_e.update()
  check(#find_text(live(), "stale") == 0 and #find_text(live(), "Feed request failed") == 0, "after a good refresh the error is gone")
end

-- empty state
local rt5 = make_runtime({})
local rendered5
local penv5 = load_entry("panel.luau", { noctalia = rt5.noctalia, ui = ui, panel = { render = function(t) rendered5 = t end, close = function() end } })
penv5.onOpen({})
check(#find_text(rendered5, "Waiting") >= 1, "panel shows a waiting message without data")

print(failures == 0 and "\nall checks passed" or ("\n" .. failures .. " check(s) failed"))
os.exit(failures == 0 and 0 or 1)
