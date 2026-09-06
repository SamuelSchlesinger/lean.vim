vim9script

var root = fnamemodify(expand('<sfile>'), ':p:h:h')
var rpc_log = root .. '/test-editor-rpc.log'
delete(rpc_log)

execute 'set runtimepath^=' .. fnameescape(root)
g:lean_config = {
  infoview: {autoopen: false},
  semantic_highlighting: {enable: false},
  lsp: {
    command: ['python3', root .. '/test/support/fake_lean_server.py', rpc_log],
    change_delay: 0,
    stderr: false,
  },
}

runtime plugin/lean.vim
filetype plugin indent on
set hidden
execute 'edit! ' .. fnameescape(root .. '/test/fixtures/Editor.lean')

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

def RpcHas(method: string, command: string = ''): bool
  for encoded in filereadable(rpc_log) ? readfile(rpc_log) : []
    var message = json_decode(encoded)
    if get(message, 'method', '') ==# method
        && (empty(command)
          || get(get(message, 'params', {}), 'command', '') ==# command)
      return true
    endif
  endfor
  return false
enddef

assert_true(WaitFor(() => get(lean#LspStatus(), 'initialized', false)),
  'editor fake server did not initialize')

# LSP columns are UTF-16 code units, while quickfix columns are byte based.
cursor(1, 1)
lean#References()
assert_true(WaitFor(() => !empty(getqflist())), 'references did not populate quickfix')
assert_equal(10, getqflist()[0].col, 'reference UTF-16 column was used as a byte column')
assert_equal('-- α😊target', getqflist()[0].text, 'reference quickfix item omitted source context')
cclose

# Delayed navigation, hover, and outline replies belong to the requesting
# window. They must not modify a window visited while Lean was responding.
var navigation_source = bufnr()
lean#Definition()
lean#Hover()
lean#Outline()
execute 'edit ' .. fnameescape(root .. '/test/fixtures/Basic.lean')
cursor(3, 2)
var destination = win_getid()
var destination_cursor = getcurpos()[1 : 2]
var destination_list = getloclist(0)
sleep 400m
assert_equal(destination, win_getid(), 'a delayed response changed the active window')
assert_equal('Basic.lean', expand('%:t'), 'a delayed definition replaced the active buffer')
assert_equal(destination_cursor, getcurpos()[1 : 2], 'a delayed definition moved the active cursor')
assert_equal(destination_list, getloclist(0), 'a delayed outline replaced another window list')
assert_true(empty(popup_list()), 'a delayed hover appeared in another buffer')
execute 'buffer ' .. navigation_source

# LSP defines array order for multiple inserts at one position.
enew!
execute 'file ' .. fnameescape(root .. '/test/fixtures/WorkspaceEdit.lean')
setline(1, 'X')
var edit_uri = lean#util#UriFromBuf(bufnr())
assert_true(lean#util#ApplyTextEdits(edit_uri, [
  {range: {start: {line: 0, character: 0}, end: {line: 0, character: 0}}, newText: 'A'},
  {range: {start: {line: 0, character: 0}, end: {line: 0, character: 0}}, newText: 'B'},
]))
assert_equal('ABX', getline(1), 'same-position LSP inserts were reversed')

setline(1, 'XYZ')
assert_true(lean#util#ApplyTextEdits(edit_uri, [
  {range: {start: {line: 0, character: 0}, end: {line: 0, character: 0}}, newText: 'A'},
  {range: {start: {line: 0, character: 0}, end: {line: 0, character: 0}}, newText: 'B'},
  {range: {start: {line: 0, character: 0}, end: {line: 0, character: 1}}, newText: 'C'},
]), 'ordered inserts followed by a replacement were rejected')
assert_equal('ABCYZ', getline(1))

setline(1, 'abcd')
assert_false(lean#util#ApplyTextEdits(edit_uri, [
  {range: {start: {line: 0, character: 0}, end: {line: 0, character: 2}}, newText: 'X'},
  {range: {start: {line: 0, character: 1}, end: {line: 0, character: 3}}, newText: 'Y'},
]), 'overlapping LSP edits were accepted')
assert_equal('abcd', getline(1), 'rejected overlapping edits changed the buffer')

