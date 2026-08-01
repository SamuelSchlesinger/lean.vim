# lean.vim

A Vim9-native Lean 4 environment, modeled after
[`lean.nvim`](https://github.com/Julian/lean.nvim). It runs Lean's language
server directly over Vim jobs and channels; Neovim and an external LSP client
are not required.

This project owes an enormous debt to Julian Berman and the lean.nvim
community. See [Acknowledgements](ACKNOWLEDGEMENTS.md) for our thanks and the
specific upstream work that made this port possible.

The implementation was built against lean.nvim `main` at
`e05c0f821412337259b98cc732ff0cf6ac7afe0c` (2026-07-30). See
[FUNCTIONALITY.md](FUNCTIONALITY.md) for the reviewed feature inventory and
the exact parity boundary.

## Requirements

- Vim 9.1 with `+vim9script`, `+job`, `+channel`, `+popupwin`, `+textprop`, and
  `+signs`
- Lean 4 on `PATH` (normally installed with `elan`)
- `lake` on `PATH` for Lake projects

The test suite currently exercises Vim 9.1.1752 and Lean 4.32.2.

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
| `infoview.autoopen` | `v:true` | Open the plain-text infoview for Lean buffers |
| `infoview.orientation` | `auto` | `auto`, `vertical`, or `horizontal` |
| `infoview.update_cooldown` | `50` | Throttle cursor-driven refreshes in milliseconds (`0` disables throttling) |
| `lsp.enable` | `v:true` | Start the built-in Lean-specific LSP client |
| `lsp.command` | `[]` | Override server argv, or supply a root-to-argv function |
| `lsp.change_delay` | `50` | Trailing debounce for edit bursts; isolated edits flush immediately |
| `progress_bars.enable` | `v:true` | Show processing ranges in the sign column |
| `semantic_highlighting.enable` | `v:true` | Render LSP semantic tokens as text properties |
| `signs.enable` | `v:true` | Render diagnostic and Lean goal signs |

The original `infoview.update_delay` name remains accepted as an alias for
`infoview.update_cooldown`.

Run `:help lean-vim9-configuration` for all accepted keys.

## Daily use

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

- `:LeanGoal`, `:LeanTermGoal`, `:LeanLineDiagnostics`, `:LeanHover`
- `:LeanInfoviewToggle`, `:LeanInfoviewAddPin`, `:LeanInfoviewClearPins`
- `:LeanRestartFile`, `:LeanRestartServer`, `:LeanStatus`
- `:LeanDefinition`, `:LeanDeclaration`, `:LeanReferences`, `:LeanRename`
- `:LeanCodeAction`, `:LeanSorryFill`
- `:LeanModuleImports`, `:LeanModuleImportedBy`, `:LeanSearchPaths`
- `:LeanAbbreviationsReverseLookup`

Unicode abbreviations expand on Space, Tab, Enter, or leaving Insert mode.
The full abbreviation table is synchronized from lean.nvim's VS Code data.

## Deliberate compatibility boundary

Core editing is implemented directly in Vim9: server lifecycle, document
synchronization, goals, term goals, diagnostics, progress, semantic tokens,
hover/navigation, code actions, workspace edits, pins, abbreviations, syntax,
indentation, snippets, and module queries.

ProofWidgets, clickable subexpressions, terminal graphics, and Neovim-specific
Telescope/satellite integrations are not emulated. The infoview uses Lean's
stable `$/lean/plainGoal` and `$/lean/plainTermGoal` requests. Widget commands
exist for command-name compatibility and explain this boundary when invoked.

## Validation

```sh
make lint       # compile every Vim9 module
make test       # fake-server transport and editor integration
make test-live  # end-to-end check against the installed Lean server
make license-check # verify pinned third-party files and required notices
```

The headless tests cover split JSON-RPC frames, initialization and graceful
shutdown, request cancellation, diagnostics, progress, goals, term goals,
semantic tokens, UTF-16 incremental changes, restart races, workspace-edit
preflight, tab and ftplugin lifecycle, indentation, and Unicode
abbreviation insertion. The live test checks goal retrieval, diagnostic
updates, Lake startup, and search paths against real Lean processes.

## License

The port and the retained lean.nvim syntax/snippet material are MIT-licensed.
The Unicode abbreviation data is Apache-2.0. See [NOTICE](NOTICE) for exact
file provenance and [ACKNOWLEDGEMENTS.md](ACKNOWLEDGEMENTS.md) for project
credit.
