# lean.nvim functionality review and Vim9 port boundary

## Reviewed upstream

This review is pinned to Julian Berman's `lean.nvim` commit
`e05c0f821412337259b98cc732ff0cf6ac7afe0c`, authored 2026-07-30. The review
used the repository README, generated `doc/lean.txt`, the public manual, tests,
and the implementations under `lua/lean`, `lsp/leanls.lua`, and
`ftplugin/lean/lean.lua`.

Relevant upstream entry points:

- [lean.nvim README](https://github.com/Julian/lean.nvim)
- [lean.nvim manual](https://github.com/Julian/lean.nvim/wiki/The-lean.nvim-Manual)
- [Lean server protocol notes](https://github.com/leanprover/lean4/tree/master/src/Lean/Server)

## What lean.nvim does

lean.nvim is more than an LSP configuration. Its functionality divides into
six layers:

1. It finds a Lean project, chooses `lake serve` or `lean --server`, configures
   Lean-specific capabilities, and manages file restarts.
2. It augments standard LSP behavior with Lean diagnostics, goal markers,
   file-progress signs, semantic highlighting, hovers, navigation, code
   actions, and inlay hints.
3. It opens a persistent infoview and queries goals, term goals, diagnostics,
   suggestions, pins, and module state as the cursor moves.
4. It establishes Lean RPC sessions and renders interactive expressions,
   tagged diagnostics, tooltips, user widgets, ProofWidgets HTML, images, and
   SVG content through a custom terminal UI renderer.
5. It expands Lean's Unicode abbreviation vocabulary and provides syntax,
   indentation, snippets, comment, match, and switch support.
6. It integrates optional Neovim plugins such as Telescope and satellite.nvim.

The fourth layer is the main portability fault line. It depends heavily on
Neovim Lua APIs, extmarks, namespaces, asynchronous coroutines, buffer-local
render trees, and—in some cases—the Kitty graphics protocol. Vim 9 has strong
jobs, channels, popups, signs, and text properties, but it does not expose the
same UI substrate or a built-in LSP client.

## Implemented parity

| Upstream behavior | Vim9 implementation | Status |
|---|---|---|
| Project/root detection | Parent marker walk and `.lake/packages` handling | Implemented |
| `lake serve` / `lean --server` | Vim job with raw channel transport | Implemented |
| LSP framing and lifecycle | Native Content-Length JSON-RPC parser, request table, server requests | Implemented |
| Open/change/save/close sync | Versioned full-document notifications with debounce | Implemented |
| Restart current file | `didClose` + `didOpen` with `dependencyBuildMode = once` | Implemented |
| Diagnostics | Signs, underlines, silent-goal filtering, line popup | Implemented |
| File progress | Lean progress notifications rendered as signs | Implemented |
| Semantic tokens | UTF-16-aware Vim text properties | Implemented |
| Goal and term-goal popups | Lean plain-goal protocol requests | Implemented |
| Persistent infoview | Cursor-following Vim split with goals, terms, diagnostics | Implemented |
| Pins and diff pins | Persistent textual snapshots and line-oriented diffs | Implemented, simpler model |
| Hover and navigation | LSP hover, definition, declaration, type definition | Implemented |
| References and rename | Quickfix references and workspace-edit rename | Implemented |
| Code actions | Selection plus workspace edit / execute-command support | Implemented |
| Module hierarchy | Lean 4.22 requests displayed as a flat quickfix list | Implemented, simpler UI |
| Unicode abbreviations | Full upstream data, Insert-mode conversion, reverse lookup | Implemented |
| Syntax, indentation, snippets | Vim runtime files and VS Code snippet data | Implemented |
| Matchit and switch.vim | Lean-aware buffer definitions when installed | Implemented |
| Lean search paths | Core prefix plus `LEAN_SRC_PATH` from `lake env` | Implemented |

## Intentionally not emulated

| Neovim feature | Reason / Vim9 behavior |
|---|---|
| Interactive subexpression renderer | Plain hover and goal text are shown; nested clickable RPC references are not rendered |
| ProofWidgets and arbitrary user widgets | These require the upstream render tree and widget-specific Lua/HTML machinery |
| Terminal image and SVG rendering | No Kitty graphics layer is emitted by this port |
| Infoview tooltips and widget mouse actions | The Vim infoview is a read-only text buffer |
| Inlay hints | Not yet rendered; ordinary diagnostics and semantic tokens are supported |
| Telescope Loogle picker | Neovim/Telescope-specific; use an external search workflow |
| satellite.nvim progress overview | Neovim-specific; normal Vim sign-column progress is present |

The compatibility commands `:LeanInfoviewEnableWidgets` and
`:LeanInfoviewDisableWidgets` remain available so shared editor configuration
does not fail mysteriously; they report that the Vim9 infoview is plain-text.

## Port architecture

- `autoload/lean/lsp.vim`: Lean-specific LSP/JSON-RPC client, document state,
  diagnostics, progress, semantic tokens, and workspace edits.
- `autoload/lean/infoview.vim`: split/popup goal UI, pins, diff pins, and
  cursor-following updates.
- `autoload/lean/abbreviations.vim`: full Unicode expansion and reverse lookup.
- `autoload/lean/editor.vim`: hover, navigation, references, rename, code
  actions, sorry fill, hierarchy, and search paths.
- `autoload/lean.vim`: public commands, mappings, and buffer lifecycle.

The transport is intentionally self-contained. Requiring users to install a
second Vim LSP plugin would make goal requests, restart behavior, and
Lean-specific notifications depend on a third party's extension hooks.
