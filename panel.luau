-- Buienradar forecast panel.
--
-- Pure presentation: widget.luau fetches and publishes the snapshot to plugin
-- state, this file only renders it.

local STATE_KEY = "buienradar"
local REFRESH_KEY = "buienradar.refresh"

local DEFAULT_URL = "https://www.buienradar.nl"
local MUTED = "on_surface/0.6"

local is_open = false

local function stat(glyph, value, caption)
  return ui.column({ gap = 2, align = "center", flexGrow = 1 }, {
    ui.glyph({ name = glyph, size = 18, color = "primary" }),
    ui.label({ text = value, fontSize = 13, fontWeight = "bold" }),
    ui.label({ text = caption, fontSize = 10, color = MUTED }),
  })
end

local function header(d)
  return ui.row({ gap = 12, align = "center" }, {
    ui.glyph({ name = d.glyph, size = 46, color = "primary" }),
    ui.column({ gap = 2, flexGrow = 1 }, {
      ui.row({ gap = 8, align = "center" }, {
        ui.label({ text = d.temp_text, fontSize = 30, fontWeight = "bold" }),
        ui.label({ text = "feels " .. d.feels_text, fontSize = 12, color = MUTED }),
      }),
      ui.label({ text = d.desc, fontSize = 12, color = MUTED, maxLines = 2 }),
      ui.row({ gap = 4, align = "center" }, {
        ui.glyph({ name = "map-pin", size = 12, color = MUTED }),
        ui.label({ text = "Station " .. d.station, fontSize = 11, color = MUTED }),
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
  if type(d) ~= "table" then
    panel.render(ui.column({ gap = 12, padding = 16, align = "center", justify = "center" }, {
      ui.glyph({ name = "cloud", size = 40, color = MUTED }),
      ui.label({ text = "Waiting for Buienradar...", fontSize = 13, color = MUTED }),
      ui.button({ text = "Close", variant = "outline", onClick = "onCloseClicked" }),
    }))
    return
  end

  local days = {}
  for _, day in ipairs(d.days or {}) do
    days[#days + 1] = day_row(day)
  end

  panel.render(ui.column({ gap = 14, padding = 16 }, {
    header(d),
    ui.row({ gap = 4 }, {
      stat("wind", d.wind_text, "wind"),
      stat("droplets", d.humidity_text, "humidity"),
      stat("gauge", d.pressure_text, "pressure"),
      stat("umbrella", d.rain_hour_text, "last hour"),
    }),
    ui.separator({}),
    rain_section(d),
    ui.separator({}),
    ui.column({ gap = 10 }, days),
    ui.row({ gap = 4, align = "center" }, {
      ui.label({ text = "Updated " .. d.updated, fontSize = 10, color = MUTED, flexGrow = 1 }),
      ui.button({
        text = "buienradar.nl",
        glyph = "external-link",
        variant = "ghost",
        controlSize = "sm",
        tooltip = "Open in browser",
        onClick = "onOpenSiteClicked",
      }),
      ui.button({ glyph = "refresh", variant = "ghost", controlSize = "sm", tooltip = "Refresh", onClick = "onRefreshClicked" }),
    }),
  }))
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
  local url = noctalia.getConfig("page_url")
  if type(url) ~= "string" or url == "" then url = DEFAULT_URL end
  noctalia.runAsync({ "xdg-open", url })
  panel.close()
end

function onRefreshClicked()
  noctalia.state.set(REFRESH_KEY, noctalia.nowMs())
end

noctalia.state.watch(STATE_KEY, function() render() end)
