vim9script

var root = fnamemodify(expand('<sfile>'), ':p:h:h')
execute 'set runtimepath^=' .. fnameescape(root)

# bufnr({name}) treats the argument as a pattern: 'bracket[1].lean' matches a
# buffer named bracket1.lean. FindBuffer must resolve names exactly.
var decoy = root .. '/test/fixtures/bracket1.lean'
var bracketed = root .. '/test/fixtures/bracket[1].lean'
execute 'badd ' .. fnameescape(decoy)
assert_equal(-1, lean#util#FindBuffer(bracketed),
  'FindBuffer matched a decoy buffer through pattern interpretation')
execute 'badd ' .. fnameescape(bracketed)
var found = lean#util#FindBuffer(bracketed)
assert_true(found > 0, 'FindBuffer did not find the bracketed buffer')
assert_equal(fnamemodify(bracketed, ':p'), fnamemodify(bufname(found), ':p'),
  'FindBuffer returned the wrong buffer for a bracketed path')
assert_equal(fnamemodify(decoy, ':p'),
  fnamemodify(bufname(lean#util#FindBuffer(decoy)), ':p'),
  'FindBuffer no longer finds a plain path')
assert_equal(-1, lean#util#FindBuffer(''), 'FindBuffer accepted an empty path')
assert_equal(-1, lean#util#FindBuffer(root .. '/test/fixtures/absent.lean'),
  'FindBuffer invented a buffer for a path that was never added')

if !empty(v:errors)
  for error in v:errors
    echomsg error
  endfor
  cquit
endif
qa!
