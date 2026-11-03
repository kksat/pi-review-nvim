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

All options go through `setup()` (or `vim.g.pi_review` as an alternative):

```lua
require("pi-review").setup({
    add_mode          = "pi-input",  -- "pi-input": each Add appends to Pi's input box
                                    -- "queue": Add accumulates in nvim, Send flushes
    send_mode         = "input",     -- queue-mode flush: "input" or "submit"
    include_symbol    = true,        -- "(symbol `word`)"
    include_line_text = true,        -- "line: `text`" (single-cursor items)
    include_col       = true,        -- the column in file:line:col
    single_prefix     = "Review ",   -- prefix on immediate sends
    batch_header      = "Review comments ({count}):",
    item_template     = nil,         -- full format override, cursor items
    item_template_range = nil,       -- full format override, visual selections
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

Example:

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
