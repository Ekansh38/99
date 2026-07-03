-- luacheck: globals describe it assert before_each after_each
local _99 = require("99")
local test_utils = require("99.test.test_utils")
local discuss = require("99.ops.discuss")
local eq = assert.are.same

local content = {
  "local function foo()",
  "    return 42",
  "end",
}

describe("discuss", function()
  local provider

  before_each(function()
    if discuss.__current then
      discuss.__current:close()
      discuss.__current = nil
    end
    provider = test_utils.TestProvider.new()
    _99.setup(test_utils.get_test_setup_options({
      in_flight_options = { enable = false },
    }, provider))
    test_utils.create_file(content, "lua", 1, 0)
  end)

  after_each(function()
    if discuss.__current then
      discuss.__current:close()
      discuss.__current = nil
    end
    test_utils.clean_files()
  end)

  --- @param buf number
  --- @return string
  local function buf_text(buf)
    return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
  end

  it("runs a multi turn conversation without touching buffers", function()
    local state = _99.__get_state()
    discuss.open(state)

    local session = discuss.__current
    assert(session, "a session should have been created")
    assert(session:panel_valid(), "panel should be open")

    session:send("what does foo return")
    assert(provider.request, "provider should have received a request")

    local q1 = provider.request.query
    assert(
      q1:find("DISCUSSION", 1, true),
      "query must contain the discuss system prompt"
    )
    assert(
      q1:find("what does foo return", 1, true),
      "query must contain the user prompt"
    )
    assert(
      q1:find("<Conversation>", 1, true) == nil,
      "first turn must not contain history"
    )

    provider:resolve("success", "foo returns 42")
    test_utils.next_frame()

    eq(2, #session.messages)
    eq("assistant", session.messages[2].role)
    eq("foo returns 42", session.messages[2].content)
    assert(
      buf_text(session.tbuf):find("foo returns 42", 1, true),
      "reply must be rendered into the transcript"
    )

    session:send("why 42")
    local q2 = provider.request.query
    assert(
      q2:find("<Conversation>", 1, true),
      "second turn must contain history"
    )
    assert(
      q2:find("foo returns 42", 1, true),
      "history must contain the previous reply"
    )

    provider:resolve("success", "because the answer to everything")
    test_utils.next_frame()
    eq(4, #session.messages)
  end)

  it("tracks and serializes successful conversations", function()
    local state = _99.__get_state()
    discuss.open(state)
    local session = discuss.__current

    session:send("hello")
    provider:resolve("success", "hi there")
    test_utils.next_frame()

    local history = state.tracking.history
    local last = history[#history]
    eq("discuss", last.operation)
    eq("success", last.state)
    eq(2, #last.data.messages)

    local serialized = state.tracking:serialize()
    local found = false
    for _, r in ipairs(serialized.requests) do
      if r.data.type == "discuss" then
        found = true
        eq(2, #r.data.messages)
      end
    end
    assert(found, "discuss request must be serialized")
  end)

  it("toggles in normal mode and keeps the conversation", function()
    local state = _99.__get_state()
    discuss.open(state)
    local session = discuss.__current

    session:send("hello")
    provider:resolve("success", "hi")
    test_utils.next_frame()

    --- toggle closed
    discuss.open(state)
    assert(not session:panel_valid(), "panel should be closed")

    --- toggle open again: same conversation
    discuss.open(state)
    eq(session, discuss.__current)
    assert(session:panel_valid(), "panel should be open again")
    eq(2, #session.messages)
    assert(
      buf_text(session.tbuf):find("hi", 1, true),
      "previous reply must still be rendered"
    )
  end)

  it("does not yank the cursor to the bottom while scrolled up", function()
    local state = _99.__get_state()
    discuss.open(state)
    local session = discuss.__current

    session:send("hello")
    provider:resolve("success", "line one\nline two\nline three")
    test_utils.next_frame()

    --- user scrolls to the top of the transcript
    vim.api.nvim_win_set_cursor(session.twin, { 1, 0 })
    session:render()
    eq({ 1, 0 }, vim.api.nvim_win_get_cursor(session.twin))

    --- once back at the bottom, renders follow again
    local last = vim.api.nvim_buf_line_count(session.tbuf)
    vim.api.nvim_win_set_cursor(session.twin, { last, 0 })
    session:send("more")
    provider:resolve("success", "even more")
    test_utils.next_frame()
    last = vim.api.nvim_buf_line_count(session.tbuf)
    eq(last, vim.api.nvim_win_get_cursor(session.twin)[1])
  end)

  it("re-captures the live document state on every send", function()
    local state = _99.__get_state()
    local file = vim.fn.tempname() .. ".lua"
    vim.fn.writefile({ "local a = 1", "local b = 2", "local c = 3" }, file)

    local session = discuss.__Session.new(state, {
      block = "<SELECTION_CONTENT>local b = 2</SELECTION_CONTENT>",
      label = "test.lua:2-2",
      file = file,
      start_row = 2,
      end_row = 2,
    }, file)
    discuss.__current = session
    session:open_panel()

    session:send("what is b")
    local q1 = provider.request.query
    assert(
      q1:find("CURRENT_DOCUMENT_STATE", 1, true),
      "first turn must include the live document state"
    )
    assert(q1:find("local b = 2", 1, true), "must contain current content")
    provider:resolve("success", "b is 2")
    test_utils.next_frame()

    --- the user edits the file between messages
    vim.fn.writefile(
      { "local a = 1", "local b = 99", "local c = 3" },
      file
    )

    session:send("and now?")
    local q2 = provider.request.query
    assert(
      q2:find("local b = 99", 1, true),
      "second turn must see the edited file"
    )
    provider:resolve("success", "b is 99")
    test_utils.next_frame()

    vim.fn.delete(file)
  end)

  it("resumes a conversation from a tracked request", function()
    local state = _99.__get_state()
    discuss.open(state)
    local session = discuss.__current

    session:send("hello")
    provider:resolve("success", "hi")
    test_utils.next_frame()
    session:close()
    discuss.__current = nil

    local history = state.tracking.history
    local last = history[#history]
    discuss.resume(state, last)

    local resumed = discuss.__current
    assert(resumed, "a resumed session should exist")
    assert(resumed ~= session, "resume must create a fresh session")
    eq(2, #resumed.messages)

    resumed:send("continue")
    local q = provider.request.query
    assert(
      q:find("<Conversation>", 1, true),
      "resumed conversation must send history"
    )
    provider:resolve("success", "continuing")
    test_utils.next_frame()
    eq(4, #resumed.messages)
  end)
end)
