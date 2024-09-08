---@class CopilotChat.copilot.ask.opts
---@field selection string?
---@field filename string?
---@field filetype string?
---@field start_row number?
---@field end_row number?
---@field system_prompt string?
---@field model string?
---@field temperature number?
---@field on_done nil|fun(response: string, token_count: number?, token_count_in:number?):nil
---@field on_progress nil|fun(response: string):nil
---@field on_error nil|fun(err: string):nil
---@field use_selection boolean?
---@field limit number?
---@field use_general_ai boolean?
---@field url string|CopilotChat.config.prompt
---@field token string?

---@class CopilotChat.Copilot
---@field ask fun(self: CopilotChat.Copilot, prompt: string, opts: CopilotChat.copilot.ask.opts):nil
---@field stop fun(self: CopilotChat.Copilot):boolean
---@field reset fun(self: CopilotChat.Copilot):boolean
---@field save fun(self: CopilotChat.Copilot, name: string, path: string):nil
---@field load fun(self: CopilotChat.Copilot, name: string, path: string):table
---@field running fun(self: CopilotChat.Copilot):boolean

local log = require('plenary.log')
local curl = require('plenary.curl')
local utils = require('CopilotChat.utils')
local class = utils.class
local temp_file = utils.temp_file
local prompts = require('CopilotChat.prompts')
local tiktoken = require('CopilotChat.tiktoken')
local max_tokens = 8192

local function generate_selection_message(filename, filetype, start_row, end_row, selection)
  if not selection or selection == '' then
    return ''
  end

  local content = selection
  if start_row > 0 then
    local lines = vim.split(selection, '\n')
    local total_lines = #lines
    local max_length = #tostring(total_lines)
    for i, line in ipairs(lines) do
      local formatted_line_number = string.format('%' .. max_length .. 'd', i - 1 + start_row)
      lines[i] = formatted_line_number .. ': ' .. line
    end
    content = table.concat(lines, '\n')
  end

  return string.format('Active selection: `%s`\n```%s\n%s\n```', filename, filetype, content)
end

local function generate_ask_request(
  history,
  prompt,
  selection,
  system_prompt,
  model,
  temperature,
  use_selection
)
  local messages = {}

  if system_prompt ~= '' then
    table.insert(messages, {
      content = system_prompt,
      role = 'system',
    })
  end

  for _, message in ipairs(history) do
    table.insert(messages, message)
  end

  if selection ~= '' and use_selection then
    table.insert(messages, {
      content = selection,
      role = 'system',
    })
  end

  table.insert(messages, {
    content = prompt,
    role = 'user',
  })

  return {
    intent = true,
    model = model,
    n = 1,
    stream = true,
    temperature = temperature,
    top_p = 1,
    messages = messages,
  }
end

local Copilot = class(function(self, proxy, allow_insecure)
  self.proxy = proxy
  self.allow_insecure = allow_insecure
  self.history = {}
  self.token = nil
  self.token_count_in = 0
  self.token_count = 0
  self.sessionid = nil
  self.current_job = nil
end)