assert_false(lean#util#ApplyTextEdits(edit_uri, [{
  range: {start: {line: 0, character: 99}, end: {line: 0, character: 99}},
  newText: 'X',
}]), 'an out-of-bounds UTF-16 edit position was accepted')
assert_equal('abcd', getline(1), 'an invalid UTF-16 edit changed the buffer')

setline(1, '😊')
assert_false(lean#util#ApplyTextEdits(edit_uri, [{
  range: {start: {line: 0, character: 1}, end: {line: 0, character: 1}},
  newText: 'X',
}]), 'an edit position splitting a UTF-16 surrogate pair was accepted')
assert_equal('😊', getline(1), 'a surrogate-splitting edit changed the buffer')
setline(1, 'abcd')

setlocal nomodifiable
assert_false(lean#util#ApplyTextEdits(edit_uri, [{
  range: {start: {line: 0, character: 0}, end: {line: 0, character: 0}},
  newText: 'X',
}]), 'an edit to a non-modifiable buffer was reported as successful')
assert_equal('abcd', getline(1), 'an edit changed a non-modifiable buffer')
setlocal modifiable

# The whole workspace edit is validated before any target is changed.
var atomic_uri = edit_uri
assert_false(lean#lsp#ApplyWorkspaceEdit({documentChanges: [
  {
    textDocument: {uri: atomic_uri, version: v:null},
    edits: [{
      range: {start: {line: 0, character: 0}, end: {line: 0, character: 0}},
      newText: 'changed',
    }],
  },
  {kind: 'create', uri: lean#util#UriFromPath(root .. '/test/fixtures/Created.lean')},
]}), 'unsupported workspace resource operation was accepted')
assert_equal('abcd', getline(1), 'failed workspace edit was applied partially')

# LSP edits include the document's final newline in their position space.
setlocal endofline
setline(1, 'X')
assert_true(lean#util#ApplyTextEdits(edit_uri, [{
  range: {start: {line: 0, character: 0}, end: {line: 1, character: 0}},
  newText: 'Y',
}]))
assert_equal('Y', getline(1))
assert_false(&endofline, 'whole-document edit did not remove the final newline')

execute 'edit! ' .. fnameescape(root .. '/test/fixtures/Editor.lean')

