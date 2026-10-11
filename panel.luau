-- Buienradar forecast panel.
--
-- Pure presentation: widget.luau fetches and publishes the snapshot to plugin
-- state, this file only renders it.

local STATE_KEY = "buienradar"
local REFRESH_KEY = "buienradar.refresh"
local SIG_KEY = "buienradar.sig" -- signature of the widget's current settings
local ERROR_KEY = "buienradar.error" -- last error text, "" when fine

local DEFAULT_URL = "https://www.buienradar.nl"
local MUTED = "on_surface/0.6"
local FAR_STATION_KM = 60 -- from this distance the panel says how far the station is

local is_open = false

---------------------------------------------------------------------------
-- formatting from the snapshot's raw numbers (same rules as widget.luau)
---------------------------------------------------------------------------

local function round(x)
  return math.floor(x + 0.5)
end

local function trim(s)
  s = s:gsub("^%s+", "")
  s = s:gsub("%s+$", "")
  return s
end

local function degrees(v)
  if type(v) ~= "number" then return "-" end
  return string.format("%d°", round(v))
end

-- Dutch compass letters -> English (Z = zuid -> S, O = oost -> E).
local function compass(dir)
  if type(dir) ~= "string" then return "" end
  return (dir:upper():gsub("Z", "S"):gsub("O", "E"))
end

local function wind_unit()
  local unit = noctalia.getConfig("wind_unit")
  if unit == "ms" or unit == "kmh" then return unit end
  return "bft"
end

-- Snapshots with v == 2 carry raw numbers; older ones only have the texts.
local function temp_text(d)
  if d.v == 2 then return degrees(d.temp) end
  return d.temp_text
end

local function feels_text(d)
  if d.v == 2 then return degrees(d.feels) end
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

---------------------------------------------------------------------------
-- link to buienradar.nl
---------------------------------------------------------------------------

-- Lower case; every run of characters other than ASCII letters and digits becomes one hyphen.
local function slug(name)
  local s = tostring(name):lower()
  s = s:gsub("[^%w]+", "-")
  s = s:gsub("^%-+", "")
  s = s:gsub("%-+$", "")
  return s
end

-- A non-empty page_url wins; a place with a GeoNames id gets its city page (plus the
-- link parameters); anything else opens the home page.
local function page_link(d)
  local override = noctalia.getConfig("page_url")
  if type(override) == "string" and trim(override) ~= "" then return trim(override) end

  local place = type(d) == "table" and d.place or nil
  if type(place) ~= "table" or not place.geoid or not place.cc or not place.name then return DEFAULT_URL end

  local url = string.format("%s/weer/%s/%s/%d", DEFAULT_URL, slug(place.name), tostring(place.cc):lower(), place.geoid)
  local query = noctalia.getConfig("page_query")
  if type(query) == "string" and trim(query) ~= "" then url = url .. "?" .. trim(query) end
  return url
end

---------------------------------------------------------------------------
-- state checks
---------------------------------------------------------------------------

-- A snapshot built for other settings (another place or station) is not shown.
-- Snapshots without a signature (an older script) are.
local function snapshot_matches(d)
  local current = noctalia.state.get(SIG_KEY)
  return d.sig == nil or current == nil or d.sig == current
end

local function current_error()
  local err = noctalia.state.get(ERROR_KEY)
  if type(err) == "string" and err ~= "" then return err end
  return nil
end

local function error_row(text)
  return ui.row({ gap = 6, align = "center" }, {
    ui.glyph({ name = "alert-triangle", size = 14, color = "primary" }),
    ui.label({ text = text, fontSize = 11, color = MUTED, maxLines = 2, flexGrow = 1 }),
  })
end

---------------------------------------------------------------------------
-- layout
---------------------------------------------------------------------------

-- `grow` widens a tile: the wind text ("WSW 12.5 m/s") is longer than the others.
local function stat(glyph, value, caption, grow)
  return ui.column({ gap = 2, align = "center", flexGrow = grow or 1 }, {
    ui.glyph({ name = glyph, size = 18, color = "primary" }),
    ui.label({ text = value, fontSize = 13, fontWeight = "bold" }),
    ui.label({ text = caption, fontSize = 10, color = MUTED }),
  })
end