--- Ask a question to Copilot
---@param prompt string: The prompt to send to Copilot
---@param opts CopilotChat.copilot.ask.opts: Options for the request
function Copilot:ask(prompt, opts)
  opts = opts or {}
  local filename = opts.filename or ''
  local filetype = opts.filetype or ''
  local selection = opts.selection or ''
  local start_row = opts.start_row or 0
  local end_row = opts.end_row or 0
  local system_prompt = opts.system_prompt or prompts.COPILOT_INSTRUCTIONS
  local temperature = opts.temperature or 0.1
  local on_done = opts.on_done
  local on_progress = opts.on_progress
  local on_error = opts.on_error
  local token = opts.token
  local model = opts.model
  local limit = opts.limit

  self.token_count_in = self.token_count_in + self.token_count

  if opts.use_general_ai then
    system_prompt = 'You are a general AI. Please assist me with your capacity.'
  end

  -- If we already have running job, cancel it and notify the user
  if self.current_job then
    self:stop()
  end

  local selection_message =
    generate_selection_message(filename, filetype, start_row, end_row, selection)

  -- Count tokens

  local current_count = 0
  current_count = current_count + tiktoken.count(system_prompt)
  current_count = current_count + tiktoken.count(selection_message)
  current_count = current_count + tiktoken.count(prompt)

  local body = vim.json.encode(
    generate_ask_request(
      self.history,
      prompt,
      selection_message,
      system_prompt,
      model,
      temperature,
      opts.use_selection
    )
  )

  -- Add the prompt to history after we have encoded the request
  table.insert(self.history, {
    content = prompt,
    role = 'user',
  })

  local errored = false
  local full_response = ''

  local function run_chat()
    local headers = {
      ['Content-Type'] = 'application/json',
      ['Authorization'] = 'Bearer ' .. token,
    }
    local file = temp_file(body)
    self.current_job = curl
      .post(opts.url, {
        headers = headers,
        body = file,
        proxy = self.proxy,
        insecure = self.allow_insecure,
        on_error = function(err)
          err = 'Failed to get response: ' .. vim.inspect(err)
          log.error(err)
          if self.current_job and on_error then
            on_error(err)
          end
        end,
        stream = function(err, line)
          if not line or errored then
            return
          end

          if err or vim.startswith(line, '{"error"') then
            err = 'Failed to get response: ' .. (err and vim.inspect(err) or line)
            errored = true
            log.error(err)
            if self.current_job and on_error then
              on_error(err)
            end
            return
          end

          line = line:gsub('data: ', '')
          if line == '' then
            return
          elseif line == '[DONE]' then
            log.trace('Full response: ' .. full_response)
            self.token_count = self.token_count + tiktoken.count(full_response)

            if self.current_job and on_done then
              self.token_count_in = self.token_count_in + current_count
              on_done(full_response, self.token_count, self.token_count_in)
            end

            table.insert(self.history, {
              content = full_response,
              role = 'assistant',
            })
            if #self.history > limit then
              self.token_count_in = self.token_count_in - tiktoken.count(self.history[1]['content'])
              table.remove(self.history, 1)
              self.token_count_in = self.token_count_in - tiktoken.count(self.history[1]['content'])
              table.remove(self.history, 1)
            end

            local tmp_token = 0

            for i = 1, #self.history do
              tmp_token = tmp_token + tiktoken.count(self.history[i]['content'])
            end

            if tmp_token > max_tokens then
              self.token_count_in = self.token_count_in - tiktoken.count(self.history[1]['content'])
              table.remove(self.history, 1)
              self.token_count_in = self.token_count_in - tiktoken.count(self.history[1]['content'])
              table.remove(self.history, 1)
            end

            return
          end

          local ok, content = pcall(vim.json.decode, line, {
            luanil = {
              object = true,
              array = true,
            },
          })

          if not ok then
            if string.find(line, 'ping') == nil then
              err = 'Failed parse response: \n' .. line .. '\n' .. vim.inspect(content)
              log.error(err)
            end
            return
          end

          if not content.choices or #content.choices == 0 then
            return
          end

          content = content.choices[1].delta.content
          if not content then
            return
          end

          if self.current_job and on_progress then
            on_progress(content)
          end

          -- Collect full response incrementally so we can insert it to history later
          full_response = full_response .. content
        end,
      })
      :after(function()
        self.current_job = nil
      end)
  end
  run_chat()
end

--- Stop the running job
function Copilot:stop()
  if self.current_job then
    local job = self.current_job
    self.current_job = nil
    job:shutdown()
    return true
  end

  return false
end

--- Reset the history and stop any running job
function Copilot:reset()
  local stopped = self:stop()
  self.history = {}
  self.token_count_in = 0
  self.token_count = 0
  return stopped
end

--- Save the history to a file
---@param name string: The name to save the history to
---@param path string: The path to save the history to
function Copilot:save(name, path)
  local history = vim.json.encode(self.history)
  path = vim.fn.expand(path)
  vim.fn.mkdir(path, 'p')
  path = path .. '/' .. name .. '.json'
  local file = io.open(path, 'w')
  if not file then
    log.error('Failed to save history to ' .. path)
    return
  end

  file:write(history)
  file:close()
  log.info('Saved Copilot history to ' .. path)
end

--- Load the history from a file
---@param name string: The name to load the history from
---@param path string: The path to load the history from
---@return table
function Copilot:load(name, path)
  path = vim.fn.expand(path) .. '/' .. name .. '.json'
  local file = io.open(path, 'r')
  if not file then
    return {}
  end

  local history = file:read('*a')
  file:close()
  self.history = vim.json.decode(history, {
    luanil = {
      object = true,
      array = true,
    },
  })

  log.info('Loaded Copilot history from ' .. path)
  return self.history
end

--- Check if there is a running job
---@return boolean
function Copilot:running()
  return self.current_job ~= nil
end

return Copilot
