local Prompt = require("99.prompt")
local make_prompt = require("99.ops.make-prompt")
local CleanUp = require("99.ops.clean-up")
local Agents = require("99.extensions.agents")
local Extensions = require("99.extensions")
local Range = require("99.geo").Range
local get_id = require("99.id")

local make_observer = CleanUp.make_observer

local INPUT_HEIGHT = 4
local SPINNER = {
  "_thinking_",
  "_thinking ·_",
  "_thinking ··_",
  "_thinking ···_",
}

--- @class _99.Discuss.Message
--- @field role "user" | "assistant"
--- @field content string

--- @class _99.Discuss.Selection
--- @field block string the fully rendered selection context for the prompt
--- @field label string short human label shown in the panel header

--- @class _99.Discuss.Session
--- @field state _99.State
--- @field messages _99.Discuss.Message[]
--- @field selection _99.Discuss.Selection | nil
--- @field file_path string
--- @field id number
--- @field busy boolean
--- @field closing boolean
--- @field note string | nil
--- @field pending string | nil
--- @field current_context _99.Prompt | nil
--- @field twin number | nil
--- @field tbuf number | nil
--- @field iwin number | nil
--- @field ibuf number | nil
--- @field timer any
local Session = {}
Session.__index = Session

local M = {}

--- @type _99.Discuss.Session | nil
M.__current = nil

--- @param state _99.State
--- @param selection _99.Discuss.Selection | nil
--- @param file_path string | nil
--- @param messages _99.Discuss.Message[] | nil
--- @return _99.Discuss.Session
function Session.new(state, selection, file_path, messages)
  local path = file_path
  if not path or path == "" then
    path = vim.api.nvim_buf_get_name(0)
  end
  return setmetatable({
    state = state,
    selection = selection,
    file_path = path,
    messages = messages or {},
    id = get_id(),
    busy = false,
    closing = false,
  }, Session)
end

--- @return boolean
function Session:panel_valid()
  return self.twin ~= nil
    and vim.api.nvim_win_is_valid(self.twin)
    and self.iwin ~= nil
    and vim.api.nvim_win_is_valid(self.iwin)
end

function Session:focus_input()
  if self.iwin and vim.api.nvim_win_is_valid(self.iwin) then
    vim.api.nvim_set_current_win(self.iwin)
    vim.cmd("startinsert")
  end
end

--- @return string
function Session:_header_label()
  if self.selection then
    return self.selection.label
  end
  local name = vim.fs.basename(self.file_path)
  if name == "" then
    name = "project"
  end
  return name
end

