-- Buienradar bar widget.
--
-- Fetches the public Buienradar feed + 2-hour rain outlook, shows glyph and
-- temperature in the bar, and publishes the whole snapshot to plugin state so
-- the forecast panel (panel.luau) can render it without fetching anything.

local FEED_URL = "https://data.buienradar.nl/2.0/feed/json"
local RAIN_URL = "https://gpsgadget.buienradar.nl/data/raintext"
local STATE_KEY = "buienradar"
local REFRESH_KEY = "buienradar.refresh"
local PANEL_ID = "lazy/buienradar:forecast"

local WEEKDAYS = { "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" }
local WET_THRESHOLD = 77 -- raw raintext value: 10^((77-109)/32) = 0.1 mm/h

-- Glyph by keyword in Buienradar's Dutch description (checked in this order).
local DESC_RULES = {
  { "onweer", "cloud-storm" },
  { "sneeuw", "cloud-snow" },
  { "hagel", "cloud-snow" },
  { "regen", "cloud-rain" },
  { "bui", "cloud-rain" },
  { "motregen", "cloud-rain" },
  { "mist", "cloud-fog" },
  { "nevel", "cloud-fog" },
  { "onbewolkt", "sun" },
  { "zonnig", "sun" },
  { "helder", "sun" },
  { "opklaring", "cloud-sun" },
  { "afwisselend", "cloud-sun" },
  { "bewolkt", "cloud" },
}

-- Fallback by icon letter (e.g. ".../30x30/q.png" -> "q").
local CODE_GLYPHS = {
  a = "sun", b = "cloud-sun", j = "cloud-sun", o = "cloud-sun", r = "cloud-sun",
  c = "cloud", p = "cloud", d = "cloud-fog", n = "cloud-fog",
  f = "cloud-rain", h = "cloud-rain", k = "cloud-rain", l = "cloud-rain",
  m = "cloud-rain", q = "cloud-rain", g = "cloud-storm", s = "cloud-storm",
  i = "cloud-snow", t = "cloud-snow", u = "cloud-snow", v = "cloud-snow", w = "cloud-snow",
}

local busy = false
local last_error = nil

---------------------------------------------------------------------------
-- helpers
---------------------------------------------------------------------------

local function round(x)
  return math.floor(x + 0.5)
end

-- First number in a value that may be a number or a string like "9/12".
local function first_number(v)
  if type(v) == "number" then return v end
  if v == nil then return nil end
  return tonumber(tostring(v):match("%-?%d+%.?%d*"))
end

local function degrees(v)
  local n = first_number(v)
  if not n then return "-" end
  return string.format("%d°", round(n))
end

-- Dutch compass letters -> English (Z = zuid -> S, O = oost -> E).
local function compass(dir)
  if type(dir) ~= "string" then return "" end
  return (dir:upper():gsub("Z", "S"):gsub("O", "E"))
end

local function minutes_of_day(s)
  local h, m = tostring(s):match("(%d%d):(%d%d)")
  if h then return tonumber(h) * 60 + tonumber(m) end
  return nil
end

-- 0 = Sunday. Howard Hinnant's days_from_civil.
local function weekday_of(date)
  local y, m, d = tostring(date):match("(%d+)-(%d+)-(%d+)")
  if not y then return nil end
  y, m, d = tonumber(y), tonumber(m), tonumber(d)
  if m <= 2 then y = y - 1 end
  local era = math.floor(y / 400)
  local yoe = y - era * 400
  local mp = (m + 9) % 12
  local doy = math.floor((153 * mp + 2) / 5) + d - 1
  local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
  local days = era * 146097 + doe - 719468
  return (days + 4) % 7
end

local function is_night(actual)
  local now = minutes_of_day(noctalia.formatTime("%H:%M"))
  local rise = minutes_of_day(actual.sunrise)
  local set = minutes_of_day(actual.sunset)
  if not (now and rise and set) then return false end
  return now < rise or now >= set
end

