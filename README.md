# pi-review.nvim

Send review comments from nvim to [pi](https://pi.dev), with file, line, column, and symbol context — while nvim runs inside a pi terminal.

Comments accumulate in pi's input box as you add them (you stay in nvim); when you're done, detach back to pi, edit them if needed, and press Enter to send. Or submit a comment to the model immediately.

## Requirements

- [pi](https://pi.dev) with the **pi-terminal extension** installed (`~/.pi/agent/extensions/pi-terminal`). It exports two environment variables to terminals:
  - `PI_TERMINAL_SOCK` — Unix socket to the enclosing pi session
  - `PI_TERMINAL_CWD` — pi's working directory (for relative paths)
- nvim 0.9+ (uses `vim.fs.relpath`, `vim.json`, `sockconnect`)

## Install

### [lazy.nvim](https://lazy.folke.io) / LazyVim

```lua
-- lua/plugins/pi-review.lua
return {
    "ksatarin/pi-review-nvim",
    lazy = false,
    opts = {
        item_template = "{relative_file_path}:{line1} (`{symbol}`) comment: {comment}",
    },
}
```

During development, point lazy at a local checkout:

```lua
return {
    dir = "~/dev/pi-review-nvim",
    lazy = false,
    opts = {},
}
```

## Commands and keymaps

| Keymap | Command | Action |
|---|---|---|
| `<leader>pr` | `:PiReview` | Send one comment to the model immediately |
| `<leader>pa` | `:PiReviewAdd` | Add a comment to pi's input box (stay in nvim) |
| `<leader>ps` | `:PiReviewSend` | Detach back to pi, where the comments wait in the input box |
| `<leader>pc` | `:PiReviewClear` | Clear pi's input box |
| `<leader>pl` | `:PiReviewList` | Preview the nvim queue (queue mode) |

`<leader>pr` and `<leader>pa` accept visual selections (a line range is sent). Keymaps are created unless `create_keymaps = false` is passed to `setup()`.

## Configuration

All options go through `setup()` (or `vim.g.pi_review` as an alternative). Defaults produce comments with a **relative path, line number, and comment only**:

```
Review comments (2):
1. src/app.ts:42 comment: rename this
2. src/util.ts:7-9 comment: dead code
```

| Option | Default | Description |
|---|---|---|
| `add_mode` | `"pi-input"` | Where comments accumulate: appended to pi's input box as you add them (`"pi-input"`), or queued in nvim and flushed by `:PiReviewSend` (`"queue"`) |
| `send_mode` | `"input"` | Queue-mode flush: place the batch in pi's input box (`"input"`) or submit it to the model (`"submit"`) |
| `include_symbol` | `false` | Append `(symbol \`word\`)` to cursor items (built-in format only, i.e. when `item_template` is nil) |
| `include_line_text` | `false` | Append `line: \`text\`` to cursor items (built-in format only) |
| `include_col` | `false` | Include the column in the location (`file:line:col`) (built-in format only) |
| `single_prefix` | `"Review "` | Prefix on immediate sends (`<leader>pr`) |
| `batch_header` | `"Review comments ({count}):"` | First line of the batch in pi's input box; `{count}` is replaced with the item count |
| `item_template` | `nil` | Full format override for single-cursor items; when nil, the built-in format is `{relative_file_path}:{line1} comment: {comment}` plus the `include_*` extras |
| `item_template_range` | `nil` | Full format override for visual selections; when nil, the built-in format is `{relative_file_path}:{line1}-{line2} comment: {comment}` |
| `create_keymaps` | `true` | Create the default `<leader>` keymaps in `setup()` |

```lua
require("pi-review").setup({
    add_mode          = "pi-input",
    send_mode         = "input",
    include_symbol    = false,
    include_line_text = false,
    include_col       = false,
    single_prefix     = "Review ",
    batch_header      = "Review comments ({count}):",
    item_template     = nil,
    item_template_range = nil,
    create_keymaps    = true,
})
```

### Templates

`item_template` replaces the built-in format for single-cursor items; `item_template_range` does the same for visual selections (defaults to `file:line1-line2 comment: ...`). Placeholders (empty fields render as `""`):

| Placeholder | Meaning |
|---|---|
| `{file}` | absolute file path |
| `{relative_file_path}` | path relative to pi's working directory (absolute when outside it) |
| `{line1}` `{line2}` | selection range (equal for cursor items) |
| `{col}` | cursor column (selection start in visual mode) |
| `{symbol}` | word under the cursor (selection start in visual mode) |
| `{line_text}` | cursor line text (selection start in visual mode) |
| `{comment}` | the comment you typed |

Example — adding the symbol back and styling selections differently:

```lua
opts = {
    item_template       = "{relative_file_path}:{line1} (`{symbol}`) — {comment}",
    item_template_range = "{relative_file_path}:{line1}-{line2} (selection): {comment}",
}
```

```
Review comments (2):
1. src/app.ts:42 (`handleRetry`) — rename this
2. src/util.ts:7-9 (selection): dead code
```

## How it works

Each comment is written as one newline-terminated line to `$PI_TERMINAL_SOCK`:

- `{"text": "...", "mode": "append", "header": "..."}` — append a numbered item to pi's input box, no detach; `{count}` in the header is replaced with the item count
- plain text — submit immediately as a user message
- `{"mode": "focus"}` / `{"mode": "clear"}` — detach back to pi / clear its input box

Item numbering counts the numbered lines already in pi's input, so it stays correct across sends from pi. Comments added while a passthrough editor has the screen are buffered and applied when it detaches.

## License

MIT
