vim9script

var root = fnamemodify(expand('<sfile>'), ':p:h:h')
var rpc_log = root .. '/test-rpc.log'
delete(rpc_log)

execute 'set runtimepath^=' .. fnameescape(root)
g:lean_config = {
  mappings: true,
  infoview: {autoopen: true, update_delay: 10},
  lsp: {
    command: ['python3', root .. '/test/support/fake_lean_server.py', rpc_log],
    change_delay: 10,
    stderr: false,
  },
}

runtime plugin/lean.vim
filetype plugin indent on
syntax enable
execute 'edit ' .. fnameescape(root .. '/test/fixtures/Basic.lean')

def WaitFor(Predicate: func(): any, timeout_ms: number = 2000): bool
  var elapsed = 0
  while elapsed < timeout_ms
    if Predicate()
      return true
    endif
    sleep 10m
    elapsed += 10
  endwhile
  return Predicate()
enddef

assert_true(WaitFor(() => get(lean#LspStatus(), 'initialized', false)), 'LSP did not initialize')
assert_equal('lean', &filetype)
assert_equal('-- %s', &commentstring)
assert_equal('LeanVim9Indent(v:lnum)', &indentexpr)
assert_equal(2, exists(':LeanGoal'))
assert_false(empty(maparg('<Plug>(LeanInfoviewToggle)', 'n')))
assert_false(empty(maparg('K', 'n')))
assert_equal('α', lean#abbreviations#ConvertText("\\alpha"))
assert_equal('→', lean#abbreviations#ConvertText("\\to"))
assert_equal(5, lean#util#ByteColumn('a😊b', 3))
assert_equal(root .. '/test/fixtures/LakeProject',
  lean#lsp#ProjectRoot(root .. '/test/fixtures/LakeProject/LeanVimFixture.lean'))

assert_true(WaitFor(() => !empty(sign_getplaced(bufnr(), {group: 'lean-diagnostics'})[0].signs)),
  'diagnostic sign was not placed')
assert_equal('test warning', lean#lsp#DiagnosticsAt(bufnr(), 1)[0].message)
assert_equal(1, len(lean#lsp#DiagnosticsAt(bufnr(), 1)))
assert_true(index(mapnew(sign_getplaced(bufnr(), {group: 'lean-diagnostics'})[0].signs,
  (_, sign) => sign.name), 'LeanGoalUnsolved') >= 0)
assert_true(lean#lsp#ProgressAt(bufnr(), 2))
assert_true(WaitFor(() => index(mapnew(prop_list(1, {bufnr: bufnr()}),
  (_, property) => property.type), 'LeanSemantic_keyword') >= 0),
  'semantic token property was not placed')

assert_true(WaitFor(() => index(get(lean#InfoviewState(), 'goal', []), '⊢ Nat') >= 0),
  'auto-opened infoview goal did not render: ' .. string(lean#InfoviewState()))
var state = lean#InfoviewState()
assert_equal(['Nat'], state.term_goal)

lean#InfoviewClose()
assert_true(empty(win_findbuf(state.bufnr)), 'infoview window did not close')
lean#InfoviewOpen()
assert_true(WaitFor(() => !empty(win_findbuf(state.bufnr))), 'infoview window did not reopen')
state = lean#InfoviewState()

var source = state.source_bufnr
win_gotoid(state.source_winid)
setbufline(source, 2, '  exact 43')
lean#OnChanged(source)
sleep 100m
lean#RestartFile()
sleep 100m

var uri = lean#util#UriFromBuf(source)
assert_true(lean#lsp#ApplyWorkspaceEdit({changes: {
  [uri]: [{
    range: {
      start: {line: 1, character: 8},
      end: {line: 1, character: 10},
    },
    newText: '42',
  }],
}}))
assert_equal('  exact 42', getbufline(source, 2)[0])

setbufline(source, 5, '')
cursor(5, 1)
var old_tab_mapping = maparg('<Tab>', 'i', false, true)
feedkeys("i\\alpha \<Esc>", 'xt')
sleep 50m
assert_equal('α ', getbufline(source, 5)[0], 'insert-mode abbreviation did not expand')
assert_equal(old_tab_mapping, maparg('<Tab>', 'i', false, true), 'Tab mapping was not restored')
appendbufline(source, 5, '')
cursor(6, 1)
feedkeys("i\\to\<Tab>X\<Esc>", 'xt')
sleep 50m
assert_equal('→X', getbufline(source, 6)[0], 'tab-triggered abbreviation did not expand')
appendbufline(source, 6, '')
cursor(7, 1)
feedkeys("i\\\\ \<Esc>", 'xt')
sleep 50m
assert_equal("\\ ", getbufline(source, 7)[0], 'escaped abbreviation leader did not collapse')

lean#Stop()
sleep 50m

var messages = mapnew(filereadable(rpc_log) ? readfile(rpc_log) : [], (_, line) => json_decode(line))
assert_true(indexof(messages, (_, message) => get(message, 'method', '') ==# 'initialize') >= 0)
assert_true(indexof(messages, (_, message) => get(message, 'method', '') ==# 'textDocument/didChange') >= 0)
assert_true(indexof(messages, (_, message) => get(message, 'id', -1) == 900
  && get(message, 'result', []) ==# [v:null]) >= 0)
assert_true(indexof(messages, (_, message) =>
  get(message, 'method', '') ==# 'textDocument/didOpen'
    && get(get(message, 'params', {}), 'dependencyBuildMode', '') ==# 'once') >= 0)

if !empty(v:errors)
  for error in v:errors
    echomsg error
  endfor
  cquit
endif
qa!
