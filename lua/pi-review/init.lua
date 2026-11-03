-- pi-review.nvim — send review comments from nvim to pi.
--
-- Requires nvim to be running inside a pi-terminal session (passthrough or
-- overlay) of the pi-terminal extension, which exports $PI_TERMINAL_SOCK
-- (Unix socket to the enclosing pi session) and $PI_TERMINAL_CWD (pi's
-- working directory). Each comment is sent to pi's input box, where you can
-- edit and send it; an immediate-send option submits straight to the model.

local M = {}

---@class PiReviewOpts
---@field add_mode "pi-input"|"queue" Where comments accumulate: appended to Pi's input box as you add them (default), or queued in nvim
---@field send_mode "input"|"submit" Queue-mode flush: place the batch in Pi's input box (default) or submit it
---@field include_symbol boolean Append "(symbol `word`)"
---@field include_line_text boolean Append "line: `text`" (single-cursor items)
---@field include_col boolean Include the column in the location
---@field single_prefix string Prefix for immediate sends
---@field batch_header string Batch header; "{count}" is replaced with the item count
---@field item_template string|nil Full format override for single-cursor items
---@field item_template_range string|nil Full format override for visual selections
---@field create_keymaps boolean Create default <leader> keymaps (default true)

---@type PiReviewOpts
local defaults = {
	add_mode = "pi-input",
	send_mode = "input",
	include_symbol = false,
	include_line_text = false,
	include_col = false,
	single_prefix = "Review ",
	batch_header = "Review comments ({count}):",
	item_template = nil,
	item_template_range = nil,
	create_keymaps = true,
}

---@type PiReviewOpts|nil
local opts = nil

---Accumulated review comments waiting to be sent as one prompt (queue mode).
local queue = {}

---@return PiReviewOpts
local function config()
	local user = vim.g.pi_review
	if type(user) ~= "table" then
		user = {}
	end
	return vim.tbl_deep_extend("keep", opts or {}, user, defaults)
end

---@return string|nil socket path
local function prompt_sock()
	return os.getenv("PI_TERMINAL_SOCK")
end

---Render a template, substituting `{field}` placeholders. Missing or empty
---fields render as empty strings. User text is substituted literally.
---@param template string
---@param fields table
---@return string
local function render(template, fields)
	return (template:gsub("{([%w_]+)}", function(key)
		local value = fields[key]
		if value == nil or value == "" then
			return ""
		end
		return tostring(value)
	end))
end

---Compute the file path relative to Pi's working directory (exported by the
---pi-terminal extension as $PI_TERMINAL_CWD). Falls back to nvim's cwd, then
---to the absolute path when the file is outside it.
---@param file string absolute path
---@return string
local function relative_file_path(file)
	local base = os.getenv("PI_TERMINAL_CWD") or vim.fn.getcwd()
	-- Resolve symlinks on both sides (e.g. macOS /tmp vs /private/tmp) so
	-- paths that differ only by symlink still compare as relative.
	local ok, rel = pcall(vim.fs.relpath, vim.fn.resolve(base), vim.fn.resolve(file))
	if ok and type(rel) == "string" and rel ~= "" then
		return rel
	end
	return file
end

---Collect the location fields for the cursor or selection.
---@param opts_ table :command args (line1, line2, range)
---@return table fields, boolean is_range
local function location_fields(opts_)
	local is_range = opts_.range > 0
	local file = vim.fn.expand("%:p")
	return {
		file = file,
		relative_file_path = file ~= "" and relative_file_path(file) or "",
		line1 = opts_.line1 or vim.fn.line("."),
		line2 = opts_.line2 or vim.fn.line("."),
		col = vim.fn.col("."),
		symbol = vim.fn.expand("<cword>"),
		line_text = vim.trim(vim.fn.getline(".")),
	}, is_range
end

