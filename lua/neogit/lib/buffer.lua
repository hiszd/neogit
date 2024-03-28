local api = vim.api
local fn = vim.fn

local mappings_manager = require("neogit.lib.mappings_manager")
local signs = require("neogit.lib.signs")
local Ui = require("neogit.lib.ui")

local Path = require("plenary.path")

---@class Buffer
---@field handle number
---@field win_handle number
---@field namespaces table
---@field mmanager MappingsManager
---@field ui Ui
---@field kind string
---@field disable_line_numbers boolean
local Buffer = {
  kind = "split",
  disable_line_numbers = true,
}
Buffer.__index = Buffer

---@param handle number
---@return Buffer
function Buffer:new(handle)
  local this = {
    handle = handle,
    border = nil,
    mmanager = mappings_manager.new(handle),
    kind = nil, -- how the buffer was opened. For more information look at the create function
    namespaces = {
      default = api.nvim_create_namespace("neogit-buffer-" .. handle),
    },
    line_buffer = {},
    hl_buffer = {},
    line_hl_buffer = {},
    ext_buffer = {},
    fold_buffer = {},
  }

  this.ui = Ui.new(this)

  setmetatable(this, self)

  return this
end

---@return number|nil
function Buffer:focus()
  local windows = fn.win_findbuf(self.handle)

  if not windows or not windows[1] then
    return nil
  end

  fn.win_gotoid(windows[1])
  return windows[1]
end

---@return boolean
function Buffer:is_focused()
  return api.nvim_win_get_buf(0) == self.handle
end

---@return number
function Buffer:get_changedtick()
  return api.nvim_buf_get_changedtick(self.handle)
end

function Buffer:lock()
  self:set_buffer_option("readonly", true)
  self:set_buffer_option("modifiable", false)
end

function Buffer:clear()
  api.nvim_buf_set_lines(self.handle, 0, -1, false, {})
end

---@return table
function Buffer:save_view()
  local view = fn.winsaveview()
  return {
    topline = view.topline,
    leftcol = 0,
  }
end

---@param view table output of Buffer:save_view()
---@param cursor? number
function Buffer:restore_view(view, cursor)
  if cursor then
    view.lnum = math.min(fn.line("$"), cursor)
  end

  fn.winrestview(view)
end

function Buffer:write()
  self:call(function()
    vim.cmd("silent w!")
  end)
end

function Buffer:get_lines(first, last, strict)
  return api.nvim_buf_get_lines(self.handle, first, last, strict or false)
end

function Buffer:get_line(line)
  return fn.getbufline(self.handle, line)
end

function Buffer:get_current_line()
  return self:get_line(fn.getpos(".")[2])
end

function Buffer:set_lines(first, last, strict, lines)
  api.nvim_buf_set_lines(self.handle, first, last, strict, lines)
end

function Buffer:insert_line(line)
  local line_nr = fn.line(".") - 1
  api.nvim_buf_set_lines(self.handle, line_nr, line_nr, false, { line })
end

function Buffer:buffered_set_line(line)
  table.insert(self.line_buffer, line)
end

function Buffer:buffered_add_highlight(...)
  table.insert(self.hl_buffer, { ... })
end

function Buffer:buffered_set_extmark(...)
  table.insert(self.ext_buffer, { ... })
end

function Buffer:buffered_create_fold(...)
  table.insert(self.fold_buffer, { ... })
end

function Buffer:buffered_add_line_highlight(...)
  table.insert(self.line_hl_buffer, { ... })
end

