vim9script

var root = fnamemodify(expand('<sfile>'), ':p:h:h')
execute 'set runtimepath^=' .. fnameescape(root)
import autoload 'lean/util.vim' as util

set hidden
highlight LeanTestEdit cterm=bold
prop_type_add('LeanTestEdit', {highlight: 'LeanTestEdit'})
const original = ['before', 'α😊old', 'remove', 'after']

def Properties(bufnr: number): list<any>
  return mapnew(prop_list(1, {bufnr: bufnr, end_lnum: -1}), (_, prop) =>
    [prop.id, prop.lnum, prop.col, prop.length])
enddef

def CheckEdit(label: string, span: list<number>, new_text: string,
    expected: list<string>, retained: list<list<number>>, hidden: bool,
    endofline: bool = true)
  enew!
  execute 'file ' .. fnameescape(root .. '/test/fixtures/TextEdits.lean')
  setline(1, original)
  setlocal endofline
  var target = bufnr()
  for index in range(len(original))
    prop_add(index + 1, 1, {type: 'LeanTestEdit', id: index + 1,
      length: strlen(original[index])})
  endfor
  var prepared = util.PrepareTextEdits(util.UriFromBuf(target), [{
    range: {start: {line: span[0], character: span[1]},
      end: {line: span[2], character: span[3]}},
    newText: new_text,
  }])
  # Separate fixture setup from the edit's undo block.
  &g:undolevels = &g:undolevels
  if hidden
    enew!
    setline(1, 'unrelated buffer')
  endif
  var current = bufnr()
  var view = winsaveview()
  var tick = getbufvar(target, 'changedtick')
  assert_true(util.ApplyPreparedTextEdits(prepared), label)
  assert_equal(current, bufnr(), label .. ': changed the active buffer')
  assert_equal(expected, getbufline(target, 1, '$'), label .. ': wrong text')
  assert_equal(endofline, !!getbufvar(target, '&endofline'), label .. ': wrong final newline')
  var expected_properties = mapnew(retained, (_, location) =>
    [location[0], location[1], 1, strlen(original[location[0] - 1])])
  assert_equal(expected_properties, Properties(target), label .. ': lost unchanged properties')
  if hidden
    assert_equal(view, winsaveview(), label .. ': moved another buffer view')
    assert_equal(['unrelated buffer'], getline(1, '$'), label .. ': changed another buffer')
    execute 'bwipeout! ' .. current
  endif
  execute 'buffer ' .. target
  if expected ==# original
    if endofline
      assert_equal(tick, b:changedtick, label .. ': no-op edit changed the buffer')
    endif
  else
    undo
    assert_equal(original, getline(1, '$'), label .. ': one undo did not restore all lines')
    redo
    assert_equal(expected, getline(1, '$'), label .. ': one redo did not restore the edit')
  endif
  # Rollback uses the same helper and must leave the outside properties alone.
  assert_true(util.RestorePreparedTextEdits(prepared), label .. ': restore failed')
  assert_equal(join(original, "\n") .. "\n", util.BufText(target), label .. ': restore changed text')
  for location in retained
    assert_true(index(Properties(target), [location[0], location[0], 1,
      strlen(original[location[0] - 1])]) >= 0, label .. ': restore lost an outside property')
  endfor
  bwipeout!
enddef

for hidden in [false, true]
  CheckEdit('Unicode replacement', [1, 3, 1, 6], 'new',
    ['before', 'α😊new', 'remove', 'after'], [[1, 1], [3, 3], [4, 4]], hidden)
  CheckEdit('growing replacement', [1, 3, 1, 6], "new\nadded",
    ['before', 'α😊new', 'added', 'remove', 'after'], [[1, 1], [3, 4], [4, 5]], hidden)
  CheckEdit('shrinking replacement', [1, 0, 3, 0], "new\n",
    ['before', 'new', 'after'], [[1, 1], [4, 3]], hidden)
  CheckEdit('middle insertion', [1, 0, 1, 0], "added\n",
    ['before', 'added', 'α😊old', 'remove', 'after'], [[1, 1], [2, 3], [3, 4], [4, 5]], hidden)
  CheckEdit('first-line insertion', [0, 0, 0, 0], "added\n",
    ['added'] + original, [[1, 2], [2, 3], [3, 4], [4, 5]], hidden)
  CheckEdit('last-line insertion', [4, 0, 4, 0], "added\n",
    original + ['added'], [[1, 1], [2, 2], [3, 3], [4, 4]], hidden)
  CheckEdit('middle deletion', [1, 0, 3, 0], '',
    ['before', 'after'], [[1, 1], [4, 2]], hidden)
  CheckEdit('last-line deletion', [2, 0, 4, 0], '',
    ['before', 'α😊old'], [[1, 1], [2, 2]], hidden)
  CheckEdit('empty document', [0, 0, 4, 0], '', [''], [], hidden, false)
  CheckEdit('no-op', [1, 3, 1, 6], 'old', original,
    [[1, 1], [2, 2], [3, 3], [4, 4]], hidden)
  CheckEdit('final newline only', [3, 5, 4, 0], '', original,
    [[1, 1], [2, 2], [3, 3], [4, 4]], hidden, false)
endfor

if !empty(v:errors)
  for error in v:errors
    echomsg error
  endfor
  cquit
endif
qa!
