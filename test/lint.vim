vim9script

# Compile every Vim9 module; each file ends in defcompile, so sourcing it
# surfaces compile errors.  A compile failure inside defcompile does NOT
# make -es exit non-zero (or even print to stderr), so check v:errmsg after
# every file and fail explicitly.

var root = fnamemodify(expand('<sfile>'), ':p:h:h')
execute 'set runtimepath^=' .. fnameescape(root)
runtime plugin/lean.vim

var failed = false
for path in [
  'autoload/lean.vim',
  'autoload/lean/util.vim',
  'autoload/lean/config.vim',
  'autoload/lean/lsp.vim',
  'autoload/lean/infoview.vim',
  'autoload/lean/abbreviations.vim',
  'autoload/lean/completion.vim',
  'autoload/lean/inlayhints.vim',
  'autoload/lean/editor.vim',
  'autoload/lean/health.vim',
  'autoload/lean/loogle.vim',
  'indent/lean.vim',
]
  v:errmsg = ''
  execute 'source ' .. fnameescape(root .. '/' .. path)
  if !empty(v:errmsg)
    echomsg $'lint: {path}: {v:errmsg}'
    failed = true
  endif
endfor

if failed
  cquit
endif
qa!
