-- mod-version:2 lite-xl 2.0
local core = require "core"
local keymap = require "core.keymap"
local command = require "core.command"
local common = require "core.common"
local config = require "core.config"
local style = require "core.style"
local View = require "core.view"

config.console_size = 250 * SCALE
config.max_console_lines = 200
config.autoscroll_console = true

local current_process = nil

local console = {}

local views = {}
local pending_threads = {}
local thread_active = false
local output = nil
local output_id = 0
local visible = false

function console.clear()
  output = { { text = "", time = 0 } }
end


local function lines(text)
  return (text .. "\n"):gmatch("(.-)\n")
end

local function split(str, sep)
	local t = {}
	for s in str:gmatch("([^"..sep.."]+)") do
		table.insert(t, s)
	end
	return t
end

local function push_output(str, opt)
  local first = true
  for line in lines(str) do
    if first then
      line = table.remove(output).text .. line
    end
    line = line:gsub("\x1b%[[%d;]+m", "") -- strip ANSI colors
    table.insert(output, {
      text = line,
      time = os.time(),
      icon = line:find(opt.error_pattern) and "!"
          or line:find(opt.warning_pattern) and "i",
      file_pattern = opt.file_pattern,
    })
    if #output > config.max_console_lines then
      table.remove(output, 1)
      for view in pairs(views) do
        view:on_line_removed()
      end
    end
    first = false
  end
  output_id = output_id + 1
  core.redraw = true
end


local function init_opt(opt)
  local res = {
    command = "",
    file_pattern = "[^?:%s]+%.[^?:%s]+",
    error_pattern = "error",
    warning_pattern = "warning",
    on_complete = function() end,
  }
  for k, v in pairs(res) do
    res[k] = opt[k] or v
  end
  return res
end