---Build one review item using the configured format.
---@param opts_ table :command args (line1, line2, range)
---@return string|nil
local function build_review_text(opts_)
	local fields, is_range = location_fields(opts_)
	if fields.file == "" then
		vim.notify("pi-review: no file in this buffer", vim.log.levels.WARN)
		return nil
	end

	local comment = vim.fn.input("pi review comment: ")
	if vim.trim(comment) == "" then
		return nil
	end
	fields.comment = comment

	local cfg = config()

	if is_range and cfg.item_template_range then
		return render(cfg.item_template_range, fields)
	end
	if cfg.item_template then
		return render(cfg.item_template, fields)
	end

	local location
	if is_range then
		location = ("%s:%d-%d"):format(fields.relative_file_path, fields.line1, fields.line2)
	elseif cfg.include_col then
		location = ("%s:%d:%d"):format(fields.relative_file_path, fields.line1, fields.col)
	else
		location = ("%s:%d"):format(fields.relative_file_path, fields.line1)
	end

	local parts = { location }
	if cfg.include_symbol and fields.symbol ~= "" then
		table.insert(parts, ("(symbol `%s`)"):format(fields.symbol))
	end
	if cfg.include_line_text and not is_range and fields.line_text ~= "" then
		table.insert(parts, ("line: `%s`"):format(fields.line_text))
	end
	table.insert(parts, ("comment: %s"):format(comment))

	return table.concat(parts, " ")
end

---Send one newline-terminated line to the pi prompt socket. Plain text must
---stay single-line; multi-line prompts and mode selection are framed as JSON
---{"text": "...", "mode": ..., "header": "..."}.
---@param text string
---@param send_opts table|nil { multiline = boolean, mode = string, header = string }
function M.send(text, send_opts)
	local sock = prompt_sock()
	if not sock then
		vim.notify("pi-review: $PI_TERMINAL_SOCK not set (run nvim inside pi-terminal)", vim.log.levels.WARN)
		return false
	end
	local ok, chan = pcall(vim.fn.sockconnect, "pipe", sock, { rpc = false })
	if not ok then
		vim.notify("pi-review: cannot connect to pi socket: " .. tostring(chan), vim.log.levels.ERROR)
		return false
	end
	local payload
	if send_opts and (send_opts.multiline or send_opts.mode) then
		local obj = { text = text }
		if send_opts.mode then
			obj.mode = send_opts.mode
		end
		if send_opts.header then
			obj.header = send_opts.header
		end
		payload = vim.json.encode(obj)
	else
		payload = text
	end
	vim.fn.chansend(chan, payload .. "\n")
	vim.fn.chanclose(chan)
	return true
end

---Send immediately.
function M.review_now(cmd_opts)
	local text = build_review_text(cmd_opts)
	if text then
		local cfg = config()
		if M.send(cfg.single_prefix .. text) then
			vim.notify("pi-review: sent", vim.log.levels.INFO)
		end
	end
end