-- "Emmen, Drenthe - Station Hoogeveen", with the distance once the station is far away.
local function place_line(d)
  local text = "Station " .. d.station
  if type(d.place) == "table" and d.place.label then
    text = d.place.label .. " · " .. text
  end
  if type(d.station_km) == "number" and d.station_km > FAR_STATION_KM then
    text = text .. ", " .. d.station_km .. " km away"
  end
  return text
end

local function header(d)
  return ui.row({ gap = 12, align = "center" }, {
    ui.glyph({ name = d.glyph, size = 46, color = "primary" }),
    ui.column({ gap = 2, flexGrow = 1 }, {
      ui.row({ gap = 8, align = "center" }, {
        ui.label({ text = temp_text(d), fontSize = 30, fontWeight = "bold" }),
        ui.label({ text = "feels " .. feels_text(d), fontSize = 12, color = MUTED }),
      }),
      ui.label({ text = d.desc, fontSize = 12, color = MUTED, maxLines = 2 }),
      ui.row({ gap = 4, align = "center" }, {
        ui.glyph({ name = "map-pin", size = 12, color = MUTED }),
        ui.label({ text = place_line(d), fontSize = 11, color = MUTED, maxLines = 2, flexGrow = 1 }),
      }),
    }),
    ui.button({ glyph = "x", variant = "ghost", controlSize = "sm", onClick = "onCloseClicked" }),
  })
end

local BAR_AREA_HEIGHT = 48

-- A bar counts as rain from 0.1 mm/h on: bar heights are sqrt(mm / 5), and this
-- is the same wet threshold widget.luau uses for the summary and the tooltips.
local WET_BAR = math.sqrt(0.1 / 5)

local MIN_NOW_BARS = 3 -- bars before the first tick needed to print "now"
local MIN_LABEL_BARS = 3 -- bars from a tick to the end of the chart needed to print its label
local TICK_WIDTH, TICK_HEIGHT = 1, 4

-- One bar per 5-minute step; ui.graph scales unpredictably, boxes do not.
-- `tips` (one text per bar) is optional: state from an older widget lacks it.
local function rain_bars(values, tips)
  local bars = {}
  for i, v in ipairs(values) do
    local wet = v >= WET_BAR - 1e-9 -- tolerance for float noise right at the threshold
    bars[#bars + 1] = ui.box({
      fill = wet and "primary" or "on_surface/0.2",
      radius = 2,
      height = math.max(2, math.floor(v * BAR_AREA_HEIGHT + 0.5)),
      flexGrow = 1,
      tooltip = type(tips) == "table" and tips[i] or nil,
    })
  end
  return ui.row({ gap = 2, align = "end", height = BAR_AREA_HEIGHT }, bars)
end

