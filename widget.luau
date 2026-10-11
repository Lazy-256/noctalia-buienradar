-- Buienradar bar widget.
--
-- Works out which place the weather is for (city name, IP address or plain
-- coordinates), fetches the public Buienradar feed + 2-hour rain outlook for
-- it, shows glyph and text in the bar, and publishes the whole snapshot to
-- plugin state so the forecast panel (panel.luau) can render it without
-- fetching anything.
--
-- The snapshot carries raw numbers next to the old preformatted texts; units
-- and the bar text are applied when drawing, so changing a setting needs no
-- new download.

local FEED_URL = "https://data.buienradar.nl/2.0/feed/json"
local RAIN_URL = "https://gpsgadget.buienradar.nl/data/raintext"
local GEOCODE_URL = "https://geocoding-api.open-meteo.com/v1/search"
local IP_URL = "https://ipwho.is/"
local STATE_KEY = "buienradar"
local REFRESH_KEY = "buienradar.refresh"
local PLACE_KEY = "buienradar.place" -- { sig, place, at }: the resolved place
local SIG_KEY = "buienradar.sig" -- signature of the current settings
local ERROR_KEY = "buienradar.error" -- last error text, "" when fine
local PANEL_ID = "lazy/buienradar:forecast"

local DEFAULT_CITY, DEFAULT_COUNTRY = "Emmen", "NL"
local DEFAULT_LAT, DEFAULT_LON = 52.7792, 6.9006
local AUTO_TTL_MS = 60 * 60 * 1000 -- an IP-based place is looked up again after an hour
local RAIN_HINT = "☂"

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

local function trim(s)
  s = s:gsub("^%s+", "")
  s = s:gsub("%s+$", "")
  return s
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

local function config_string(key, fallback)
  local v = noctalia.getConfig(key)
  if type(v) == "string" then return v end
  return fallback
end

---------------------------------------------------------------------------
-- settings
---------------------------------------------------------------------------

local function location_mode()
  local mode = config_string("location_mode", "city")
  if mode == "auto" or mode == "coordinates" then return mode end
  return "city"
end

local function wind_unit()
  local unit = config_string("wind_unit", "bft")
  if unit == "ms" or unit == "kmh" then return unit end
  return "bft"
end

-- bar_text is a widget-level setting: inside a widget noctalia.getConfig returns this widget's own value.
local function bar_mode()
  local mode = config_string("bar_text", "temperature")
  if mode == "temperature_feels" or mode == "temperature_rain" then return mode end
  return "temperature"
end

-- What the resolved place depends on; a cached place is valid while it matches.
local function place_sig()
  local mode = location_mode()
  if mode == "auto" then return "auto" end
  if mode == "coordinates" then
    return string.format("coords|%.4f|%.4f", config_number("latitude", DEFAULT_LAT), config_number("longitude", DEFAULT_LON))
  end
  return "city|" .. trim(config_string("city", DEFAULT_CITY)):lower() .. "|" .. trim(config_string("country", DEFAULT_COUNTRY)):upper()
end