function Session:render()
  if not (self.tbuf and vim.api.nvim_buf_is_valid(self.tbuf)) then
    return
  end

  local lines = {}
  local function push(text)
    for _, l in ipairs(vim.split(text, "\n")) do
      table.insert(lines, l)
    end
  end

  push(string.format("# 99 Discuss — %s", self:_header_label()))
  if #self.messages == 0 and not self.pending then
    push("")
    push("_Ask anything about this code.  `<CR>`, `<C-s>` or `:w` in the")
    push("box below sends.  `#rule` and `@file` completions work here too._")
  end

  for _, msg in ipairs(self.messages) do
    push("")
    push(msg.role == "user" and "## You" or "## 99")
    push("")
    push(msg.content)
  end

  if self.pending then
    push("")
    push("## 99")
    push("")
    push(self.pending)
  end

  if self.note then
    push("")
    push("> " .. self.note)
  end

  vim.bo[self.tbuf].modifiable = true
  vim.api.nvim_buf_set_lines(self.tbuf, 0, -1, false, lines)
  vim.bo[self.tbuf].modifiable = false

  if self.twin and vim.api.nvim_win_is_valid(self.twin) then
    vim.wo[self.twin].winbar =
      string.format(" 99 Discuss · %s", self.state.model)
    vim.api.nvim_win_set_cursor(self.twin, { #lines, 0 })
  end
end

function Session:_stop_spinner()
  if self.timer then
    self.timer:stop()
    self.timer:close()
    self.timer = nil
  end
  self.pending = nil
end

function Session:_start_spinner()
  self:_stop_spinner()
  local frame = 0
  self.pending = SPINNER[1]
  self.timer = vim.uv.new_timer()
  self.timer:start(
    350,
    350,
    vim.schedule_wrap(function()
      if not self.timer then
        return
      end
      frame = frame + 1
      self.pending = SPINNER[(frame % #SPINNER) + 1]
      self:render()
    end)
  )
end

--- @return string
function Session:_system_prompt()
  local prompts = self.state.prompts.prompts
  local parts = { prompts.discuss() }

  if self.selection then
    table.insert(parts, self.selection.block)
  elseif self.file_path ~= "" then
    table.insert(
      parts,
      string.format(
        "<Location><File>%s</File></Location>\n"
          .. "The discussion started from this file. "
          .. "Read it for context if needed.",
        self.file_path
      )
    )
  end

  if #self.messages > 0 then
    local hist = { "<Conversation>" }
    for _, m in ipairs(self.messages) do
      local tag = m.role == "user" and "User" or "Assistant"
      table.insert(hist, string.format("<%s>\n%s\n</%s>", tag, m.content, tag))
    end
    table.insert(hist, "</Conversation>")
    table.insert(
      hist,
      "Continue this conversation by answering the new <Prompt>."
    )
    table.insert(parts, table.concat(hist, "\n"))
  end

  return table.concat(parts, "\n")
end

function Session:cancel()
  if self.current_context then
    self.current_context:cancel()
  end
end

--- @param text string
function Session:send(text)
  text = vim.trim(text or "")
  if text == "" then
    return
  end
  if self.busy then
    vim.notify(
      "[99] a discuss request is already in flight (<C-c> to cancel)",
      vim.log.levels.WARN
    )
    return
  end

  local state = self.state
  local context = Prompt.discuss(state)
  context.user_prompt = text
  context.full_path = self.file_path
  local logger = context.logger:set_area("discuss")

  local rules_and_names = Agents.by_name(state.rules, text)
  --- @type _99.ops.Opts
  local opts = {
    additional_prompt = text,
    additional_rules = rules_and_names.rules,
  }

  --- history must be built before the new message is appended
  local system = self:_system_prompt()
  local prompt, refs = make_prompt(context, system, opts)
  context:add_prompt_content(prompt)
  context:add_references(refs)

  table.insert(self.messages, { role = "user", content = text })
  self.note = nil
  self.busy = true
  self.current_context = context
  self:_start_spinner()
  self:render()

  context:start_request(make_observer(context, function(status, response)
    self.busy = false
    self.current_context = nil
    self:_stop_spinner()

    if status == "success" then
      local reply = vim.trim(response or "")
      if reply == "" then
        reply = "_the model returned an empty response_"
      end
      table.insert(self.messages, { role = "assistant", content = reply })
      context.data.response = reply
      context.data.messages = vim.deepcopy(self.messages)
      context.data.selection = self.selection
        and vim.deepcopy(self.selection)
        or nil
      context.data.file_path = self.file_path
    elseif status == "failed" then
      logger:error(
        "request failed for discuss",
        "error response",
        response or "no response provided"
      )
      self.note = "request failed — `:lua require('99').view_logs()`"
    elseif status == "cancelled" then
      logger:debug("request cancelled for discuss")
      self.note = "request cancelled"
    end
    self:render()
  end))
end

function Session:close()
  if self.closing then
    return
  end
  self.closing = true

  --- in flight requests are left running on purpose: the answer is
  --- appended to the session and shows up when the panel is reopened
  self:_stop_spinner()
  pcall(vim.api.nvim_del_augroup_by_name, "99_discuss_" .. self.id)

  for _, win in ipairs({ self.iwin, self.twin }) do
    if win and vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end
  self.twin, self.tbuf, self.iwin, self.ibuf = nil, nil, nil, nil
end

function Session:open_panel()
  if self:panel_valid() then
    self:focus_input()
    return
  end

  self.closing = false
  local group = vim.api.nvim_create_augroup(
    "99_discuss_" .. self.id,
    { clear = true }
  )

  --- transcript window
  vim.cmd("botright vsplit")
  self.twin = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_width(
    self.twin,
    math.max(50, math.floor(vim.o.columns * 0.38))
  )

  self.tbuf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(
    self.tbuf,
    string.format("99://discuss/%d", self.id)
  )
  vim.api.nvim_win_set_buf(self.twin, self.tbuf)
  vim.bo[self.tbuf].buftype = "nofile"
  vim.bo[self.tbuf].bufhidden = "wipe"
  vim.bo[self.tbuf].swapfile = false
  vim.bo[self.tbuf].filetype = "markdown"
  vim.bo[self.tbuf].modifiable = false

  local two = vim.wo[self.twin]
  two.wrap = true
  two.linebreak = true
  two.breakindent = true
  two.number = false
  two.relativenumber = false
  two.signcolumn = "no"
  two.spell = false

  --- input window
  vim.cmd("belowright " .. INPUT_HEIGHT .. "split")
  self.iwin = vim.api.nvim_get_current_win()
  self.ibuf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(
    self.ibuf,
    string.format("99://discuss/%d/input", self.id)
  )
  vim.api.nvim_win_set_buf(self.iwin, self.ibuf)
  vim.bo[self.ibuf].buftype = "acwrite"
  vim.bo[self.ibuf].bufhidden = "wipe"
  vim.bo[self.ibuf].swapfile = false

  local iwo = vim.wo[self.iwin]
  iwo.wrap = true
  iwo.number = false
  iwo.relativenumber = false
  iwo.signcolumn = "no"
  iwo.winbar = " prompt · <CR>/<C-s>/:w send · <C-c> cancel · q close"

  --- attach #rule and @file completions to the input buffer
  Extensions.setup_buffer(self.state)

  local function submit()
    if not (self.ibuf and vim.api.nvim_buf_is_valid(self.ibuf)) then
      return
    end
    local input_lines = vim.api.nvim_buf_get_lines(self.ibuf, 0, -1, false)
    local text = table.concat(input_lines, "\n")
    vim.api.nvim_buf_set_lines(self.ibuf, 0, -1, false, {})
    vim.bo[self.ibuf].modified = false
    vim.cmd("stopinsert")
    self:send(text)
  end

  local function close()
    self:close()
  end

  local function cancel()
    self:cancel()
  end

  local imap = { buffer = self.ibuf, nowait = true }
  vim.keymap.set("n", "<CR>", submit, imap)
  vim.keymap.set({ "n", "i" }, "<C-s>", submit, { buffer = self.ibuf })
  vim.keymap.set("n", "q", close, imap)
  vim.keymap.set("n", "<C-c>", cancel, { buffer = self.ibuf })

  local tmap = { buffer = self.tbuf, nowait = true }
  vim.keymap.set("n", "q", close, tmap)
  vim.keymap.set("n", "<C-c>", cancel, { buffer = self.tbuf })
  for _, key in ipairs({ "i", "a", "o", "<CR>" }) do
    vim.keymap.set("n", key, function()
      self:focus_input()
    end, tmap)
  end

  vim.api.nvim_create_autocmd("BufWriteCmd", {
    group = group,
    buffer = self.ibuf,
    callback = submit,
  })

  vim.api.nvim_create_autocmd("WinClosed", {
    group = group,
    pattern = { tostring(self.twin), tostring(self.iwin) },
    callback = function()
      vim.schedule(function()
        self:close()
      end)
    end,
  })

  self:render()
  self:focus_input()
end

--- @param state _99.State
--- @return _99.Discuss.Selection, string
local function capture_selection(state)
  --- the marks used by visual selection are only set once visual
  --- mode has been left
  vim.api.nvim_feedkeys(
    vim.api.nvim_replace_termcodes("<Esc>", true, false, true),
    "x",
    false
  )
  local range = Range.from_visual_selection()
  local full_path = vim.api.nvim_buf_get_name(0)
  local srow = range.start:to_vim()
  local erow = range.end_:to_vim()
  local name = vim.fs.basename(full_path)
  if name == "" then
    name = "[scratch]"
  end
  return {
    block = state.prompts.prompts.discuss_selection(full_path, range),
    label = string.format("%s:%d-%d", name, srow + 1, erow + 1),
  }, full_path
end

--- Opens (or toggles) the discuss side panel.
---
--- In visual mode this starts a NEW discussion about the current selection.
--- In normal mode it toggles the panel, resuming the previous conversation
--- if one exists, otherwise starting a discussion about the current file.
---
--- @param state _99.State
--- @param opts _99.ops.Opts | nil
function M.open(state, opts)
  opts = opts or {}
  local is_visual = vim.fn.mode():match("^[vV\22]") ~= nil

  if is_visual then
    local selection, full_path = capture_selection(state)
    if M.__current then
      M.__current:close()
    end
    local session = Session.new(state, selection, full_path)
    M.__current = session
    session:open_panel()
    if opts.additional_prompt then
      session:send(opts.additional_prompt)
    end
    return
  end

  local current = M.__current
  if current and current:panel_valid() then
    current:close()
    return
  end
  if not current then
    current = Session.new(state, nil, nil)
    M.__current = current
  end
  current:open_panel()
  if opts.additional_prompt then
    current:send(opts.additional_prompt)
  end
end

--- Rebuilds a session from a tracked (possibly deserialized) discuss
--- request and opens its panel.  The conversation can be continued.
---
--- @param state _99.State
--- @param context _99.Prompt
function M.resume(state, context)
  assert(
    context.data.type == "discuss",
    "cannot resume a non discuss request"
  )
  local data = context.data --[[@as _99.Prompt.Data.Discuss]]
  if M.__current then
    M.__current:close()
  end
  local session = Session.new(
    state,
    data.selection,
    data.file_path,
    vim.deepcopy(data.messages or {})
  )
  M.__current = session
  session:open_panel()
end

--- exposed for testing
M.__Session = Session

return M
