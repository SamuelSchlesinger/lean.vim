vim9script

var root = fnamemodify(expand('<sfile>'), ':p:h:h')
var rpc_log = root .. '/test-inlayhints-rpc.log'
delete(rpc_log)

execute 'set runtimepath^=' .. fnameescape(root)
g:lean_config = {
  infoview: {autoopen: false},
  semantic_highlighting: {enable: false},
  completion: {autotrigger: false},
  inlay_hints: {debounce: 0},
  lsp: {
    command: ['python3', root .. '/test/support/fake_lean_server.py', rpc_log],
    change_delay: 0,
    stderr: false,
  },
}

runtime plugin/lean.vim
filetype plugin indent on
execute 'edit! ' .. fnameescape(root .. '/test/fixtures/Completion.lean')

def WaitFor(Predicate: func(): any, timeout_ms: number = 3000): bool
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

def HintProps(): list<any>
  # The plugin creates its prop types lazily on the first refresh.
  var types = filter(['LeanInlayHint', 'LeanInlayHintType', 'LeanInlayHintParam'],
    (_, name) => !empty(prop_type_get(name)))
  if empty(types)
    return []
  endif
  return prop_list(1, {bufnr: bufnr(), end_lnum: -1, types: types})
enddef

def HintRequestCount(): number
  var count = 0
  for encoded in filereadable(rpc_log) ? readfile(rpc_log) : []
    if get(json_decode(encoded), 'method', '') ==# 'textDocument/inlayHint'
      count += 1
    endif
  endfor
  return count
enddef

assert_true(WaitFor(() => get(lean#LspStatus(), 'initialized', false)),
  'inlay-hint fake server did not initialize')
assert_true(WaitFor(() => len(HintProps()) == 2),
  $'expected exactly the two valid hints, got {string(HintProps())}')

# Byte-exact placement: line 1 char 7 → byte col 8; line 2 `-- α😊abc`
# char 6 (after the emoji, 3+2+4 bytes) → byte col 10. Invalid positions
# (surrogate half, out of range) are dropped.
var props = HintProps()
assert_equal(1, props[0].lnum, 'first hint landed on the wrong line')
assert_equal(8, props[0].col, 'first hint landed on the wrong column')
assert_equal('LeanInlayHintType', props[0].type, 'first hint used the wrong prop type')
assert_equal(' : Nat', get(props[0], 'text', ''), 'paddingLeft was not applied')
assert_equal(2, props[1].lnum, 'second hint landed on the wrong line')
assert_equal(10, props[1].col, 'UTF-16 hint column was not converted to bytes')
assert_equal('LeanInlayHintParam', props[1].type, 'second hint used the wrong prop type')
assert_equal('param:', get(props[1], 'text', ''), 'label parts were not concatenated')

# An edit re-requests hints for the new version and re-renders.
var requests_before = HintRequestCount()
setline(3, 'def two := 22')
doautocmd TextChanged
assert_true(WaitFor(() => HintRequestCount() > requests_before),
  'editing the buffer did not re-request inlay hints')
assert_true(WaitFor(() => len(HintProps()) == 2),
  'hints did not re-render after an edit')

# Toggling clears and restores the rendered hints.
LeanInlayHintsToggle
assert_true(WaitFor(() => empty(HintProps())), 'toggle off did not clear hints')
LeanInlayHintsToggle
assert_true(WaitFor(() => len(HintProps()) == 2), 'toggle on did not restore hints')

# Detaching the server leaves no hint properties behind.
lean#Stop()
sleep 50m
assert_true(empty(HintProps()), 'stopping the client left hint properties behind')

if !empty(v:errors)
  for error in v:errors
    echomsg error
  endfor
  cquit
endif
delete(rpc_log)
qa!