local function pick_glyph(desc, iconurl, night)
  local glyph
  local lower = type(desc) == "string" and desc:lower() or ""
  for _, rule in ipairs(DESC_RULES) do
    if lower:find(rule[1], 1, true) then
      glyph = rule[2]
      break
    end
  end
  if not glyph then
    local code = tostring(iconurl or ""):match("/(%a+)%.png")
    glyph = code and CODE_GLYPHS[code:sub(1, 1):lower()] or "cloud"
  end
  if night then
    if glyph == "sun" then return "moon-stars" end
    if glyph == "cloud-sun" then return "cloud" end
  end
  return glyph
end

local function config_number(key, fallback)
  local v = noctalia.getConfig(key)
  if type(v) == "number" then return v end
  return fallback
end

---------------------------------------------------------------------------
-- parsing
---------------------------------------------------------------------------

local function nearest_station(stations, lat, lon)
  local best, best_d
  local k = math.cos(math.rad(lat))
  for _, s in ipairs(stations) do
    -- skip stations that do not report a temperature
    if type(s.lat) == "number" and type(s.lon) == "number" and type(s.temperature) == "number" then
      local dy = s.lat - lat
      local dx = (s.lon - lon) * k
      local d = dx * dx + dy * dy
      if not best_d or d < best_d then
        best, best_d = s, d
      end
    end
  end
  return best
end

local function find_station(stations, id, lat, lon)
  if id and id > 0 then
    for _, s in ipairs(stations) do
      if s.stationid == id then return s end
    end
  end
  return nearest_station(stations, lat, lon)
end

local function build_snapshot(body, id, lat, lon)
  local feed = noctalia.json.decode(body)
  if type(feed) ~= "table" or type(feed.actual) ~= "table" then return nil, "unexpected feed format" end

  local stations = feed.actual.stationmeasurements
  if type(stations) ~= "table" then return nil, "feed has no stations" end

  local s = find_station(stations, id, lat, lon)
  if not s then return nil, "no matching station" end

  local night = is_night(feed.actual)
  local snap = {
    station = tostring(s.regio or s.stationname or "?"),
    updated = noctalia.formatTime("%H:%M"),
    desc = tostring(s.weatherdescription or ""),
    glyph = pick_glyph(s.weatherdescription, s.iconurl, night),
    temp_text = degrees(s.temperature),
    feels_text = degrees(s.feeltemperature),
    wind_text = string.format("%s %s Bft", compass(s.winddirection), tostring(s.windspeedBft or "-")),
    humidity_text = s.humidity and string.format("%d%%", round(s.humidity)) or "-",
    pressure_text = s.airpressure and string.format("%d hPa", round(s.airpressure)) or "-",
    rain_hour_text = s.rainFallLastHour and string.format("%.1f mm", s.rainFallLastHour) or "-",
    sunrise = tostring(feed.actual.sunrise or ""):match("T(%d%d:%d%d)") or "",
    sunset = tostring(feed.actual.sunset or ""):match("T(%d%d:%d%d)") or "",
    days = {},
  }

  local forecast = feed.forecast and feed.forecast.fivedayforecast
  if type(forecast) == "table" then
    for _, f in ipairs(forecast) do
      local wd = weekday_of(f.day)
      local mm_min, mm_max = first_number(f.mmRainMin), first_number(f.mmRainMax)
      local mm_text = ""
      if mm_max and mm_max > 0 then
        mm_text = string.format("%.1f-%.1f mm", mm_min or 0, mm_max)
      end
      snap.days[#snap.days + 1] = {
        label = wd and WEEKDAYS[wd + 1] or "?",
        date = tostring(f.day or ""):sub(1, 10),
        glyph = pick_glyph(f.weatherdescription, f.iconurl, false),
        desc = tostring(f.weatherdescription or ""),
        min_text = degrees(f.mintemperature),
        max_text = degrees(f.maxtemperature),
        chance = first_number(f.rainChance) or 0,
        mm_text = mm_text,
      }
    end
  end

  return snap
end

