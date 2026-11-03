-- pi-review.nvim — send review comments from nvim to pi.
--
-- Requires nvim to be running inside a pi-terminal session (passthrough or
-- overlay) of the pi-terminal extension, which exports $PI_TERMINAL_SOCK
-- (Unix socket to the enclosing pi session) and $PI_TERMINAL_CWD (pi's
-- working directory). Each comment is appended to pi's input box as you add
-- it; editing and sending happens in pi.

local M = {}

---@class PiReviewOpts
---@field include_symbol boolean Append "(symbol `word`)" to cursor items
---@field include_line_text boolean Append "line: `text`" to cursor items
---@field include_col boolean Include the column in the location
---@field batch_header string Batch header; "{count}" is replaced with the item count
---@field item_template string|nil Full format override for single-cursor items
---@field item_template_range string|nil Full format override for visual selections
---@field create_keymaps boolean Create the default <leader> keymaps (default true)

---@type PiReviewOpts
local defaults = {
	include_symbol = false,
	include_line_text = false,
	include_col = false,
	batch_header = "Review comments ({count}):",
	item_template = nil,
	item_template_range = nil,
	create_keymaps = true,
}

---@type PiReviewOpts|nil
local opts = nil

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
---@param cmd_opts table :command args (line1, line2, range)
---@return table fields, boolean is_range
local function location_fields(cmd_opts)
	local is_range = cmd_opts.range > 0
	local file = vim.fn.expand("%:p")
	return {
		file = file,
		relative_file_path = file ~= "" and relative_file_path(file) or "",
		line1 = cmd_opts.line1 or vim.fn.line("."),
		line2 = cmd_opts.line2 or vim.fn.line("."),
		col = vim.fn.col("."),
		symbol = vim.fn.expand("<cword>"),
		line_text = vim.trim(vim.fn.getline(".")),
	}, is_range
end

---Build one review item using the configured format.
---@param cmd_opts table :command args (line1, line2, range)
---@return string|nil
local function build_review_text(cmd_opts)
	local fields, is_range = location_fields(cmd_opts)
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

---Append one comment to Pi's input box as a JSON-framed socket line.
---@param text string item text
---@param header string batch header template
---@return boolean
local function send_append(text, header)
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
	local payload = vim.json.encode({ text = text, mode = "append", header = header })
	vim.fn.chansend(chan, payload .. "\n")
	vim.fn.chanclose(chan)
	return true
end

---Add a review comment at the cursor (or for the selection) to Pi's input
---box. You stay in nvim; edit and send the accumulated comments in pi.
---@param cmd_opts table :command args (line1, line2, range)
function M.review_add(cmd_opts)
	local text = build_review_text(cmd_opts)
	if not text then
		return
	end
	local cfg = config()
	if send_append(text, cfg.batch_header) then
		vim.notify("pi-review: added to Pi input — send from Pi when done", vim.log.levels.INFO)
	end
end

local function create_commands()
	vim.api.nvim_create_user_command("PiReviewAdd", function(c)
		M.review_add(c)
	end, { range = true, desc = "Add a review comment to Pi's input box" })
end

local function create_keymaps()
	vim.keymap.set("n", "<leader>pa", ":PiReviewAdd<CR>", { desc = "Review: add comment to Pi input" })
	vim.keymap.set("v", "<leader>pa", ":PiReviewAdd<CR>", { desc = "Review: add selection comment to Pi input" })
end

---Configure pi-review. Also creates the command and (by default) keymaps.
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