---Add a comment. Default ("pi-input" mode): append it to Pi's input box right
---away — stay in nvim, keep adding, then edit and send from Pi. "queue" mode:
---accumulate in nvim and flush later with PiReviewSend.
function M.review_add(cmd_opts)
	local text = build_review_text(cmd_opts)
	if not text then
		return
	end
	local cfg = config()
	if cfg.add_mode ~= "queue" then
		if M.send(text, { mode = "append", header = cfg.batch_header }) then
			vim.notify("pi-review: added to Pi input — send from Pi when done", vim.log.levels.INFO)
		end
		return
	end
	table.insert(queue, text)
	vim.notify(("pi-review: queued (%d pending)"):format(#queue), vim.log.levels.INFO)
end

---Finish adding. Default ("pi-input" mode): detach back to Pi, where the
---comments are already in the input box — edit and press Enter to send.
---"queue" mode: flush the nvim queue into Pi's input box ("input") or submit
---it to the model ("submit").
function M.review_send()
	local cfg = config()
	if cfg.add_mode ~= "queue" then
		if M.send("", { mode = "focus" }) then
			vim.notify("pi-review: back in Pi — press Enter to send the comments", vim.log.levels.INFO)
		end
		return
	end
	if #queue == 0 then
		vim.notify("pi-review: queue is empty", vim.log.levels.WARN)
		return
	end
	local items = {}
	for i, text in ipairs(queue) do
		table.insert(items, ("%d. %s"):format(i, text))
	end
	local header = render(cfg.batch_header, { count = #queue })
	local text = ("%s\n%s"):format(header, table.concat(items, "\n"))
	local mode = cfg.send_mode == "submit" and "submit" or "input"
	if M.send(text, { multiline = true, mode = mode }) then
		queue = {}
		if mode == "input" then
			vim.notify("pi-review: comments added to Pi input — edit and press Enter in Pi to send", vim.log.levels.INFO)
		else
			vim.notify("pi-review: sent batch", vim.log.levels.INFO)
		end
	end
end

---Discard the comments. Default ("pi-input" mode): clear Pi's input box.
---"queue" mode: clear the nvim queue.
function M.review_clear()
	local cfg = config()
	if cfg.add_mode ~= "queue" then
		if M.send("", { mode = "clear" }) then
			vim.notify("pi-review: cleared Pi input", vim.log.levels.INFO)
		end
		return
	end
	if #queue == 0 then
		vim.notify("pi-review: queue is already empty", vim.log.levels.INFO)
		return
	end
	queue = {}
	vim.notify("pi-review: queue cleared", vim.log.levels.INFO)
end

---Preview the queue contents ("queue" mode only; in "pi-input" mode the
---comments live in Pi's input box).
function M.review_list()
	local cfg = config()
	if cfg.add_mode ~= "queue" then
		vim.notify("pi-review: comments accumulate in Pi's input box — detach (alt+e) to view them", vim.log.levels.INFO)
		return
	end
	if #queue == 0 then
		vim.notify("pi-review: queue is empty", vim.log.levels.INFO)
		return
	end
	local lines = {}
	for i, text in ipairs(queue) do
		table.insert(lines, ("%d. %s"):format(i, text))
	end
	vim.notify("pi-review queue:\n" .. table.concat(lines, "\n"), vim.log.levels.INFO)
end

local function create_commands()
	vim.api.nvim_create_user_command("PiReview", function(c)
		M.review_now(c)
	end, { range = true, desc = "Send review comment (file:line:col + symbol) to pi now" })

	vim.api.nvim_create_user_command("PiReviewAdd", function(c)
		M.review_add(c)
	end, { range = true, desc = "Add a review comment to Pi's input box" })

	vim.api.nvim_create_user_command("PiReviewSend", function()
		M.review_send()
	end, { desc = "Send queued review comments to Pi (input box, or submit)" })

	vim.api.nvim_create_user_command("PiReviewClear", function()
		M.review_clear()
	end, { desc = "Discard queued review comments" })

	vim.api.nvim_create_user_command("PiReviewList", function()
		M.review_list()
	end, { desc = "Preview queued review comments" })
end

local function create_keymaps()
	vim.keymap.set("n", "<leader>pr", ":PiReview<CR>", { desc = "Review: send location + comment to pi now" })
	vim.keymap.set("v", "<leader>pr", ":PiReview<CR>", { desc = "Review: send selection + comment to pi now" })
	vim.keymap.set("n", "<leader>pa", ":PiReviewAdd<CR>", { desc = "Review: add comment to Pi input" })
	vim.keymap.set("v", "<leader>pa", ":PiReviewAdd<CR>", { desc = "Review: add selection comment to Pi input" })
	vim.keymap.set("n", "<leader>ps", ":PiReviewSend<CR>", { desc = "Review: back to Pi to edit and send comments" })
	vim.keymap.set("n", "<leader>pc", ":PiReviewClear<CR>", { desc = "Review: clear queued comments" })
	vim.keymap.set("n", "<leader>pl", ":PiReviewList<CR>", { desc = "Review: list queued comments" })
end

---Configure pi-review. Also creates the commands and (by default) keymaps.
---Alternatively, set `vim.g.pi_review` to the same table.
---@param user_opts PiReviewOpts|nil
function M.setup(user_opts)
	opts = user_opts or {}
	create_commands()
	if opts.create_keymaps ~= false then
		create_keymaps()
	end
end

return M