-- Body: "087|15:25\r\n..." (raw value, 5-minute steps, ~2 hours).
local function parse_rain(body)
  local values, times, wet = {}, {}, {}
  for raw, time in tostring(body):gmatch("(%d+)|(%d%d:%d%d)") do
    local v = tonumber(raw)
    local mm = v > 0 and 10 ^ ((v - 109) / 32) or 0
    values[#values + 1] = math.min(1, math.sqrt(mm / 5))
    times[#times + 1] = time
    wet[#wet + 1] = v >= WET_THRESHOLD
  end
  if #values == 0 then return nil end

  local note
  local first_wet
  for i, w in ipairs(wet) do
    if w then first_wet = i break end
  end
  if not first_wet then
    note = "Dry for the next 2 hours"
  elseif first_wet == 1 then
    local first_dry
    for i, w in ipairs(wet) do
      if not w then first_dry = i break end
    end
    note = first_dry and ("Rain until " .. times[first_dry]) or "Rain for the next 2 hours"
  else
    note = "Rain from " .. times[first_wet]
  end

  return { values = values, start = times[1], stop = times[#times], note = note }
end

---------------------------------------------------------------------------
-- bar rendering
---------------------------------------------------------------------------

local function render(d)
  if type(d) ~= "table" then
    barWidget.setGlyph(last_error and "cloud-off" or "cloud")
    barWidget.setText("--")
    barWidget.setTooltip(last_error and ("Buienradar: " .. last_error) or "Buienradar: loading...")
    return
  end

  barWidget.setGlyph(d.glyph)
  barWidget.setText(d.temp_text)

  local rows = {
    { key = d.station, value = d.desc },
    { key = "Feels like", value = d.feels_text },
    { key = "Wind", value = d.wind_text },
    { key = "Humidity", value = d.humidity_text },
  }
  if d.rain then
    rows[#rows + 1] = { key = "Rain", value = d.rain.note }
  end
  rows[#rows + 1] = { key = "Updated", value = d.updated .. (last_error and " (stale)" or "") }
  barWidget.setTooltip(rows)
end

---------------------------------------------------------------------------
-- networking
---------------------------------------------------------------------------

local function get(url, cb)
  local accepted = noctalia.http({
    url = url,
    headers = { "Accept: application/json, text/plain" },
    follow_redirects = true,
  }, function(resp)
    if resp and resp.ok and resp.status == 200 and type(resp.body) == "string" then
      cb(resp.body)
    else
      cb(nil, resp and tostring(resp.status) or "no response")
    end
  end)
  if not accepted then cb(nil, "request rejected") end
end

local function fail(msg)
  last_error = msg
  noctalia.log("buienradar: " .. msg)
  busy = false
  render(noctalia.state.get(STATE_KEY))
end

local function refresh()
  if busy then return end
  busy = true

  local id = config_number("station_id", 0)
  local lat = config_number("latitude", 52.7792)
  local lon = config_number("longitude", 6.9006)

  get(FEED_URL, function(body, err)
    if not body then return fail("feed request failed (" .. tostring(err) .. ")") end

    local snap, perr = build_snapshot(body, id, lat, lon)
    if not snap then return fail(perr or "could not parse feed") end

    -- two decimals: more precision makes the endpoint answer with a redirect
    get(string.format("%s?lat=%.2f&lon=%.2f", RAIN_URL, lat, lon), function(rain_body)
      if rain_body then
        snap.rain = parse_rain(rain_body)
      end
      last_error = nil
      busy = false
      noctalia.state.set(STATE_KEY, snap) -- triggers render() via watch below
    end)
  end)
end

---------------------------------------------------------------------------
-- entry points
---------------------------------------------------------------------------

function update()
  noctalia.setUpdateInterval(config_number("refresh_minutes", 10) * 60 * 1000)
  refresh()
end

function onClick()
  noctalia.togglePanel(PANEL_ID)
end

function onRightClick()
  refresh()
end

noctalia.state.watch(STATE_KEY, render)
noctalia.state.watch(REFRESH_KEY, function() refresh() end)
render(noctalia.state.get(STATE_KEY))
