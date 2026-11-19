local M = {}

local defaults = {
	priority = 200,
	debounce = 80,

	skip_strings = true,
	skip_comments = true,

	colors = {
		"#E06C75", -- Red
		"#E5C07B", -- Yellow
		"#98C379", -- Green
		"#56B6C2", -- Cyan
		"#61AFEF", -- Blue
		"#C678DD", -- Purple
	},
}

local namespace = vim.api.nvim_create_namespace("RainbowPairs")
local group = vim.api.nvim_create_augroup("RainbowPairs", { clear = true })

local config = {}
local timers = {}
local enabled = {}

local function get_pairs(bufnr)
	local value = vim.api.nvim_get_option_value("matchpairs", {
		buf = bufnr,
	})

	local open_to_close = {}
	local close_to_open = {}

	for _, pair in ipairs(vim.split(value, ",", { trimempty = true })) do
		if #pair >= 3 then
			local open = pair:sub(1, 1)
			local close = pair:sub(3, 3)

			open_to_close[open] = close
			close_to_open[close] = open
		end
	end

	return open_to_close, close_to_open
end

local function define_highlights()
	for i, color in ipairs(config.colors) do
		vim.api.nvim_set_hl(0, "RainbowPairs" .. i, {
			fg = color,
			default = true,
		})
	end
end

local function should_skip(bufnr, row, col)
	if not config.skip_strings and not config.skip_comments then
		return false
	end

	if vim.bo[bufnr].syntax == "" then
		return false
	end

	local id = vim.fn.synID(row + 1, col + 1, 0)
	local name = vim.fn.synIDattr(id, "name"):lower()

	if config.skip_strings then
		if name:find("string", 1, true) or name:find("character", 1, true) or name:find("heredoc", 1, true) then
			return true
		end
	end

	if config.skip_comments then
		if name:find("comment", 1, true) then
			return true
		end
	end

	return false
end

local function collect_pairs(bufnr)
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	local open_to_close, close_to_open = get_pairs(bufnr)

	local stack = {}
	local pairs = {}

	for row, line in ipairs(lines) do
		local col = 0

		while col < #line do
			local char = line:sub(col + 1, col + 1)

			if open_to_close[char] or close_to_open[char] then
				if not should_skip(bufnr, row - 1, col) then
					if open_to_close[char] then
						stack[#stack + 1] = {
							char = char,
							row = row - 1,
							col = col,
							depth = #stack + 1,
						}
					end
				elseif close_to_open[char] then
					local expected = close_to_open[char]
					local match

					for i = #stack, 1, -1 do
						if stack[i].char == expected then
							match = i
							break
						end
					end

					if match then
						local opening = stack[match]

						pairs[#pairs + 1] = {
							open = opening,
							close = {
								row = row - 1,
								col = col,
							},
							depth = opening.depth,
						}

						for i = #stack, match, -1 do
							stack[i] = nil
						end
					end
				end
			end

			col = col + 1
		end
	end

	return pairs
end

local function render(bufnr)
	if not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end

	if not enabled[bufnr] then
		return
	end

	vim.api.nvim_buf_clear_namespace(bufnr, namespace, 0, -1)

	local pairs = collect_pairs(bufnr)
	local color_count = #config.colors

	if color_count == 0 then
		return
	end

	for _, pair in ipairs(pairs) do
		local color = ((pair.depth - 1) % color_count) + 1
		local hl_group = "RainbowPairs" .. color

		for _, position in ipairs({ pair.open, pair.close }) do
			vim.api.nvim_buf_set_extmark(bufnr, namespace, position.row, position.col, {
				end_row = position.row,
				end_col = position.col + 1,
				hl_group = hl_group,
				priority = config.priority,
			})
		end
	end
end

function M.refresh(bufnr)
	bufnr = bufnr or vim.api.nvim_get_current_buf()

	render(bufnr)
end

local function schedule_refresh(bufnr)
	if not enabled[bufnr] then
		return
	end

	if timers[bufnr] then
		timers[bufnr]:stop()
		timers[bufnr]:close()
	end

	timers[bufnr] = vim.defer_fn(function()
		timers[bufnr] = nil

		if vim.api.nvim_buf_is_valid(bufnr) then
			render(bufnr)
		end
	end, config.debounce)
end

function M.enable(bufnr)
	bufnr = bufnr or vim.api.nvim_get_current_buf()

	enabled[bufnr] = true
	render(bufnr)
end

function M.disable(bufnr)
	bufnr = bufnr or vim.api.nvim_get_current_buf()

	enabled[bufnr] = false
	vim.api.nvim_buf_clear_namespace(bufnr, namespace, 0, -1)
end

function M.toggle(bufnr)
	bufnr = bufnr or vim.api.nvim_get_current_buf()

	if enabled[bufnr] then
		M.disable(bufnr)
	else
		M.enable(bufnr)
	end
end

function M.setup(opts)
	config = vim.tbl_deep_extend("force", defaults, opts or {})

	define_highlights()

	vim.api.nvim_create_autocmd({
		"BufEnter",
		"TextChanged",
		"TextChangedI",
		"InsertLeave",
	}, {
		group = group,
		callback = function(ev)
			if enabled[ev.buf] == nil then
				enabled[ev.buf] = true
			end

			schedule_refresh(ev.buf)
		end,
	})

	vim.api.nvim_create_autocmd("ColorScheme", {
		group = group,
		callback = function()
			define_highlights()

			for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
				if enabled[bufnr] then
					schedule_refresh(bufnr)
				end
			end
		end,
	})

	vim.api.nvim_create_autocmd("BufWipeout", {
		group = group,
		callback = function(ev)
			enabled[ev.buf] = nil

			if timers[ev.buf] then
				timers[ev.buf]:stop()
				timers[ev.buf]:close()
				timers[ev.buf] = nil
			end
		end,
	})

	vim.api.nvim_create_user_command("RainbowPairsToggle", function()
		M.toggle()
	end, {})

	vim.api.nvim_create_user_command("RainbowPairsEnable", function()
		M.enable()
	end, {})

	vim.api.nvim_create_user_command("RainbowPairsDisable", function()
		M.disable()
	end, {})

	vim.api.nvim_create_user_command("RainbowPairsRefresh", function()
		M.refresh()
	end, {})

	local bufnr = vim.api.nvim_get_current_buf()
	enabled[bufnr] = true
	schedule_refresh(bufnr)
end

return M