-- A tick mark with its (optional) label under it, left-aligned in a cell that is
-- as wide (flexGrow) as the number of bars it covers.
local function tick_cell(span, label)
  local children = { ui.box({ width = TICK_WIDTH, height = TICK_HEIGHT, fill = MUTED }) }
  if label then
    children[#children + 1] = ui.label({ text = label, fontSize = 10, color = MUTED })
  end
  return ui.column({ flexGrow = span, gap = 1, align = "start" }, children)
end

-- Half-hour scale under the bars. Cell widths are proportional to the number of
-- bars they cover, so a tick sits at the left edge of "its" bar to within the
-- 2 px bar gap, whatever the panel width is.
local function scale_row(rain, bar_count)
  local ticks = rain.ticks
  if type(ticks) ~= "table" or #ticks == 0 then return nil end

  local cells = {}
  local lead = ticks[1].index - 1
  if lead > 0 then
    cells[#cells + 1] = lead >= MIN_NOW_BARS and tick_cell(lead, "now") or ui.row({ flexGrow = lead }, {})
  end
  for k, tick in ipairs(ticks) do
    local following = ticks[k + 1]
    local span = (following and following.index or bar_count + 1) - tick.index
    local remaining = bar_count - tick.index + 1
    cells[#cells + 1] = tick_cell(span, remaining >= MIN_LABEL_BARS and tick.label or nil)
  end
  return ui.row({ gap = 0, align = "start" }, cells)
end

local function rain_section(d)
  if not d.rain then
    return ui.label({ text = "Rain outlook unavailable", fontSize = 12, color = MUTED })
  end
  local children = {
    ui.row({ align = "center", justify = "space_between" }, {
      ui.label({ text = d.rain.note, fontSize = 13, fontWeight = "bold" }),
      ui.label({ text = "next 2 h", fontSize = 11, color = MUTED }),
    }),
    rain_bars(d.rain.values, d.rain.tips),
  }
  local scale = scale_row(d.rain, #d.rain.values)
  if scale then children[#children + 1] = scale end
  return ui.column({ gap = 6 }, children)
end

local function day_row(day)
  local rain = day.chance > 0 and (tostring(day.chance) .. "%") or ""
  return ui.row({ gap = 10, align = "center", tooltip = day.desc }, {
    ui.label({ text = day.label, fontSize = 13, fontWeight = "bold", width = 38 }),
    ui.glyph({ name = day.glyph, size = 22, color = "primary" }),
    ui.column({ flexGrow = 1, gap = 0 }, {
      ui.label({ text = day.min_text .. " / " .. day.max_text, fontSize = 13 }),
      day.mm_text ~= "" and ui.label({ text = day.mm_text, fontSize = 10, color = MUTED }) or ui.spacer({ height = 0 }),
    }),
    ui.glyph({ name = "droplet", size = 13, color = MUTED, visible = day.chance > 0 }),
    ui.label({ text = rain, fontSize = 12, color = MUTED, width = 36 }),
  })
end

local function render()
  if not is_open then return end

  local d = noctalia.state.get(STATE_KEY)
  local err = current_error()
  if type(d) ~= "table" or not snapshot_matches(d) then
    local waiting = {
      ui.glyph({ name = err and "cloud-off" or "cloud", size = 40, color = MUTED }),
      ui.label({ text = "Waiting for Buienradar...", fontSize = 13, color = MUTED }),
    }
    if err then waiting[#waiting + 1] = error_row(err) end
    waiting[#waiting + 1] = ui.button({ text = "Close", variant = "outline", onClick = "onCloseClicked" })
    panel.render(ui.column({ gap = 12, padding = 16, align = "center", justify = "center" }, waiting))
    return
  end

  local days = {}
  for _, day in ipairs(d.days or {}) do
    days[#days + 1] = day_row(day)
  end

  local children = {
    header(d),
    ui.row({ gap = 4 }, {
      stat("wind", wind_text(d, wind_unit()), "wind", 1.6),
      stat("droplets", d.humidity_text, "humidity"),
      stat("gauge", d.pressure_text, "pressure"),
      stat("umbrella", d.rain_hour_text, "last hour"),
    }),
    ui.separator({}),
    rain_section(d),
    ui.separator({}),
    ui.column({ gap = 8 }, days),
  }
  if err then children[#children + 1] = error_row(err) end

  children[#children + 1] = ui.row({ gap = 4, align = "center" }, {
    ui.label({ text = "Updated " .. d.updated .. (err and " (stale)" or ""), fontSize = 10, color = MUTED, flexGrow = 1 }),
    ui.button({
      text = "buienradar.nl",
      glyph = "external-link",
      variant = "ghost",
      controlSize = "sm",
      tooltip = "Open in browser",
      onClick = "onOpenSiteClicked",
    }),
    ui.button({ glyph = "refresh", variant = "ghost", controlSize = "sm", tooltip = "Refresh", onClick = "onRefreshClicked" }),
  })

  panel.render(ui.column({ gap = 12, padding = 16 }, children))
end

function onOpen(context)
  is_open = true
  render()
end

function onClose()
  is_open = false
end

function onCloseClicked()
  panel.close()
end

function onOpenSiteClicked()
  local d = noctalia.state.get(STATE_KEY)
  noctalia.runAsync({ "xdg-open", page_link(type(d) == "table" and d or nil) })
  panel.close()
end

function onRefreshClicked()
  noctalia.state.set(REFRESH_KEY, noctalia.nowMs())
end

-- Redraw on new data, on a failed refresh and when the widget switches to other settings.
noctalia.state.watch(STATE_KEY, function() render() end)
noctalia.state.watch(ERROR_KEY, function() render() end)
noctalia.state.watch(SIG_KEY, function() render() end)