# Multiple goals get focused sorries and leave the cursor in the first one.
cursor(2, strlen(getline(2)))
lean#SorryFill()
assert_true(WaitFor(() => getline(3) ==# '  · sorry'), 'multiple-goal sorries were not inserted')
assert_equal(['  · sorry', '  · sorry'], getline(3, 4))
assert_equal([3, 6], [line('.'), col('.')], 'cursor was not placed in the first focused sorry')

# A sorry inserted from within a focused branch is indented under the branch.
edit!
cursor(3, strlen(getline(3)))
lean#SorryFill()
assert_true(WaitFor(() => getline(4) ==# '    sorry'), 'focused-branch sorry was not indented')
assert_equal([4, 5], [line('.'), col('.')], 'cursor was not placed in the inserted sorry')

# Async replies must not edit a buffer which changed after the request.
edit!
cursor(4, strlen(getline(4)))
lean#SorryFill()
setline(4, '  exact changed')
sleep 150m
assert_equal(4, line('$'), 'stale LeanSorryFill response inserted text')
assert_equal('  exact changed', getline(4))

# A delayed reply uses the target buffer's indentation even if another buffer
# is current by the time it arrives.
edit!
var editor_bufnr = bufnr()
cursor(4, strlen(getline(4)))
lean#SorryFill()
execute 'edit ' .. fnameescape(root .. '/test/fixtures/Basic.lean')
assert_true(WaitFor(() => len(getbufline(editor_bufnr, 1, '$')) == 5),
  'LeanSorryFill did not update its hidden target buffer')
assert_equal('  sorry', getbufline(editor_bufnr, 5)[0],
  'LeanSorryFill used the current buffer indentation')
assert_equal('Basic.lean', expand('%:t'), 'LeanSorryFill changed the current buffer')
execute 'buffer ' .. editor_bufnr
edit!

# Clearing pins invalidates an in-flight pin request, so a late reply cannot
# make a cleared pin reappear.
edit!
cursor(4, strlen(getline(4)))
lean#InfoviewAddPin()
lean#InfoviewClearPins()
sleep 300m
assert_true(empty(get(lean#InfoviewState(), 'pins', [])), 'cleared pin reappeared after a late reply')

# Data-only code actions must be resolved before their resulting command is
# executed.
lean#editor#ApplyCodeAction(bufnr(), {title: 'resolve me', data: {id: 1}})
assert_true(WaitFor(() => RpcHas('codeAction/resolve')),
  'data-only code action was not resolved')
assert_true(WaitFor(() => RpcHas('workspace/executeCommand', 'fake.resolvedAction')),
  'resolved code-action command was not executed')

# <CR> in the infoview jumps the source window to the rendered entry.
edit!
cursor(2, 3)
lean#InfoviewOpen()
assert_true(WaitFor(() => !empty(get(lean#InfoviewState(), 'goal', []))),
  'infoview goal did not render for the jump test')
lean#InfoviewAddPin()
assert_true(WaitFor(() => len(get(lean#InfoviewState(), 'pins', [])) == 1),
  'pin was not added for the jump test')
var jump_view = lean#InfoviewState()
var pin_lnum = indexof(getbufline(jump_view.bufnr, 1, '$'),
  (_, text) => text =~# '^Pin ') + 1
assert_true(pin_lnum > 0, 'pin header was not rendered')
win_gotoid(bufwinid(jump_view.bufnr))
assert_false(empty(maparg('<CR>', 'n')), 'infoview <CR> mapping was not installed')
cursor(pin_lnum, 1)
lean#infoview#JumpToTarget()
assert_equal('Editor.lean', expand('%:t'), '<CR> jump did not focus the source window')
assert_equal([2, 3], [line('.'), col('.')], '<CR> jump missed the pin position')

# A pin retains its file when the infoview follows a different Lean buffer.
execute 'edit ' .. fnameescape(root .. '/test/fixtures/Basic.lean')
jump_view = lean#InfoviewState()
pin_lnum = indexof(getbufline(jump_view.bufnr, 1, '$'), (_, text) => text =~# '^Pin ') + 1
assert_match('Editor.lean', getbufline(jump_view.bufnr, pin_lnum)[0],
  'a pin from another file did not identify its source')
win_gotoid(bufwinid(jump_view.bufnr))
cursor(pin_lnum, 1)
lean#infoview#JumpToTarget()
assert_equal('Editor.lean', expand('%:t'), 'pin jump went to the currently followed file')
assert_equal([2, 3], [line('.'), col('.')], 'cross-file pin jump missed its position')
lean#InfoviewClearPins()
lean#InfoviewClose()

# :LeanDiagnosticsList collects real diagnostics and skips decoration-only
# entries (silent goals, goal markers).
assert_true(WaitFor(() => !empty(lean#lsp#Diagnostics(lean#util#UriFromBuf(bufnr())))),
  'diagnostics were not republished for the loclist test')
lean#DiagnosticsList()
var loclist = getloclist(0)
assert_equal(1, len(loclist), 'diagnostics loclist should hold exactly the real warning')
assert_equal(2, loclist[0].lnum, 'diagnostics loclist used the wrong line')
assert_equal('W', loclist[0].type, 'diagnostics loclist used the wrong severity type')
assert_equal('test warning', loclist[0].text, 'diagnostics loclist used the wrong text')
lclose

# The document outline flattens hierarchical symbols with depth indenting.
lean#Outline()
assert_true(WaitFor(() => get(getloclist(0, {title: 1}), 'title', '') ==# 'Lean outline'),
  'outline did not populate the location list')
var outline = getloclist(0)
assert_equal(2, len(outline), 'outline item count')
assert_equal('answer [constant]', outline[0].text, 'outline top-level entry')
# Line 1 is `-- α😊target`: UTF-16 character 4 is the emoji at byte 5.
assert_equal([1, 6], [outline[0].lnum, outline[0].col], 'outline selectionRange position')
assert_equal('  nested [function]', outline[1].text, 'outline child entry was not indented')
lclose

# Workspace symbol search fills the quickfix list with kind labels.
lean#WorkspaceSymbols('succ')
assert_true(WaitFor(() => get(getqflist({title: 1}), 'title', '') =~# 'workspace symbols'),
  'workspace symbols did not populate quickfix')
var symbols = getqflist()
assert_equal(1, len(symbols), 'workspace symbol count')
assert_match('Nat\.succ_le \[theorem\] (Nat)', symbols[0].text,
  'workspace symbol text lacked the kind and container labels')
cclose

# Statusline component reports diagnostic counts for attached buffers.
assert_match('W:1', lean#StatuslineProgress(),
  'statusline component did not report the warning count')

# Loogle: response parsing is pure, and network access is opt-in.
var loogle_parsed = lean#loogle#ParseResponse(
  '{"hits": [{"name": "Nat.succ", "type": "Nat → Nat", "module": "Init.Prelude"}]}')
assert_true(loogle_parsed.ok, 'valid Loogle response failed to parse')
assert_equal([{name: 'Nat.succ', type: 'Nat → Nat', module: 'Init.Prelude'}],
  loogle_parsed.hits, 'Loogle hits were not extracted')
var loogle_error = lean#loogle#ParseResponse('{"error": "unknown identifier"}')
assert_false(loogle_error.ok, 'a Loogle error response was treated as success')
assert_equal('unknown identifier', loogle_error.error)
assert_false(lean#loogle#ParseResponse('not json').ok,
  'invalid JSON from Loogle was treated as success')
lean#Loogle('Nat.succ')
assert_match('Loogle is disabled', execute('messages'),
  ':LeanLoogle did not explain the opt-in flag while disabled')

# The popup command prompts from a mapping, then delegates the entered query
# to the same async search path. A temporary curl keeps this test offline.
var fake_bin = tempname()
mkdir(fake_bin)
var fake_curl = fake_bin .. '/curl'
writefile([
  '#!/bin/sh',
  'printf ''%s\n'' ''{"hits":[{"name":"Nat.succ","type":"Nat → Nat\n  continuation","module":"Init.Prelude"}]}''',
], fake_curl)
setfperm(fake_curl, 'rwxr-xr-x')
var saved_path = $PATH
$PATH = fake_bin .. ':' .. saved_path
g:lean_config['loogle'] = {enable: true}
lean#config#Reset()
timer_start(10, (_) => feedkeys("Nat.succ\<CR>", 'nt'))
nnoremap <buffer> ,l <Cmd>LeanLooglePopup<CR>
feedkeys(',l', 'xt')
nunmap <buffer> ,l
assert_true(WaitFor(() => getline(1) ==# 'Loogle: Nat.succ'),
  ':LeanLooglePopup did not submit the prompted query')
assert_match('Nat.succ : Nat → Nat', getline(3),
  ':LeanLooglePopup did not render the search result')
assert_equal('  continuation', getline(4), 'multiline Loogle types were not split into lines')
close
$PATH = saved_path
delete(fake_curl)
delete(fake_bin, 'd')

# :LeanHealth renders a self-contained report.
lean#Health()
assert_match('lean.vim health', getline(1), ':LeanHealth did not open its report')
var health_text = join(getline(1, '$'), "\n")
assert_match('uri_encode(): ok', health_text, 'health report skipped builtin checks')
assert_match('project root:', health_text, 'health report skipped the project root')
assert_match('server initialized: true', health_text, 'health report skipped server state')
assert_match('Recent server stderr:', health_text, 'health report omitted server errors')
var health_buffer = bufnr()
wincmd p
lean#Health()
assert_equal(health_buffer, bufnr(), 'repeating LeanHealth did not refresh the existing report')
close

lean#Stop()
sleep 50m
delete(rpc_log)

if !empty(v:errors)
  for error in v:errors
    echomsg error
  endfor
  cquit
endif
qa!
