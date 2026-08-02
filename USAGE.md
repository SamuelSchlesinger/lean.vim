# Using lean.vim

A task-oriented tour of daily Lean 4 work in Vim. The complete reference
lives in the help file: `:help lean-vim9`.

## Your first proof session

Open any `.lean` file. lean.vim finds the project root (`lakefile.toml`,
`lakefile.lean`, `lean-toolchain`, or `.git`), starts `lake serve` (or
`lean --server` for standalone files), and auto-opens the infoview. As
elaboration proceeds you'll see orange progress bars in the sign column
march down the file; they track only the part of the file you're looking
at, so Mathlib-sized files stay responsive.

Move the cursor into a proof and the infoview follows, showing the tactic
goals at that position. When a proof closes, it shows `Goals accomplished 🎉`.

If nothing happens, run `:LeanHealth` — it reports the Vim build, the
toolchain on `PATH`, the detected project root, and the server state in one
place.

## The infoview

The infoview is a plain-text split that follows your cursor:

- the header line shows the file and position it reflects,
- goals render with `case` labels, hypotheses, and `⊢`, all syntax
  highlighted,
- diagnostics at the cursor line appear below the goals,
- `Expected type:` shows the term-mode goal when there is one.

Inside the infoview window:

- `<CR>` jumps the source window to the entry under the cursor — the
  header, a pin, or a diagnostic,
- `q` closes it, `<Esc>` returns to the source window.

Pins (`:LeanInfoviewAddPin`, `<LocalLeader>x`) capture the goal at a
position so you can watch two proof states at once; `:LeanInfoviewClearPins`
removes them. Diff pins (`:LeanInfoviewSetDiffPin`, `<LocalLeader>dx`)
record a baseline goal and show a `-`/`+` line diff as the goal evolves;
`:LeanInfoviewToggleAutoDiffPin` re-baselines on every step. Pins are
snapshots of text — they do not re-elaborate as the file changes.

`:LeanInfoviewPinTogglePause` freezes updates while you explore;
`:LeanGoal` and `:LeanTermGoal` show one-off popups without the split.

## Typing Lean

**Unicode abbreviations** work like VS Code and lean.nvim: type `\alpha`
and it becomes `α` when you press Space, Tab, Enter, or leave Insert mode.
Tab expands without inserting anything; Space expands and keeps the space.
`\\` escapes to a literal backslash. With the cursor on any special symbol,
`:LeanAbbreviationsReverseLookup` (`<LocalLeader>\`) shows what to type to
produce it.

**Completion** pops up as you type identifiers, and immediately after `.`
(so `Nat.` lists everything in the namespace). It is fully asynchronous —
a busy elaborator never blocks your typing; results simply appear when
ready. Navigate with `<C-n>`/`<C-p>`; the highlighted item's documentation
loads into the preview popup on demand. Theorems are tagged `t` in the
menu. `<C-x><C-o>` triggers completion (the default); set
`completion.autotrigger: v:true` for an automatic as-you-type popup —
each request costs the server real elaboration work, so it is opt-in.

The two features are aware of each other: while you're mid-abbreviation,
completion stays out of the way, so `\al<Tab>` always expands rather than
fighting a popup for the Tab key.

## Reading feedback

- Diagnostics render as signs (`E`/`W`/`I`/`H`) and underlines; unsolved
  goals show `G`, finished proofs `✓`.
- `:LeanLineDiagnostics` pops up the full messages for the current line.
- `:LeanDiagnosticsList` collects every diagnostic in the buffer into the
  location list for a file-wide sweep.
- Inlay hints (parameter names, inferred types) render as dimmed virtual
  text over the visible range and follow scrolling. `:LeanInlayHintsToggle`
  turns them on and off.
- Semantic highlighting colors keywords and function applications from the
  server. Variables and field projections stay uncolored on purpose — they
  are most of the file; `semantic_highlighting.links` opts them back in
  (for example `{'variable': 'Identifier'}`).
- For a statusline summary (elaboration percentage plus error/warning
  counts): `set statusline+=%{lean#StatuslineProgress()}`.

## Getting around

- `:LeanDefinition` / `:LeanDeclaration` / `:LeanTypeDefinition` jump to a
  symbol's source; `K` (suggested mapping) shows hover documentation.
- `:LeanReferences` fills the quickfix list with every use of the symbol.
- `:LeanOutline` puts the document's declarations in the location list,
  indented by nesting.
- `:LeanWorkspaceSymbols {query}` searches the whole project.
- `:LeanModuleImports` / `:LeanModuleImportedBy` show the import graph
  around the current file.

## Editing assists

- `:LeanCodeAction` (`<LocalLeader>a`) lists server code actions — this is
  how you accept `Try this:` suggestions.
- `:LeanRename` renames project-wide with a preflighted, atomic workspace
  edit (it rolls back cleanly rather than half-applying).
- `:LeanSorryFill` inserts one `sorry` (or a `· sorry` per goal) matching
  the current indentation.

## Searching Mathlib

`:LeanLoogle {pattern}` queries [loogle.lean-lang.org](https://loogle.lean-lang.org)
and shows `name : type — module` results in a scratch buffer. It is the
plugin's only network feature and ships disabled; enable it with:

```vim
let g:lean_config = {'loogle': {'enable': v:true}}
```

`:LeanSearchPaths` shows where Lean is reading sources from (core plus
`LEAN_SRC_PATH`), useful with `:find` and `gf`.

## Managing the server

- When the server reports "Imports are out of date", lean.vim restarts the
  file for you once per buffer (the fresh-project case), which rebuilds and
  reloads the stale imports; disable with `lsp.refresh_stale_imports`.
  Later occurrences only show the diagnostic — deliberate, so saving a
  module that others import cannot trigger background rebuild storms.
- `:LeanRestartFile` (`<LocalLeader>r`) does the same by hand — useful when
  automatic refresh is off or a rebuild failed.
- `:LeanRestartServer` restarts the project's server process.
- If the server can't start (toolchain missing, broken project), lean.vim
  reports it once and backs off instead of retrying on every window switch;
  `:LeanRestartServer` always retries immediately.
- `:LeanStatus` shows the connection; `:LeanInfoviewOpenDebug` includes the
  server's recent stderr; `:LeanHealth` is the first stop for anything
  mysterious.

## Configuration recipes

Everything lives in `g:lean_config` (set before the plugin loads); see
`:help lean-vim9-configuration` for every key.

```vim
" Enable the suggested <LocalLeader> mappings shown throughout this guide
let g:lean_config = {'mappings': v:true}

" Prefer a horizontal infoview, and the plain 'No goals.' message
let g:lean_config = {
      \ 'infoview': {'orientation': 'horizontal', 'no_goals_text': 'No goals.'},
      \ }

" As-you-type completion popup (manual <C-x><C-o> is the default)
let g:lean_config = {'completion': {'autotrigger': v:true}}

" Quieter UI: no inlay hints, no progress bars
let g:lean_config = {
      \ 'inlay_hints': {'enable': v:false},
      \ 'progress_bars': {'enable': v:false},
      \ }
```

## Relationship to lean.nvim

lean.vim shares lean.nvim's command names, mapping conventions, and
configuration shape, but is an independent implementation that has diverged
in both directions — see the
[README](README.md#relationship-to-leannvim) for the specifics.
