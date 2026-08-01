vim9script

var root = fnamemodify(expand('<sfile>'), ':p:h:h')
execute 'set runtimepath^=' .. fnameescape(root)
g:lean_config = {
  mappings: true,
  infoview: {autoopen: false},
  lsp: {enable: false},
}

runtime plugin/lean.vim
filetype plugin indent on
execute 'edit ' .. fnameescape(root .. '/test/fixtures/Basic.lean')

var source = bufnr()
var main_group = $'lean_vim_buffer_{source}'
var abbreviation_group = $'lean_abbreviations_{source}'
assert_true(get(b:, 'lean_vim_attached', false), 'Lean runtime did not attach')
assert_false(empty(maparg('K', 'n')), 'suggested Lean mapping was not installed')
assert_true(exists($'#{main_group}#TextChanged'), 'Lean buffer autocmds were not installed')
assert_true(exists($'#{abbreviation_group}#InsertCharPre'),
  'abbreviation autocmds were not installed')

# Vim's ftplugin loader executes b:undo_ftplugin before loading the new
# filetype. Lean-owned state must not leak into the replacement filetype.
setlocal filetype=text
assert_false(get(b:, 'lean_vim_attached', true), 'Lean runtime survived a filetype change')
assert_true(empty(maparg('K', 'n')), 'suggested Lean mapping survived a filetype change')
assert_true(empty(maparg('<Plug>(LeanHover)', 'n')), 'Lean <Plug> mapping survived a filetype change')
assert_false(exists($'#{main_group}#TextChanged'), 'Lean buffer autocmds survived a filetype change')
assert_false(exists($'#{abbreviation_group}#InsertCharPre'),
  'abbreviation autocmds survived a filetype change')
assert_equal('', &l:indentexpr, 'Lean indentation survived a filetype change')

# Switching back is a fresh, complete attachment rather than a half-detached
# buffer with stale b: guards.
setlocal filetype=lean
assert_true(get(b:, 'lean_vim_attached', false), 'Lean runtime did not reattach')
assert_false(empty(maparg('K', 'n')), 'suggested mapping did not return after reattach')
assert_true(exists($'#{main_group}#TextChanged'), 'Lean autocmds did not return after reattach')
assert_true(exists($'#{abbreviation_group}#InsertCharPre'),
  'abbreviation autocmds did not return after reattach')
assert_equal('g:LeanVim9Indent(v:lnum)', &l:indentexpr,
  'Lean indentation did not return after reattach')

if !empty(v:errors)
  for error in v:errors
    echomsg error
  endfor
  cquit
endif
qa!