-- What a snapshot depends on: the place and the chosen station. A snapshot is
-- only drawn while its signature equals the current one (never another place's weather).
local function current_sig()
  return place_sig() .. "|s" .. tostring(config_number("station_id", 0))
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

---------------------------------------------------------------------------
-- resolving the place
---------------------------------------------------------------------------

local function coords_place(lat, lon, source)
  local label = string.format("%.2f, %.2f", lat, lon)
  return { name = label, label = label, lat = lat, lon = lon, source = source }
end

local function geocoded_place(r)
  local place = { name = tostring(r.name), lat = r.latitude, lon = r.longitude, source = "city" }
  if r.admin1 then place.region = tostring(r.admin1) end
  if r.country_code then place.cc = tostring(r.country_code) end
  if r.id then place.geoid = r.id end
  place.label = place.region and (place.name .. ", " .. place.region) or place.name
  return place
end

-- Best match for a city name (Dutch or English), optionally within one country.
-- An empty countryCode parameter finds nothing, so it is left out when unset.
local function geocode(name, country, cb)
  name = trim(name)
  country = trim(country):upper()
  if name == "" then return cb(nil, "No city set") end

  local url = GEOCODE_URL .. "?name=" .. noctalia.string.urlEncode(name) .. "&count=1&language=nl&format=json"
  if country ~= "" then
    url = url .. "&countryCode=" .. noctalia.string.urlEncode(country)
  end

  get(url, function(body, err)
    if not body then return cb(nil, "Geocoder request failed (" .. tostring(err) .. ")") end
    local data = noctalia.json.decode(body)
    local r = type(data) == "table" and type(data.results) == "table" and data.results[1] or nil
    if type(r) ~= "table" or type(r.latitude) ~= "number" or type(r.longitude) ~= "number" then
      return cb(nil, string.format("City '%s' not found", name))
    end
    cb(geocoded_place(r))
  end)
end

-- Approximate place from the IP address: { city, cc, lat, lon }.
local function ip_lookup(cb)
  get(IP_URL, function(body, err)
    if not body then return cb(nil, "IP lookup failed (" .. tostring(err) .. ")") end
    local d = noctalia.json.decode(body)
    if type(d) ~= "table" or d.success == false or type(d.latitude) ~= "number" or type(d.longitude) ~= "number" then
      return cb(nil, "IP lookup found no location")
    end
    cb({ city = d.city, cc = d.country_code, lat = d.latitude, lon = d.longitude })
  end)
end

-- The IP's city goes through the geocoder, so id, region and name come from the
-- same source as in city mode; without a usable city the IP's coordinates are used.
local function resolve_auto(cb)
  ip_lookup(function(ip, err)
    if not ip then return cb(nil, err) end
    if type(ip.city) == "string" and ip.city ~= "" then
      geocode(ip.city, type(ip.cc) == "string" and ip.cc or "", function(place)
        cb(place or coords_place(ip.lat, ip.lon, "ip"))
      end)
    else
      cb(coords_place(ip.lat, ip.lon, "ip"))
    end
  end)
end

-- cb(place) or cb(nil, error text). City and IP results are cached in the shared
-- state; a cached IP place expires after an hour.
local function resolve_place(cb)
  local mode = location_mode()
  if mode == "coordinates" then
    return cb(coords_place(config_number("latitude", DEFAULT_LAT), config_number("longitude", DEFAULT_LON), "coordinates"))
  end

  local sig = place_sig()
  local now = noctalia.nowMs()
  local cached = noctalia.state.get(PLACE_KEY)
  if type(cached) == "table" and cached.sig == sig and type(cached.place) == "table"
      and (mode ~= "auto" or now - (cached.at or 0) < AUTO_TTL_MS) then
    return cb(cached.place)
  end

  local function done(place, err)
    if not place then return cb(nil, err) end
    noctalia.state.set(PLACE_KEY, { sig = sig, place = place, at = now })
    cb(place)
  end

  if mode == "auto" then
    resolve_auto(done)
  else
    geocode(config_string("city", DEFAULT_CITY), config_string("country", DEFAULT_COUNTRY), done)
  end
end

---------------------------------------------------------------------------
-- parsing
---------------------------------------------------------------------------

local function distance_km(s, lat, lon)
  local dy = s.lat - lat
  local dx = (s.lon - lon) * math.cos(math.rad(lat))
  return math.sqrt(dx * dx + dy * dy) * 111.2
end

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

-- An explicit station id wins over the place. Returns the station and its distance in km.
local function find_station(stations, id, lat, lon)
  local s
  if id and id > 0 then
    for _, candidate in ipairs(stations) do
      if candidate.stationid == id then s = candidate break end
    end
  end
  s = s or nearest_station(stations, lat, lon)
  if not s then return nil end
  local km = type(s.lat) == "number" and type(s.lon) == "number" and distance_km(s, lat, lon) or nil
  return s, km
end

local function build_snapshot(body, id, place)
  local feed = noctalia.json.decode(body)
  if type(feed) ~= "table" or type(feed.actual) ~= "table" then return nil, "unexpected feed format" end

  local stations = feed.actual.stationmeasurements
  if type(stations) ~= "table" then return nil, "feed has no stations" end

  local s, km = find_station(stations, id, place.lat, place.lon)
  if not s then return nil, "no matching station" end

  local night = is_night(feed.actual)
  local snap = {
    v = 2, -- snapshot with raw numbers; older ones only have the texts
    place = place,
    station = tostring(s.regio or s.stationname or "?"),
    station_km = km and round(km) or nil,
    updated = noctalia.formatTime("%H:%M"),
    desc = tostring(s.weatherdescription or ""),
    glyph = pick_glyph(s.weatherdescription, s.iconurl, night),
    temp = type(s.temperature) == "number" and s.temperature or nil,
    feels = type(s.feeltemperature) == "number" and s.feeltemperature or nil,
    wind_dir = type(s.winddirection) == "string" and s.winddirection or nil,
    wind_bft = type(s.windspeedBft) == "number" and s.windspeedBft or nil,
    wind_ms = type(s.windspeed) == "number" and s.windspeed or nil,
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
--
-- Besides the 0..1 bar heights this returns what the panel needs for the
-- half-hour scale and the bar tooltips:
--   ticks = { { index = <1-based bar>, label = "HH:MM" }, ... }  at every :00 / :30
--   tips  = { "15:25 - 0.2 mm/h" | "15:30 - dry", ... }          one per bar
-- and `expected`: true when any step is wet (the rain hint in the bar).
local function parse_rain(body)
  local values, times, wet, ticks, tips = {}, {}, {}, {}, {}
  for raw, time in tostring(body):gmatch("(%d+)|(%d%d:%d%d)") do
    local v = tonumber(raw)
    local mm = v > 0 and 10 ^ ((v - 109) / 32) or 0
    local is_wet = v >= WET_THRESHOLD
    values[#values + 1] = math.min(1, math.sqrt(mm / 5))
    times[#times + 1] = time
    wet[#wet + 1] = is_wet
    tips[#tips + 1] = time .. " - " .. (is_wet and string.format("%.1f mm/h", mm) or "dry")
    local minute = time:sub(4, 5)
    if minute == "00" or minute == "30" then
      ticks[#ticks + 1] = { index = #values, label = time }
    end
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

  return {
    values = values,
    start = times[1],
    stop = times[#times],
    note = note,
    ticks = ticks,
    tips = tips,
    expected = first_wet ~= nil,
  }
end

---------------------------------------------------------------------------
-- formatting (units and bar text are applied here, when drawing)
---------------------------------------------------------------------------

local function temp_text(d)
  if d.v == 2 then return degrees(d.temp) end
  return d.temp_text
end

-- nil when the station reports no feels-like temperature
local function feels_text(d)
  if d.v == 2 then
    if type(d.feels) ~= "number" then return nil end
    return degrees(d.feels)
  end
  if d.feels_text == nil or d.feels_text == "-" then return nil end
  return d.feels_text
end

local function wind_text(d, unit)
  if d.v ~= 2 then return d.wind_text end
  local value
  if unit == "ms" then
    value = type(d.wind_ms) == "number" and string.format("%.1f m/s", d.wind_ms) or nil
  elseif unit == "kmh" then
    value = type(d.wind_ms) == "number" and string.format("%d km/h", round(d.wind_ms * 3.6)) or nil
  else
    value = type(d.wind_bft) == "number" and string.format("%d Bft", d.wind_bft) or nil
  end
  local dir = compass(d.wind_dir)
  return (dir ~= "" and (dir .. " ") or "") .. (value or "-")
end

local function bar_text(d, mode)
  local text = temp_text(d)
  if mode == "temperature_feels" then
    local feels = feels_text(d)
    if feels then return text .. " (" .. feels .. ")" end
  elseif mode == "temperature_rain" and d.rain_expected == true then
    return text .. " " .. RAIN_HINT
  end
  return text
end

---------------------------------------------------------------------------
-- bar rendering
---------------------------------------------------------------------------

local function render(d)
  -- Never draw data of another place: a snapshot for a different signature is as
  -- good as no data (snapshots from before signatures existed have none and are
  -- shown until the next refresh replaces them).
  if type(d) ~= "table" or (d.sig ~= nil and d.sig ~= current_sig()) then
    barWidget.setGlyph(last_error and "cloud-off" or "cloud")
    barWidget.setText("--")
    barWidget.setTooltip(last_error and ("Buienradar: " .. last_error) or "Buienradar: loading...")
    return
  end

  barWidget.setGlyph(d.glyph)
  barWidget.setText(bar_text(d, bar_mode()))

  local rows = {}
  if type(d.place) == "table" and d.place.label then
    rows[#rows + 1] = { key = "Place", value = d.place.label }
  end
  rows[#rows + 1] = { key = d.station, value = d.desc }
  rows[#rows + 1] = { key = "Feels like", value = feels_text(d) or "-" }
  rows[#rows + 1] = { key = "Wind", value = wind_text(d, wind_unit()) }
  rows[#rows + 1] = { key = "Humidity", value = d.humidity_text }
  if d.rain then
    rows[#rows + 1] = { key = "Rain", value = d.rain.note }
  end
  rows[#rows + 1] = { key = "Updated", value = d.updated .. (last_error and " (stale)" or "") }
  if last_error then
    rows[#rows + 1] = { key = "Problem", value = last_error }
  end
  barWidget.setTooltip(rows)
end

---------------------------------------------------------------------------
-- refreshing
---------------------------------------------------------------------------

local function fail(msg)
  last_error = msg
  noctalia.log("buienradar: " .. msg)
  busy = false
  noctalia.state.set(ERROR_KEY, msg)
  render(noctalia.state.get(STATE_KEY))
end

local function refresh()
  if busy then return end
  busy = true

  local sig = current_sig()
  resolve_place(function(place, err)
    if not place then return fail(err or "Could not determine the place") end

    get(FEED_URL, function(body, ferr)
      if not body then return fail("Feed request failed (" .. tostring(ferr) .. ")") end

      local snap, perr = build_snapshot(body, config_number("station_id", 0), place)
      if not snap then return fail(perr or "Could not parse the feed") end
      snap.sig = sig

      -- two decimals: more precision makes the endpoint answer with a redirect
      get(string.format("%s?lat=%.2f&lon=%.2f", RAIN_URL, place.lat, place.lon), function(rain_body)
        if rain_body then
          snap.rain = parse_rain(rain_body)
        end
        snap.rain_expected = snap.rain ~= nil and snap.rain.expected == true
        last_error = nil
        busy = false
        noctalia.state.set(ERROR_KEY, "")
        noctalia.state.set(STATE_KEY, snap) -- triggers render() via watch below
      end)
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

-- A changed setting rebuilds this script: publish the new signature and draw the
-- cached snapshot again with the new units / bar text / place check.
noctalia.state.set(SIG_KEY, current_sig())
noctalia.state.watch(STATE_KEY, render)
noctalia.state.watch(REFRESH_KEY, function() refresh() end)
render(noctalia.state.get(STATE_KEY))
