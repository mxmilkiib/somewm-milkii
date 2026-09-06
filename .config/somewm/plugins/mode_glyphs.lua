-- mode_glyphs.lua
-- stable mode glyphs for tasklist items
-- comments are laconic; lower-case per style

local gears = require("gears")
local beautiful = require("beautiful")
local guarded = require("error_guard")

local M = {
  style = "basic" -- "basic" (gold markup) or "shimmer" (plain text; allow external styling)
}

-- weak map: client -> { list of prefix widgets }
local prefix_widgets = setmetatable({}, { __mode = "k" })

local function get_prefix(c)
  if not c or not c.valid then return "" end
  local symbols = {}
  if c.floating then table.insert(symbols, "✈") end
  if c.maximized then
    table.insert(symbols, "+")
  elseif c.maximized_horizontal then
    table.insert(symbols, "⬌")
  elseif c.maximized_vertical then
    table.insert(symbols, "⬍")
  end
  if c.sticky then table.insert(symbols, "▪") end
  if c.ontop then
    table.insert(symbols, "⌃")
  elseif c.above then
    table.insert(symbols, "▴")
  elseif c.below then
    table.insert(symbols, "▾")
  end
  local s = table.concat(symbols, "")
  if #s > 0 then return s end
  return ""
end

local function set_widget_for_client(pb, c)
  if not pb or not pb.set_markup or not c or not c.valid then return end
  local fg = (beautiful and beautiful.glyph_prefix_fg) or "#FFD700"
  local text = get_prefix(c)
  if M.style == "basic" then
    if #text > 0 then
      pb:set_markup(string.format('<span color="%s">%s</span>', fg, text))
    else
      pb:set_markup("")
    end
  else
    -- shimmer style: leave plain text; effect/colour applied externally
    if pb.set_text then
      pb:set_text(text)
    else
      pb:set_markup(text)
    end
  end
end

local function update_all_for_client(c)
  local list = prefix_widgets[c]
  if not list then return end
  -- prune dead widgets opportunistically
  local alive = {}
  for i, pb in ipairs(list) do
    if pb and pb.set_markup then
      set_widget_for_client(pb, c)
      table.insert(alive, pb)
    end
  end
  prefix_widgets[c] = alive
end

local function widget_already_registered(list, pb)
  if not list then return false end
  for _, w in ipairs(list) do
    if w == pb then return true end
  end
  return false
end

local function ensure_client_signals(c)
  if c._mode_glyphs_connected then return end
  c._mode_glyphs_connected = true

  local function deferred_update()
    local cc = c
    gears.timer.delayed_call(guarded(function()
      if cc and cc.valid then update_all_for_client(cc) end
    end))
  end

  local guarded_update = guarded(deferred_update)
  c:connect_signal("property::floating", guarded_update)
  c:connect_signal("property::maximized", guarded_update)
  c:connect_signal("property::maximized_horizontal", guarded_update)
  c:connect_signal("property::maximized_vertical", guarded_update)
  c:connect_signal("property::sticky", guarded_update)
  c:connect_signal("property::ontop", guarded_update)
  c:connect_signal("property::above", guarded_update)
  c:connect_signal("property::below", guarded_update)
  c:connect_signal("property::fullscreen", guarded_update)

  -- somewm 2.0: "unmanage" renamed to "request::unmanage"
  c:connect_signal("request::unmanage", guarded(function(cl)
    prefix_widgets[cl] = nil
  end))
end

function M.apply(task_item_widget, c)
  if not task_item_widget or not c or not c.valid then return end
  local pb = task_item_widget:get_children_by_id('status_prefix')[1]
  if not pb then return end

  ensure_client_signals(c)

  -- register widget for this client
  if not prefix_widgets[c] then prefix_widgets[c] = {} end
  if not widget_already_registered(prefix_widgets[c], pb) then
    table.insert(prefix_widgets[c], pb)
  end

  set_widget_for_client(pb, c)
end

-- refresh a single task item without registering again
function M.update(task_item_widget, c)
  if not task_item_widget or not c or not c.valid then return end
  local pb = task_item_widget:get_children_by_id('status_prefix')[1]
  if not pb then return end
  set_widget_for_client(pb, c)
end

function M.configure(opts)
  opts = opts or {}
  if opts.style == "basic" or opts.style == "shimmer" then
    M.style = opts.style
    -- refresh all widgets for all clients
    for c, _ in pairs(prefix_widgets) do
      if c and c.valid then update_all_for_client(c) end
    end
  end
end

return M
