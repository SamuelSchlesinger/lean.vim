vim9script

var root = fnamemodify(expand('<sfile>'), ':p:h:h')
var rpc_log = root .. '/test-rpc.log'
delete(rpc_log)

execute 'set runtimepath^=' .. fnameescape(root)
g:lean_config = {
  mappings: true,
  abbreviations: {extra: {'λx': 'custom'}},
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

def ApplyIncremental(old_text: string, change: dict<any>): string
  var start = lean#util#TextOffset(old_text, change.range.start)
  var finish = lean#util#TextOffset(old_text, change.range.end)
  return strpart(old_text, 0, start) .. change.text .. strpart(old_text, finish)
enddef

var incremental_cases = [
  ['', 'x'],
  ['abc', 'xabc'],
  ['abc', 'ab'],
  ["one\ntwo\nthree\n", "one\nTWO!\nthree\n"],
  ["one\nthree", "one\ntwo\nthree"],
  ['a😊b', 'ab'],
  ['α', 'β'],
  ['😊', '😢'],
  ["á", "â"],
  ["same\n", "same\n"],
]
for texts in incremental_cases
  var change = lean#util#IncrementalChange(texts[0], texts[1])
  assert_equal(texts[1], ApplyIncremental(texts[0], change),
    $'incremental change did not reconstruct {string(texts)}')
endfor
var emoji_change = lean#util#IncrementalChange('😊', '😢')
assert_equal({line: 0, character: 0}, emoji_change.range.start)
assert_equal({line: 0, character: 2}, emoji_change.range.end)
var multiline_change = lean#util#IncrementalChange("one\ntwo\nthree\n", "one\nTWO!\nthree\n")
assert_equal({line: 1, character: 0}, multiline_change.range.start)
assert_equal({line: 1, character: 3}, multiline_change.range.end)

# Exercise both sides of the chunked fast path, including UTF-8 code points
# whose byte prefixes are shared but whose LSP ranges must stay on boundaries.
for boundary in [4095, 4096, 4097, 8192]
  var long_old = repeat('a', boundary) .. '😊' .. repeat('z', 5000)
  var long_new = repeat('a', boundary) .. '😢' .. repeat('z', 5000)
  var long_change = lean#util#IncrementalChange(long_old, long_new)
  assert_equal(long_new, ApplyIncremental(long_old, long_change),
    $'chunk-boundary reconstruction failed at {boundary}')
  assert_equal({line: 0, character: boundary}, long_change.range.start)
  assert_equal({line: 0, character: boundary + 2}, long_change.range.end)
endfor

# Exercise every replacement range in a mixed ASCII/BMP/astral/multiline
# document. This checks the reconstruction invariant independently of any
# particular prefix/suffix shape.
var mixed_text = "aβ😊\nxýz\n"
var character_count = strchars(mixed_text)
for start_character in range(character_count)
  for end_character in range(start_character, character_count)
    for replacement in ['', 'Q', "λ\n😢"]
      var edited = strcharpart(mixed_text, 0, start_character)
        .. replacement .. strcharpart(mixed_text, end_character)
      var mixed_change = lean#util#IncrementalChange(mixed_text, edited)
      assert_equal(edited, ApplyIncremental(mixed_text, mixed_change),
        $'incremental reconstruction failed at {start_character}:{end_character}')
    endfor
  endfor
endfor

assert_true(WaitFor(() => get(lean#LspStatus(), 'initialized', false)), 'LSP did not initialize')
assert_equal('lean', &filetype)
assert_equal('-- %s', &commentstring)
assert_equal('LeanVim9Indent(v:lnum)', &indentexpr)
assert_equal(2, exists(':LeanGoal'))
assert_false(empty(maparg('<Plug>(LeanInfoviewToggle)', 'n')))
assert_false(empty(maparg('K', 'n')))
assert_equal('α', lean#abbreviations#ConvertText("\\alpha"))
assert_equal('→', lean#abbreviations#ConvertText("\\to"))
assert_equal('αx', lean#abbreviations#ConvertText("\\alphax"))
assert_equal('custom!', lean#abbreviations#ConvertText("\\λx!"))
assert_equal("\\", lean#abbreviations#ConvertText("\\"))
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
sleep 20m
var sequence = lean#InfoviewState().sequence
noautocmd call cursor(4, 1)
lean#OnCursorMoved(source)
assert_equal(sequence + 1, lean#InfoviewState().sequence,
  'the infoview throttle did not update on its leading edge')
noautocmd call cursor(2, 1)
lean#OnCursorMoved(source)
assert_equal(sequence + 1, lean#InfoviewState().sequence,
  'the infoview throttle did not suppress an update during its cooldown')
assert_true(WaitFor(() => lean#InfoviewState().sequence == sequence + 2),
  'the infoview throttle did not flush its trailing update')

var version_before_change = getbufvar(source, 'lean_lsp_version', 0)
setbufline(source, 2, '  exact 43')
lean#OnChanged(source)
assert_equal(version_before_change + 1, getbufvar(source, 'lean_lsp_version', 0),
  'an isolated document edit did not flush on the leading edge')
setbufline(source, 2, '  exact 44')
lean#OnChanged(source)
setbufline(source, 2, '  exact 45')
lean#OnChanged(source)
assert_equal(version_before_change + 1, getbufvar(source, 'lean_lsp_version', 0),
  'a document edit burst was not debounced')
assert_true(WaitFor(() => getbufvar(source, 'lean_lsp_version', 0)
  == version_before_change + 2), 'the trailing document edit was not flushed')
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
var did_changes = filter(copy(messages), (_, message) =>
  get(message, 'method', '') ==# 'textDocument/didChange')
assert_true(!empty(did_changes))
assert_true(indexof(did_changes, (_, message) =>
  !has_key(message.params.contentChanges[0], 'range')) < 0,
  'an incremental-sync server received a full-document change')
assert_true(indexof(did_changes, (_, message) =>
  get(message.params.contentChanges[0], 'text', '') ==# '3') >= 0,
  'the exact-42 to exact-43 edit was not minimized')
assert_true(indexof(did_changes, (_, message) =>
  get(message.params.contentChanges[0], 'text', '') ==# '5') >= 0,
  'the trailing exact-45 edit was not minimized')
assert_true(indexof(did_changes, (_, message) =>
  get(message.params.contentChanges[0], 'text', '') ==# '4') < 0,
  'an intermediate edit in the debounced burst was sent')
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
