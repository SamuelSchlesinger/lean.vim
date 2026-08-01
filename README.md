# lean.vim

A Vim9-native Lean 4 environment. lean.vim began as a port of
[`lean.nvim`](https://github.com/Julian/lean.nvim) and keeps its command
names, mapping conventions, and configuration shape, so shared dotfiles and
muscle memory carry over — but the two projects have since diverged: this
one is self-contained where lean.nvim composes with the Neovim ecosystem,
adds some behavior of its own, and deliberately stops short of the
interactive widget UI that only Neovim can render. See
[Relationship to lean.nvim](#relationship-to-leannvim) for the specifics.

It runs Lean's language server directly over Vim jobs and channels; Neovim
and an external LSP client are not required.

This project owes an enormous debt to Julian Berman and the lean.nvim
community. See [Acknowledgements](ACKNOWLEDGEMENTS.md) for our thanks and the
specific upstream work that made the original port possible.

The initial port was reviewed against lean.nvim `main` at
`e05c0f821412337259b98cc732ff0cf6ac7afe0c` (2026-07-30); development has been
independent since.

New here? Start with the **[usage guide](USAGE.md)** for a task-oriented
tour, or `:help lean-vim9` for the full reference.

## Requirements

- Vim 9.2, or a late Vim 9.1 that provides `uri_encode()`, built with
  `+vim9script`, `+job`, `+channel`, `+popupwin`, `+textprop`, and `+signs`
  (the plugin checks at startup and reports clearly when a build is too old)
- Lean 4 on `PATH` (normally installed with `elan`)
- `lake` on `PATH` for Lake projects

The test suite currently exercises Vim 9.2 (patches 1-850) and Lean 4.32.2.

## Installation

Put this checkout on Vim's `runtimepath`. Vim's native package layout is the
simplest option:

```sh
mkdir -p ~/.vim/pack/plugins/start
git clone <repository-url> ~/.vim/pack/plugins/start/lean.vim
```

Enable filetype plugins and syntax in `.vimrc` if they are not already enabled:

```vim
filetype plugin indent on
syntax enable
```

Opening a `*.lean` file starts `lake serve` for a Lake project and
`lean --server` for a standalone file. The project root is the nearest
`lakefile.toml`, `lakefile.lean`, `lean-toolchain`, or `.git` marker.

## Configuration

Set `g:lean_config` before the plugin loads. Suggested mappings are opt-in:

```vim
let g:lean_config = {
      \ 'mappings': v:true,
      \ 'infoview': {
      \   'autoopen': v:true,
      \   'orientation': 'auto',
      \   'width': 50,
      \   'height': 12,
      \ },
      \ 'abbreviations': {
      \   'leader': '\',
      \   'extra': {'wknight': '♘'},
      \ },
      \ }
```

The main options are:

| Option | Default | Meaning |
|---|---:|---|
| `mappings` | `v:false` | Enable the suggested buffer-local mappings |
| `abbreviations.enable` | `v:true` | Expand Lean Unicode abbreviations |
| `abbreviations.leader` | `\` | Single-character prefix used for abbreviations |
| `completion.enable` | `v:true` | Install the LSP omnifunc for Lean buffers |
| `completion.autotrigger` | `v:true` | As-you-type popup completion (identifier characters and `.`) |
| `completion.set_completeopt` | `v:true` | Apply `completeopt=menuone,noinsert,noselect,popup` buffer-locally |
| `inlay_hints.enable` | `v:true` | Render LSP inlay hints as virtual text over the visible range |
| `infoview.autoopen` | `v:true` | Open the plain-text infoview for Lean buffers |
| `infoview.orientation` | `auto` | `auto`, `vertical`, or `horizontal` |
| `infoview.update_cooldown` | `50` | Throttle cursor-driven refreshes in milliseconds (`0` disables throttling) |
| `infoview.no_goals_text` | `Goals accomplished 🎉` | Text shown when the goal list is empty |
| `loogle.enable` | `v:false` | Allow `:LeanLoogle` to query loogle.lean-lang.org (the only network feature) |
| `lsp.enable` | `v:true` | Start the built-in Lean-specific LSP client |
| `lsp.command` | `[]` | Override server argv, or supply a root-to-argv function |
| `lsp.change_delay` | `50` | Trailing debounce for edit bursts; isolated edits flush immediately |
| `progress_bars.enable` | `v:true` | Show processing ranges in the sign column |
| `semantic_highlighting.enable` | `v:true` | Render LSP semantic tokens as text properties |
| `semantic_highlighting.links` | `{}` | Per-token-type highlight overrides; `variable` and `property` are unstyled by default |
| `signs.enable` | `v:true` | Render diagnostic and Lean goal signs |

The original `infoview.update_delay` name remains accepted as an alias for
`infoview.update_cooldown`.

Run `:help lean-vim9-configuration` for all accepted keys.

## Daily use

The [usage guide](USAGE.md) walks through all of this in workflow order;
the highlights follow.

The default suggested mappings follow lean.nvim where there is an equivalent:

| Mapping | Action |
|---|---|
| `<LocalLeader>i` | Toggle the infoview |
| `<LocalLeader>p` | Pause or resume infoview updates |
| `<LocalLeader>x` / `<LocalLeader>c` | Add / clear goal pins |
| `<LocalLeader>dx` / `<LocalLeader>dc` | Set / clear a textual diff pin |
| `<LocalLeader>dd` | Toggle automatic diff pins |
| `<LocalLeader><Tab>` | Move between source and infoview |
| `<LocalLeader>\` | Reverse-lookup the symbol under the cursor |
| `<LocalLeader>r` | Restart elaboration for the current file |
| `<LocalLeader>g` | Show the current goal in a popup |
| `<LocalLeader>a` | Select a code action |
| `K` | Show hover information |

All mappings target `<Plug>` names, so users can bind their own keys without
enabling the suggested set.

The most useful commands are:

- `:LeanGoal`, `:LeanTermGoal`, `:LeanLineDiagnostics`, `:LeanDiagnosticsList`, `:LeanHover`
- `:LeanInfoviewToggle`, `:LeanInfoviewAddPin`, `:LeanInfoviewClearPins`
- `:LeanRestartFile`, `:LeanRestartServer`, `:LeanStatus`, `:LeanHealth`
- `:LeanDefinition`, `:LeanDeclaration`, `:LeanReferences`, `:LeanRename`
- `:LeanCodeAction`, `:LeanSorryFill`, `:LeanOutline`, `:LeanWorkspaceSymbols`
- `:LeanModuleImports`, `:LeanModuleImportedBy`, `:LeanSearchPaths`
- `:LeanInlayHintsToggle`, `:LeanLoogle` (opt-in), `:LeanAbbreviationsReverseLookup`

Completion works out of the box: identifiers and dot-completion pop up as you
type (asynchronously — a busy elaborator never blocks typing), `<C-x><C-o>`
triggers it manually, and the selected item's documentation is resolved into
the preview popup. Theorems are tagged `t` in the menu. Inlay hints render as
virtual text over the visible portion of the file and follow scrolling.

Inside the infoview, `<CR>` jumps the source window to the entry under the
cursor (position header, pin, or diagnostic), and the view is syntax
highlighted. A statusline component is available with
`set statusline+=%{lean#StatuslineProgress()}`.

Unicode abbreviations expand on Space, Tab, Enter, or leaving Insert mode.
The full abbreviation table is synchronized from lean.nvim's VS Code data.
While an abbreviation is in progress, completion stays out of the way.

## Relationship to lean.nvim

lean.vim began as a faithful port and stays compatible on the surface:
command names, `<LocalLeader>` mapping conventions, and configuration keys
mirror lean.nvim wherever both projects implement a feature. Core editing is
implemented directly in Vim9: server lifecycle, document synchronization,
completion, inlay hints, goals, term goals, diagnostics, progress, semantic
tokens, hover/navigation, code actions, workspace edits, pins,
abbreviations, syntax, indentation, snippets, document/workspace symbols,
and module queries.

Since the initial port the projects have diverged in both directions.

Where lean.vim goes its own way:

- **Self-contained where lean.nvim delegates.** Completion (async omnifunc
  plus as-you-type popup) and inlay hints are built in; lean.nvim relies on
  Neovim's LSP client and a completion plugin for those. The LSP transport
  itself is a small, auditable Vim9 client rather than `vim.lsp`.
- **Rendering scaled for large files.** Progress signs and inlay hints
  decorate only the visible range and follow scrolling, and a failed server
  start backs off instead of retrying on every window switch.
- **Additions without an upstream equivalent**: `:LeanHealth`, a
  Telescope-free opt-in `:LeanLoogle`, and `lean#StatuslineProgress()`.

Where lean.nvim remains ahead — deliberately not emulated here:

- ProofWidgets, clickable subexpressions, widget tooltips, and terminal
  graphics need Neovim's extmark and Lua UI substrate. The infoview uses
  Lean's stable `$/lean/plainGoal` and `$/lean/plainTermGoal` requests, with
  plain text, syntax highlighting, and `<CR>` jumps instead of an
  interactive render tree; pins are textual snapshots rather than live,
  re-elaborating markers.
- Telescope and satellite.nvim integrations are replaced by quickfix,
  location lists, and the sign column.

Widget commands exist for command-name compatibility and explain this
boundary when invoked.

## Architecture

The transport is intentionally self-contained — depending on a second Vim
LSP plugin would tie goal requests, restart behavior, and Lean-specific
notifications to a third party's extension hooks.

- `autoload/lean/lsp.vim` — LSP/JSON-RPC client, document state,
  diagnostics, progress, semantic tokens, workspace edits
- `autoload/lean/completion.vim` — async omnifunc and popup completion
- `autoload/lean/inlayhints.vim` — visible-range inlay hints
- `autoload/lean/infoview.vim` — goal UI, pins, diff pins, source jumps
- `autoload/lean/abbreviations.vim` — Unicode expansion and reverse lookup
- `autoload/lean/editor.vim` — hover, navigation, symbols, code actions,
  sorry fill, search paths
- `autoload/lean/health.vim`, `autoload/lean/loogle.vim` — `:LeanHealth`
  and the opt-in Loogle search
- `autoload/lean.vim` — commands, mappings, statusline, buffer lifecycle

## Validation

```sh
make lint       # compile every Vim9 module
make test       # fake-server transport and editor integration
make test-live  # end-to-end check against the installed Lean server
make license-check # verify pinned third-party files and required notices
```

The headless tests cover split JSON-RPC frames, initialization and graceful
shutdown, request cancellation, failed-start backoff, diagnostics, progress
(including large-file sign capping), goals, term goals, semantic tokens,
completion (async popup, UTF-16 textEdits, cancellation, resolve,
abbreviation interplay), inlay hints, infoview jumping, document and
workspace symbols, UTF-16 incremental changes, restart races, workspace-edit
preflight, tab and ftplugin lifecycle, indentation, and Unicode abbreviation
insertion. The live test checks goal retrieval, diagnostic updates, Lake
startup, and search paths against real Lean processes.

## License

The port and the retained lean.nvim syntax/snippet material are MIT-licensed.
The Unicode abbreviation data is Apache-2.0. See [NOTICE](NOTICE) for exact
file provenance and [ACKNOWLEDGEMENTS.md](ACKNOWLEDGEMENTS.md) for project
credit.