function Buffer:resize(length)
  api.nvim_buf_set_lines(self.handle, length or #self.line_buffer, -1, false, {})
end

function Buffer:flush_line_buffer()
  if self.line_buffer[1] then
    api.nvim_buf_set_lines(self.handle, 0, -1, false, self.line_buffer)
    self.line_buffer = {}
  end
end

function Buffer:flush_highlight_buffer()
  self:set_highlights(self.hl_buffer)
  self.hl_buffer = {}
end

function Buffer:set_highlights(highlights)
  for _, highlight in ipairs(highlights) do
    self:add_highlight(unpack(highlight))
  end
end

function Buffer:flush_extmark_buffer()
  self:set_extmarks(self.ext_buffer)
  self.ext_buffer = {}
end

function Buffer:set_extmarks(extmarks)
  for _, ext in ipairs(extmarks) do
    self:set_extmark(unpack(ext))
  end
end

function Buffer:flush_line_highlight_buffer()
  self:set_line_highlights(self.line_hl_buffer)
  self.line_hl_buffer = {}
end

function Buffer:set_line_highlights(highlights)
  for _, hl in ipairs(highlights) do
    self:add_line_highlight(unpack(hl))
  end
end

function Buffer:flush_fold_buffer()
  self:set_folds(self.fold_buffer)
  self.fold_buffer = {}
end

function Buffer:set_folds(folds)
  for _, fold in ipairs(folds) do
    self:create_fold(unpack(fold))
    self:set_fold_state(unpack(fold))
  end
end

function Buffer:flush_buffers()
  self:clear_namespace("default")
  self:flush_line_buffer()
  self:flush_highlight_buffer()
  self:flush_extmark_buffer()
  self:flush_line_highlight_buffer()
  self:flush_fold_buffer()
end

function Buffer:set_text(first_line, last_line, first_col, last_col, lines)
  api.nvim_buf_set_text(self.handle, first_line, first_col, last_line, last_col, lines)
end

function Buffer:move_cursor(line)
  pcall(api.nvim_win_set_cursor, 0, { line, 0 })
end

function Buffer:cursor_line()
  return api.nvim_win_get_cursor(0)[1]
end

function Buffer:close(force)
  if force == nil then
    force = false
  end

  if self.kind == "replace" then
    api.nvim_buf_delete(self.handle, { force = force })
    return
  end

  if self.kind == "tab" then
    vim.cmd("tabclose")
    return
  end

  if api.nvim_buf_is_valid(self.handle) then
    local winnr = fn.bufwinnr(self.handle)
    if winnr ~= -1 then
      local winid = fn.win_getid(winnr)
      local ok, _ = pcall(api.nvim_win_close, winid, force)
      if not ok then
        vim.cmd("b#")
      end
    else
      api.nvim_buf_delete(self.handle, { force = force })
    end
  end
end

function Buffer:hide()
  if not self:focus() then
    return
  end

  if self.kind == "tab" then
    -- `silent!` as this might throw errors if 'hidden' is disabled.
    vim.cmd("silent! 1only")
    vim.cmd("try | tabn # | catch /.*/ | tabp | endtry")
  elseif self.kind == "replace" then
    if self.old_buf and api.nvim_buf_is_loaded(self.old_buf) then
      api.nvim_set_current_buf(self.old_buf)
    end
  else
    api.nvim_win_close(0, true)
  end
end

function Buffer:is_visible()
  return #fn.win_findbuf(self.handle) > 0
end

---@return number
function Buffer:show()
  local windows = fn.win_findbuf(self.handle)

  -- Already visible
  if #windows > 0 then
    return windows[1]
  end

  if self.kind == "auto" then
    if vim.o.columns / 2 < 80 then
      self.kind = "split"
    else
      self.kind = "vsplit"
    end
  end

  local win
  local kind = self.kind

  if kind == "replace" then
    self.old_buf = api.nvim_get_current_buf()
    api.nvim_set_current_buf(self.handle)
    win = api.nvim_get_current_win()
  elseif kind == "tab" then
    vim.cmd("tab split")
    api.nvim_set_current_buf(self.handle)
    win = api.nvim_get_current_win()
  elseif kind == "split" then
    vim.cmd("below split")
    api.nvim_set_current_buf(self.handle)
    win = api.nvim_get_current_win()
  elseif kind == "split_above" then
    vim.cmd("top split")
    api.nvim_set_current_buf(self.handle)
    win = api.nvim_get_current_win()
  elseif kind == "vsplit" then
    vim.cmd("bot vsplit")
    api.nvim_set_current_buf(self.handle)
    win = api.nvim_get_current_win()
  elseif kind == "floating" then
    -- Creates the border window
    local vim_height = vim.o.lines
    local vim_width = vim.o.columns

    local width = math.floor(vim_width * 0.8) + 3
    local height = math.floor(vim_height * 0.7)
    local col = vim_width * 0.1 - 1
    local row = vim_height * 0.15

    local content_window = api.nvim_open_win(self.handle, true, {
      relative = "editor",
      width = width,
      height = height,
      col = col,
      row = row,
      style = "minimal",
      focusable = false,
      border = "single",
    })

    api.nvim_win_set_cursor(content_window, { 1, 0 })
    win = content_window
  end

  if self.disable_line_numbers then
    vim.cmd("setlocal nonu")
    vim.cmd("setlocal nornu")
  end

  -- Workaround UFO getting folds wrong.
  local ufo, _ = pcall(require, "ufo")
  if ufo then
    require("ufo").detach()
  end

  self.win_handle = win
  return win
end

function Buffer:is_valid()
  return api.nvim_buf_is_valid(self.handle)
end

function Buffer:put(lines, after, follow)
  self:focus()
  api.nvim_put(lines, "l", after, follow)
end

function Buffer:create_fold(first, last, _)
  vim.cmd(string.format("%d,%dfold", first, last))
end

function Buffer:set_fold_state(first, last, open)
  if open then
    vim.cmd(string.format("%d,%dfoldopen", first, last))
  else
    vim.cmd(string.format("%d,%dfoldclose", first, last))
  end
end

function Buffer:unlock()
  self:set_buffer_option("readonly", false)
  self:set_buffer_option("modifiable", true)
end

function Buffer:get_option(name)
  return api.nvim_get_option_value(name, { buf = self.handle })
end

function Buffer:set_buffer_option(name, value)
  api.nvim_set_option_value(name, value, { buf = self.handle })
end

function Buffer:set_window_option(name, value)
  api.nvim_set_option_value(name, value, { win = self.win_handle })
end

function Buffer:set_name(name)
  api.nvim_buf_set_name(self.handle, name)
end

function Buffer:replace_content_with(lines)
  api.nvim_buf_set_lines(self.handle, 0, -1, false, lines)
end

function Buffer:open_fold(line, reset_pos)
  local pos
  if reset_pos == true then
    pos = fn.getpos()
  end

  fn.setpos(".", { self.handle, line, 0, 0 })
  vim.cmd("normal zo")

  if reset_pos == true then
    fn.setpos(".", pos)
  end
end

function Buffer:add_highlight(line, col_start, col_end, name, namespace)
  local ns_id = self:get_namespace_id(namespace)
  if ns_id then
    api.nvim_buf_add_highlight(self.handle, ns_id, name, line, col_start, col_end)
  end
end

function Buffer:place_sign(line, name, opts)
  opts = opts or {}

  local ns_id = self:get_namespace_id(opts.namespace)
  if ns_id then
    api.nvim_buf_set_extmark(self.handle, ns_id, line - 1, 0, { sign_text = signs.get(name) })
  end
end

function Buffer:add_line_highlight(line, hl_group, opts)
  opts = opts or {}

  local ns_id = self:get_namespace_id(opts.namespace)
  if ns_id then
    api.nvim_buf_set_extmark(
      self.handle,
      ns_id,
      line,
      0,
      { line_hl_group = hl_group, priority = opts.priority or 190 }
    )
  end
end

function Buffer:clear_namespace(name)
  assert(name, "Cannot clear namespace without specifying which")

  if not self:is_focused() then
    return
  end

  local ns_id = self:get_namespace_id(name)
  if ns_id then
    api.nvim_buf_clear_namespace(self.handle, ns_id, 0, -1)
  end
end

function Buffer:create_namespace(name)
  assert(name, "Namespace must have a name")

  local namespace = "neogit-buffer-" .. self.handle .. "-" .. name
  if not self.namespaces[namespace] then
    self.namespaces[namespace] = api.nvim_create_namespace(namespace)
  end

  return self.namespaces[namespace]
end

---@param name string
---@return number|nil
function Buffer:get_namespace_id(name)
  local ns_id
  if name and name ~= "default" then
    ns_id = self.namespaces["neogit-buffer-" .. self.handle .. "-" .. name]
  else
    ns_id = self.namespaces.default
  end

  return ns_id
end

function Buffer:set_filetype(ft)
  self:set_buffer_option("filetype", ft)
end

function Buffer:call(f)
  api.nvim_buf_call(self.handle, f)
end

function Buffer:exists()
  return fn.bufnr(self.handle) ~= -1
end

function Buffer:set_extmark(...)
  return api.nvim_buf_set_extmark(self.handle, ...)
end

function Buffer:set_decorations(namespace, opts)
  local ns_id = self:get_namespace_id(namespace)
  if ns_id then
    return api.nvim_set_decoration_provider(ns_id, opts)
  end
end

function Buffer:set_header(text)
  -- Create a blank line at the top of the buffer so our floating window doesn't
  -- hide any content
  self:set_extmark(self:get_namespace_id("default"), 0, 0, {
    virt_lines = { { { "", "Comment" } } },
    virt_lines_above = true,
  })

  -- Create a new buffer with the header text
  local buf = api.nvim_create_buf(false, true)
  api.nvim_buf_set_lines(buf, 0, -1, false, { (" %s"):format(text) })
  vim.bo[buf].undolevels = -1
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].modified = false

  -- Display the buffer in a floating window
  local winid = api.nvim_open_win(buf, false, {
    relative = "win",
    width = vim.o.columns,
    height = 1,
    row = 0,
    col = 0,
    focusable = false,
    style = "minimal",
    noautocmd = true,
  })
  vim.wo[winid].wrap = false
  vim.wo[winid].winhl = "NormalFloat:NeogitFloatHeader"

  fn.matchadd("NeogitFloatHeaderHighlight", [[\v\<cr\>|\<esc\>]], 100, -1, { window = winid })

  -- Scroll the buffer viewport to the top so the header is visible
  self:call(function()
    api.nvim_input("<PageUp>")
  end)
