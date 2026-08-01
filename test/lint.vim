vim9script

# Compile every Vim9 module; each file ends in defcompile, so sourcing it
# surfaces compile errors and fails the run.

var root = fnamemodify(expand('<sfile>'), ':p:h:h')
execute 'set runtimepath^=' .. fnameescape(root)
runtime plugin/lean.vim

for path in [
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
  execute 'source ' .. fnameescape(root .. '/' .. path)
endfor

qa!
