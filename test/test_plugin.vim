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
assert_equal('g:LeanVim9Indent(v:lnum)', &indentexpr)
assert_equal(2, exists(':LeanGoal'))
assert_false(empty(maparg('<Plug>(LeanInfoviewToggle)', 'n')))
assert_false(empty(maparg('K', 'n')))
assert_equal('α', lean#abbreviations#ConvertText("\\alpha"))
assert_equal('→', lean#abbreviations#ConvertText("\\to"))
assert_equal('αx', lean#abbreviations#ConvertText("\\alphax"))
assert_equal('custom!', lean#abbreviations#ConvertText("\\λx!"))
assert_equal("\\", lean#abbreviations#ConvertText("\\"))
assert_equal(5, lean#util#ByteColumn('a😊b', 3))
var uri_path = root .. '/test/fixtures/a b#c.lean'
assert_equal(fnamemodify(uri_path, ':p'),
  lean#util#PathFromUri(lean#util#UriFromPath(uri_path)),
  'file URI encoding did not round-trip reserved characters')
assert_equal('/tmp/a b', lean#util#PathFromUri('file://localhost/tmp/a%20b'),
  'localhost file URI authority was treated as part of the path')
assert_equal(root .. '/test/fixtures/LakeProject',
  lean#lsp#ProjectRoot(root .. '/test/fixtures/LakeProject/LeanVimFixture.lean'))
assert_equal(root .. '/test/fixtures/LakeProject',
  lean#lsp#ProjectRoot(root .. '/test/fixtures/LakeProject/.lake/packages/dep/Dep.lean'),
  'a Lake dependency was given its own language-server root')
assert_equal('/opt/lean/lib/lean',
  lean#lsp#ProjectRoot('/opt/lean/lib/lean/Init/Prelude.lean'),
  'installed Lean library was split into per-directory roots')
assert_equal('/opt/lean/lean/library',
  lean#lsp#ProjectRoot('/opt/lean/lean/library/Init/Prelude.lean'),
  'Lean source library root was not detected')

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

# Showing an already-loaded Lean buffer in a new tab does not fire FileType;
# BufWinEnter must still create that tab's independent auto-opened infoview.
var original_infoview_bufnr = state.bufnr
tab split
assert_true(WaitFor(() => !empty(lean#InfoviewState())
  && lean#InfoviewState().bufnr != original_infoview_bufnr),
  'auto-open did not create an infoview for an existing buffer in a new tab')
var second_tab_infoview_bufnr = lean#InfoviewState().bufnr
tabclose
sleep 20m
assert_equal(original_infoview_bufnr, lean#InfoviewState().bufnr,
  'closing the duplicate-buffer tab changed the original infoview')
assert_false(bufexists(second_tab_infoview_bufnr),
  'duplicate-buffer tab leaked its infoview buffer')
state = lean#InfoviewState()

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
sleep 30m
assert_true(indexof(lean#lsp#DiagnosticsAt(source, 0), (_, diagnostic) =>
  get(diagnostic, 'message', '') ==# 'stale warning') < 0,
  'a stale versioned diagnostic replaced current diagnostics')
lean#RestartFile()
sleep 100m

var uri = lean#util#UriFromBuf(source)
var version_before_workspace_edit = getbufvar(source, 'lean_lsp_version', 0)
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
assert_equal(version_before_workspace_edit + 1,
  getbufvar(source, 'lean_lsp_version', 0),
  'workspace edit was not synchronized before a following command could run')

var version_for_edit = getbufvar(source, 'lean_lsp_version', 0)
assert_false(lean#lsp#ApplyWorkspaceEdit({documentChanges: [{
  textDocument: {uri: uri, version: version_for_edit - 1},
  edits: [{
    range: {
      start: {line: 1, character: 8},
      end: {line: 1, character: 10},
    },
    newText: '99',
  }],
}]}), 'a stale versioned workspace edit was accepted')
assert_equal('  exact 42', getbufline(source, 2)[0], 'a stale workspace edit changed the buffer')

# Restarting replaces the server object before the old process necessarily
# reports its exit. The old callback must not mark the new server as dead.
lean#RestartServer()
assert_true(WaitFor(() => get(lean#LspStatus(), 'initialized', false)),
  'restarted LSP did not initialize')
sleep 100m
assert_true(get(lean#LspStatus(), 'running', false),
  'the old server exit callback stopped the replacement server')
assert_true(WaitFor(() => !empty(sign_getplaced(source, {group: 'lean-diagnostics'})[0].signs)),
  'diagnostics did not return after restart')

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

# Renaming a live buffer must close the old document URI before opening the
# new one, even when both names have the same project root.
var original_uri = lean#util#UriFromBuf(source)
execute 'file ' .. fnameescape(root .. '/test/fixtures/RenamedBuffer.lean')
var renamed_uri = lean#util#UriFromBuf(source)
assert_notequal(original_uri, renamed_uri)
assert_equal(renamed_uri, getbufvar(source, 'lean_lsp_uri', ''),
  'BufFilePost did not transfer LSP ownership to the new URI')
assert_true(WaitFor(() => index(mapnew(prop_list(1, {bufnr: source}),
  (_, property) => property.type), 'LeanSemantic_keyword') >= 0),
  'semantic tokens did not return for the renamed document')

# Detach owns every decoration and cache associated with the document.
assert_true(index(mapnew(prop_list(1, {bufnr: source}),
  (_, property) => property.type), 'LeanSemantic_keyword') >= 0,
  'semantic tokens were unexpectedly absent before detach')
lean#lsp#Detach(source)
sleep 30m
assert_true(empty(sign_getplaced(source, {group: 'lean-diagnostics'})[0].signs),
  'diagnostic signs survived detach')
assert_true(empty(sign_getplaced(source, {group: 'lean-progress'})[0].signs),
  'progress signs survived detach')
assert_true(index(mapnew(prop_list(1, {bufnr: source}),
  (_, property) => property.type), 'LeanSemantic_keyword') < 0,
  'semantic tokens survived detach')
assert_true(empty(lean#lsp#DiagnosticsAt(source, 1)), 'diagnostic cache survived detach')
assert_false(lean#lsp#ProgressAt(source, 2), 'progress cache survived detach')

lean#Stop()
sleep 50m

var messages = mapnew(filereadable(rpc_log) ? readfile(rpc_log) : [], (_, line) => json_decode(line))
assert_true(indexof(messages, (_, message) => get(message, 'method', '') ==# 'initialize') >= 0)
var initialize_messages = filter(copy(messages), (_, message) =>
  get(message, 'method', '') ==# 'initialize')
assert_equal('undo', initialize_messages[0].params.capabilities.workspace.workspaceEdit.failureHandling,
  'workspace-edit failure handling overclaimed transactional support')
assert_equal(['edit', 'command'],
  initialize_messages[0].params.capabilities.textDocument.codeAction.resolveSupport.properties,
  'lazy code-action properties were not advertised')
assert_equal(2, len(filter(copy(messages), (_, message) =>
  get(message, 'method', '') ==# 'initialize')), 'restart did not create exactly one replacement server')
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
assert_true(indexof(messages, (_, message) => get(message, 'id', -1) == 901
  && get(get(message, 'error', {}), 'code', 0) == -32601) >= 0,
  'unsupported dynamic registration was incorrectly reported as successful')
assert_true(indexof(messages, (_, message) =>
  get(message, 'method', '') ==# 'textDocument/didOpen'
    && get(get(message, 'params', {}), 'dependencyBuildMode', '') ==# 'once') >= 0)
assert_equal(3, len(filter(copy(messages), (_, message) =>
  get(message, 'method', '') ==# 'textDocument/didClose')),
  'restart-file, buffer rename, and detach did not each send exactly one didClose')
assert_true(indexof(messages, (_, message) =>
  get(message, 'method', '') ==# 'textDocument/didClose'
    && get(message.params.textDocument, 'uri', '') ==# original_uri) >= 0,
  'buffer rename did not close the original URI')
assert_true(indexof(messages, (_, message) =>
  get(message, 'method', '') ==# 'textDocument/didOpen'
    && get(message.params.textDocument, 'uri', '') ==# renamed_uri) >= 0,
  'buffer rename did not open the replacement URI')
assert_true(indexof(messages, (_, message) =>
  get(message, 'method', '') ==# '$/cancelRequest') >= 0,
  'superseded infoview requests were not cancelled')
assert_equal(2, len(filter(copy(messages), (_, message) =>
  get(message, 'method', '') ==# 'shutdown')),
  'restart and final stop did not gracefully shut down both servers')
assert_equal(2, len(filter(copy(messages), (_, message) =>
  get(message, 'method', '') ==# 'exit')),
  'restart and final stop did not send exit to both servers')

if !empty(v:errors)
  for error in v:errors
    echomsg error
  endfor
  cquit
endif
delete(rpc_log)
qa!