end

---@class BufferConfig
---@field name string
---@field load boolean
---@field bufhidden string|nil
---@field buftype string|nil
---@field swapfile boolean
---@field filetype string|nil
---@field disable_line_numbers boolean|nil
---@return Buffer
function Buffer.create(config)
  config = config or {}
  local kind = config.kind or "split"
  local disable_line_numbers = (config.disable_line_numbers == nil) and true or config.disable_line_numbers
  --- This reuses a buffer with the same name
  local buffer = fn.bufnr(config.name)

  if buffer == -1 then
    buffer = api.nvim_create_buf(false, false)
    api.nvim_buf_set_name(buffer, config.name)
  end

  if config.load then
    local content = Path:new(config.name):readlines()
    api.nvim_buf_set_lines(buffer, 0, -1, false, content)
    api.nvim_buf_call(buffer, function()
      vim.cmd("silent w!")
    end)
  end

  local buffer = Buffer:new(buffer)
  buffer.kind = kind
  buffer.disable_line_numbers = disable_line_numbers

  local win
  if config.open ~= false then
    win = buffer:show()
  end

  buffer:set_buffer_option("bufhidden", config.bufhidden or "wipe")
  buffer:set_buffer_option("buftype", config.buftype or "nofile")
  buffer:set_buffer_option("swapfile", false)

  if win then
    buffer:set_window_option("statuscolumn", config.status_column or "")
    buffer:set_window_option("foldenable", true)
    buffer:set_window_option("foldlevel", 99)
    buffer:set_window_option("foldminlines", 0)
    buffer:set_window_option("foldtext", "")
  end

  if config.filetype then
    buffer:set_filetype(config.filetype)
  end

  if config.mappings then
    for mode, val in pairs(config.mappings) do
      for key, cb in pairs(val) do
        if type(key) == "string" then
          buffer.mmanager.mappings[mode][key] = function()
            cb(buffer)
          end
        elseif type(key) == "table" then
          for _, k in ipairs(key) do
            buffer.mmanager.mappings[mode][k] = function()
              cb(buffer)
            end
          end
        end
      end
    end
  end

  if config.initialize then
    config.initialize(buffer, win)
  end

  if config.render then
    buffer.ui:render(unpack(config.render(buffer)))
  end

  local neogit_augroup = require("neogit").autocmd_group
  for event, callback in pairs(config.autocmds or {}) do
    api.nvim_create_autocmd(event, { callback = callback, buffer = buffer.handle, group = neogit_augroup })
  end

  buffer.mmanager.register()

  buffer:set_buffer_option("modifiable", config.modifiable or false)
  buffer:set_buffer_option("modified", config.modifiable or false)
  buffer:set_buffer_option("readonly", config.readonly or false)

  if vim.fn.has("nvim-0.10") == 1 then
    buffer:set_window_option("spell", false)
    buffer:set_window_option("wrap", false)
    buffer:set_window_option("foldmethod", "manual")

    -- TODO: Need to find a way to turn this off properly when unloading plugin
    -- buffer:set_window_option("winfixbuf", true)
  else
    -- selene: allow(global_usage)
    _G.NeogitFoldText = function()
      return vim.fn.getline(vim.v.foldstart)
    end

    buffer:set_buffer_option("foldtext", "v:lua._G.NeogitFoldText()")
  end

  if config.after then
    buffer:call(function()
      config.after(buffer, win)
    end)
  end

  buffer:call(function()
    -- Set fold styling for Neogit windows while preserving user styling
    vim.opt_local.winhl:append("Folded:NeogitFold")
    vim.opt_local.fillchars:append("fold: ")

    -- Set signcolumn unless disabled by user settings
    if not config.disable_signs then
      vim.opt_local.signcolumn = "auto"
    end
  end)

  if config.context_highlight then
    buffer:create_namespace("ViewContext")
    buffer:set_decorations("ViewContext", {
      on_start = function()
        return buffer:exists() and buffer:is_focused()
      end,
      on_win = function()
        buffer:clear_namespace("ViewContext")

        local context = buffer.ui:get_cursor_context()
        if not context then
          return
        end

        local cursor = vim.fn.line(".")
        for line = context.position.row_start, context.position.row_end do
          local line_hl = ("%s%s"):format(
            buffer.ui:get_line_highlight(line) or "NeogitDiffContext",
            line == cursor and "Cursor" or "Highlight"
          )

          buffer:buffered_add_line_highlight(line - 1, line_hl, {
            priority = 200,
            namespace = "ViewContext",
          })
        end

        buffer:flush_line_highlight_buffer()
      end,
    })
  end

  if config.header then
    buffer:set_header(config.header)
  end

  return buffer
end

return Buffer
