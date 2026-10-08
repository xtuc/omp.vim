# omp.vim

Advanced oh-my-pi integration for Neovim.

<p align="center">
  <img src=".github/demo.png" alt="omp.vim demo" width="800">
</p>

Put in your `~/.vimrc`:

```vim
Plug 'xtuc/omp.vim'
" ...
nnoremap <silent> <leader>o :lua require('omp').open()<CR>
```

## Key bindings

- `<Esc>` then `<Enter>` — send prompt; insert-mode `<Enter>` — newline.
- `<C-c>` — abort response (prompt normal mode).
- `<Up>`/`<Down>` (normal/insert), `k`/`j` (normal) — browse prompt history at first/last line; `Down` past newest restores draft.
- `i` (transcript) — edit prompt; `:q` — close pane.
- Approval choices: `j`/`k` or arrows, then `<Enter>`; `q` or `<Esc>` dismisses. Input dialogs use `<Enter>` to submit and `<Esc>` to cancel.

## Features

- Independent transcript scroll, multiline prompt, Markdown and tool output, approvals and todos.
- Statusline: model, thinking, context, cost, activity; divider above prompt: running tasks, active commands, and named background bash/eval jobs.
- RPC edit diffs use `difft` when available; unified-diff fallback.
- Per-project sessions resume on reopen. History: 100 prompts from current RPC session, not terminal's global history.
- Prompt stays editable during tool calls, including `wait`. Send a message to steer; OMP interrupts an interruptible wait, backgrounds the still-running command, and handles the message. Background jobs leave the divider when their result arrives. Changed clean file buffers reload after tools.

## Special commands

- `/new` — new session in current project.
- `/high` — set thinking level to high.
- Other oh-my-pi text-mode slash commands pass through RPC.

## Requirements

- Neovim, Bun, and oh-my-pi (`omp`). The RPC launcher expects `~/.bun/bin/bun` and `~/.bun/bin/omp` even if Neovim's `PATH` differs.
- `difft` is optional; without it, edit results use unified diffs.
