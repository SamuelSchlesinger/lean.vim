vim9script

var root = fnamemodify(expand('<sfile>'), ':p:h:h')
execute 'set runtimepath^=' .. fnameescape(root)
import autoload 'lean/infoview_render.vim' as renderer

# Rendering works without a Lean buffer, windows, an LSP client, or config.
var snapshot = {source_loaded: true, source_name: 'Example.lean',
  position: {line: 2, character: 3},
  pins: [{uri: 'file:///Other.lean', label: 'Other.lean ', line: 8, character: 1,
    lines: ['h : True', '⊢ True']}],
  diff_pin: ['⊢ Nat'], goal: ['⊢ Bool'], term_goal: ['Bool'], processing: true,
  diagnostics: [{severity: 2, message: "first\nsecond", range: {
    start: {line: 4, character: 2}, end: {line: 4, character: 3}}}]}
var before = deepcopy(snapshot)
var rendered = renderer.Build(snapshot, {show_processing: true, show_no_info: true})
assert_equal(snapshot, before, 'rendering mutated its input model')
assert_equal('Example.lean  3:4', rendered.lines[0])
assert_equal('Pin Other.lean 9:2', rendered.lines[2])
assert_equal({uri: 'file:///Other.lean', line: 8, character: 1}, rendered.targets[3])
assert_true(index(rendered.lines, '- ⊢ Nat') >= 0)
assert_true(index(rendered.lines, '+ ⊢ Bool') >= 0)
assert_true(index(rendered.lines, 'Processing file...') >= 0)
var diagnostic_line = index(rendered.lines, '▼ warning:')
assert_equal(['  first', '  second'], rendered.lines[diagnostic_line + 1 : diagnostic_line + 2])
assert_equal({line: 4, character: 2}, rendered.targets[diagnostic_line + 1])
assert_equal(['Done'], renderer.GoalLines({goals: []}, 'Done'))
assert_equal([], renderer.GoalLines(v:null, 'Done'))
snapshot.source_loaded = false
assert_equal({lines: ['The Lean source buffer is no longer loaded.'], targets: {}},
  renderer.Build(snapshot, {}))
if !empty(v:errors)
  for error in v:errors
    echomsg error
  endfor
  cquit
endif
qa!
