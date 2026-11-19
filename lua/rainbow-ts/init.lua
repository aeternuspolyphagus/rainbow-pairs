local M = {}

local defaults = {
  debounce = 80,
  priority = 200,
  colors = {
    "#E06C75", -- Red
    "#E5C07B", -- Yellow
    "#98C379", -- Green
    "#56B6C2", -- Cyan
    "#61AFEF", -- Blue
    "#C678DD", -- Purple
  },
}

local ns = vim.api.nvim_create_namespace("rainbow-ts")
local augroup = vim.api.nvim_create_augroup("RainbowTS", { clear = true })

local config = {}
local generations = {}

local delimiters = {
  ["("] = ")",
  ["["] = "]",
  ["{"] = "}",
}

local closing = {
  [")"] = "(",
  ["]"] = "[",
  ["}"] = "{",
}

local function define_highlights()
  for i, color in ipairs(config.colors) do
    vim.api.nvim_set_hl(0, "RainbowTS" .. i, {
      fg = color,
      default = true,
    })
  end
end

local function collect_leaves(node, tokens, seen)
  if node:child_count() == 0 then
    local kind = node:type()

    if delimiters[kind] or closing[kind] then
      local row, col = node:start()

      local key = row .. ":" .. col

      if not seen[key] then
        seen[key] = true

        tokens[#tokens + 1] = {
          char = kind,
          row = row,
          col = col,
        }
      end
    end

    return
  end

  for i = 0, node:child_count() - 1 do
    collect_leaves(node:child(i), tokens, seen)
  end
end

local function color_tokens(bufnr, tokens)
  table.sort(tokens, function(a, b)
    if a.row == b.row then
      return a.col < b.col
    end

    return a.row < b.row
  end)

  local stack = {}

  for _, token in ipairs(tokens) do
    local char = token.char
    local depth

    if delimiters[char] then
      depth = #stack + 1

      stack[#stack + 1] = {
        char = char,
        depth = depth,
      }
    else
      local expected = closing[char]
      local match

      for i = #stack, 1, -1 do
        if stack[i].char == expected then
          match = i
          break
        end
      end

      if match then
        depth = stack[match].depth

        for i = #stack, match, -1 do
          stack[i] = nil
        end
      else
        depth = #stack + 1
      end
    end

    local color = ((depth - 1) % #config.colors) + 1

    vim.api.nvim_buf_set_extmark(bufnr, ns, token.row, token.col, {
      end_row = token.row,
      end_col = token.col + 1,
      hl_group = "RainbowTS" .. color,
      priority = config.priority,
    })
  end
end

function M.refresh(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()

  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)

  local ok, parser = pcall(vim.treesitter.get_parser, bufnr)

  if not ok or not parser then
    return
  end

  local parsed = pcall(function()
    parser:parse()
  end)

  if not parsed then
    return
  end

  local tokens = {}
  local seen = {}

  local success = pcall(function()
    parser:for_each_tree(function(tree)
      collect_leaves(tree:root(), tokens, seen)
    end)
  end)

  if success then
    color_tokens(bufnr, tokens)
  end
end

local function schedule_refresh(bufnr)
  generations[bufnr] = (generations[bufnr] or 0) + 1

  local generation = generations[bufnr]

  vim.defer_fn(function()
    if generations[bufnr] ~= generation then
      return
    end

    if vim.api.nvim_buf_is_valid(bufnr) then
      M.refresh(bufnr)
    end
  end, config.debounce)
end

function M.setup(opts)
  config = vim.tbl_deep_extend("force", defaults, opts or {})

  define_highlights()

  vim.api.nvim_create_autocmd({
    "BufEnter",
    "FileType",
    "TextChanged",
    "TextChangedI",
    "InsertLeave",
  }, {
    group = augroup,
    callback = function(ev)
      schedule_refresh(ev.buf)
    end,
  })

  vim.api.nvim_create_autocmd("ColorScheme", {
    group = augroup,
    callback = define_highlights,
  })

  vim.api.nvim_create_autocmd("BufWipeout", {
    group = augroup,
    callback = function(ev)
      generations[ev.buf] = nil
    end,
  })

  schedule_refresh(vim.api.nvim_get_current_buf())
end

function M.clear(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()

  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
end

return M