function console.run(opt)
  opt = init_opt(opt)

  local function thread()
    -- init process
    local cmd = split(opt.command, "(.-)%s")
		current_process = process.start(cmd)
    coroutine.yield(0.1)

    -- checks output file for change and reads
    local last_size = 0
    local function check_output()
			if current_process == nil then return end
			local text = current_process:read_stdout()
      if text and text:len() > last_size then
        push_output(text, opt)
        last_size = text:len()
      end
    end

    -- read output file until we get a file indicating completion
    while current_process ~= nil and current_process:running() do
      check_output()
      coroutine.yield(0.1)
    end

    check_output()

    if output[#output].text ~= "" then
      push_output("\n", opt)
    end
    push_output("!DIVIDER\n", opt)

    opt.on_complete()

    -- handle pending thread
    local pending = table.remove(pending_threads, 1)
    if pending then
      core.add_thread(pending)
    else
      thread_active = false
    end
  end

  -- push/init thread
  if thread_active then
    table.insert(pending_threads, thread)
  else
    core.add_thread(thread)
    thread_active = true
  end

  -- make sure static console is visible if it's the only ConsoleView
  local count = 0
  for _ in pairs(views) do count = count + 1 end
  if count == 1 then visible = true end
end



local ConsoleView = View:extend()

function ConsoleView:new()
  ConsoleView.super.new(self)
  self.target_size = config.console_size
  self.scrollable = true
  self.hovered_idx = -1
  views[self] = true
end


function ConsoleView:set_target_size(axis, value)
  if axis == "y" then
    self.target_size = value
    return true
  end
end


function ConsoleView:try_close(...)
  ConsoleView.super.try_close(self, ...)
  views[self] = nil
end


function ConsoleView:get_name()
  return "Console"
end


function ConsoleView:get_line_height()
  return style.code_font:get_height() * config.line_height
end


function ConsoleView:get_line_count()
  return #output - (output[#output].text == "" and 1 or 0)
end


function ConsoleView:get_scrollable_size()
  return self:get_line_count() * self:get_line_height() + style.padding.y * 2
end


function ConsoleView:get_visible_line_range()
  local lh = self:get_line_height()
  local min = math.max(1, math.floor(self.scroll.y / lh))
  return min, min + math.floor(self.size.y / lh) + 1
end


function ConsoleView:on_mouse_moved(mx, my, ...)
  ConsoleView.super.on_mouse_moved(self, mx, my, ...)
  self.hovered_idx = 0
  for i, item, x,y,w,h in self:each_visible_line() do
    if mx >= x and my >= y and mx < x + w and my < y + h then
      if item.text:find(item.file_pattern) then
        self.hovered_idx = i
      end
      break
    end
  end
end


local function resolve_file(name)
  if system.get_file_info(name) then
    return name
  end
  local filenames = {}
  for _, f in ipairs(core.project_files) do
    table.insert(filenames, f.filename)
  end
  local t = common.fuzzy_match(filenames, name)
  return t[1]
end


function ConsoleView:on_line_removed()
  local diff = self:get_line_height()
  self.scroll.y = self.scroll.y - diff
  self.scroll.to.y = self.scroll.to.y - diff
end


function ConsoleView:on_mouse_pressed(...)
  local caught = ConsoleView.super.on_mouse_pressed(self, ...)
  if caught then
    return
  end
  local item = output[self.hovered_idx]
  if item then
    local file, line, col = item.text:match(item.file_pattern)
    local resolved_file = resolve_file(file)
    if not resolved_file then
      core.error("Couldn't resolve file \"%s\"", file)
      return
    end
    core.try(function()
      core.set_active_view(core.last_active_view)
      local dv = core.root_view:open_doc(core.open_doc(resolved_file))
      if line then
        dv.doc:set_selection(line, col or 0)
        dv:scroll_to_line(line, false, true)
      end
    end)
  end
end


function ConsoleView:each_visible_line()
  return coroutine.wrap(function()
    local x, y = self:get_content_offset()
    local lh = self:get_line_height()
    local min, max = self:get_visible_line_range()
    y = y + lh * (min - 1) + style.padding.y
    max = math.min(max, self:get_line_count())

    for i = min, max do
      local item = output[i]
      if not item then break end
      coroutine.yield(i, item, x, y, self.size.x, lh)
      y = y + lh
    end
  end)
end


function ConsoleView:update(...)
  if self.last_output_id ~= output_id then
    if config.autoscroll_console then
      self.scroll.to.y = self:get_scrollable_size()
    end
    self.last_output_id = output_id
  end
  ConsoleView.super.update(self, ...)
end


function ConsoleView:draw()
  self:draw_background(style.background)
  local icon_w = style.icon_font:get_width("!")

  for i, item, x, y, w, h in self:each_visible_line() do
    local tx = x + style.padding.x
    local time = os.date("%H:%M:%S", item.time)
    local color = style.text
    if self.hovered_idx == i then
      color = style.accent
      renderer.draw_rect(x, y, w, h, style.line_highlight)
    end
    if item.text == "!DIVIDER" then
      local w = style.font:get_width(time)
      renderer.draw_rect(tx, y + h / 2, w, math.ceil(SCALE * 1), style.dim)
    else
      tx = common.draw_text(style.font, style.dim, time, "left", tx, y, w, h)
      tx = tx + style.padding.x
      if item.icon then
        common.draw_text(style.icon_font, color, item.icon, "left", tx, y, w, h)
      end
      tx = tx + icon_w + style.padding.x
      common.draw_text(style.code_font, color, item.text, "left", tx, y, w, h)
    end
  end

  self:draw_scrollbar(self)
end

-- init static bottom-of-screen console
local view = ConsoleView()
local node = core.root_view:get_active_node()
node:split("down", view, {y = true}, true)

function view:update(...)
  local dest = visible and self.target_size or 0
  self:move_towards(self.size, "y", dest)
  ConsoleView.update(self, ...)
end


local last_command = ""

command.add(nil, {
  ["console:reset-output"] = function()
    output = { { text = "", time = 0 } }
  end,

  ["console:open-console"] = function()
    local node = core.root_view:get_active_node()
    node:add_view(ConsoleView())
  end,

  ["console:toggle"] = function()
    visible = not visible
  end,

  ["console:run"] = function()
    core.command_view:set_text(last_command, true)
    core.command_view:enter("Run Console Command", function(cmd)
      console.run { command = cmd }
      last_command = cmd
    end)
  end
})

keymap.add {
  ["ctrl+."] = "console:toggle",
  ["ctrl+shift+."] = "console:run",
}

-- for `workspace` plugin:
package.loaded["plugins.console.view"] = ConsoleView

console.clear()
return console
