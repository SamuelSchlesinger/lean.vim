vim9script

import autoload 'lean/abbreviations.vim' as abbreviations
import autoload 'lean/config.vim' as config
import autoload 'lean/editor.vim' as editor
import autoload 'lean/infoview.vim' as infoview
import autoload 'lean/lsp.vim' as lsp
import autoload 'lean/util.vim' as util

var initialized = false
var widgets_warning_shown = false

export def Init()
  if initialized
    return
  endif
  initialized = true
  if !has('vim9script') || !has('job') || !has('channel') || !has('popupwin') || !has('textprop')
    util.Notify('requires Vim 9 with +job, +channel, +popupwin, and +textprop', 'ErrorMsg')
  endif
enddef

def DefinePlugMappings()
  var plugs = [
    ['LeanInfoviewToggle', 'LeanInfoviewToggle'],
    ['LeanInfoviewPinTogglePause', 'LeanInfoviewPinTogglePause'],
    ['LeanInfoviewAddPin', 'LeanInfoviewAddPin'],
    ['LeanInfoviewClearPins', 'LeanInfoviewClearPins'],
    ['LeanInfoviewSetDiffPin', 'LeanInfoviewSetDiffPin'],
    ['LeanInfoviewClearDiffPin', 'LeanInfoviewClearDiffPin'],
    ['LeanInfoviewToggleAutoDiffPin', 'LeanInfoviewToggleAutoDiffPin'],
    ['LeanInfoviewToggleNoClearAutoDiffPin', 'LeanInfoviewToggleNoClearAutoDiffPin'],
    ['LeanInfoviewViewOptions', 'LeanInfoviewViewOptions'],
    ['LeanInfoviewEnableWidgets', 'LeanInfoviewEnableWidgets'],
    ['LeanInfoviewDisableWidgets', 'LeanInfoviewDisableWidgets'],
    ['LeanGotoInfoview', 'LeanGotoInfoview'],
    ['LeanInfoviewAcceptSuggestion', 'LeanInfoviewAcceptSuggestion'],
    ['LeanAbbreviationsReverseLookup', 'LeanAbbreviationsReverseLookup'],
    ['LeanRestartFile', 'LeanRestartFile'],
    ['LeanHover', 'LeanHover'],
    ['LeanGoal', 'LeanGoal'],
    ['LeanCodeAction', 'LeanCodeAction'],
  ]
  for [plug, command] in plugs
    execute $'nnoremap <silent><buffer> <Plug>({plug}) <Cmd>{command}<CR>'
  endfor
enddef

export def UseSuggestedMappings()
  DefinePlugMappings()
  var mappings = [
    ['<LocalLeader>i', 'LeanInfoviewToggle'],
    ['<LocalLeader>p', 'LeanInfoviewPinTogglePause'],
    ['<LocalLeader>x', 'LeanInfoviewAddPin'],
    ['<LocalLeader>c', 'LeanInfoviewClearPins'],
    ['<LocalLeader>dx', 'LeanInfoviewSetDiffPin'],
    ['<LocalLeader>dc', 'LeanInfoviewClearDiffPin'],
    ['<LocalLeader>dd', 'LeanInfoviewToggleAutoDiffPin'],
    ['<LocalLeader>dt', 'LeanInfoviewToggleNoClearAutoDiffPin'],
    ['<LocalLeader>v', 'LeanInfoviewViewOptions'],
    ['<LocalLeader>w', 'LeanInfoviewEnableWidgets'],
    ['<LocalLeader>W', 'LeanInfoviewDisableWidgets'],
    ['<LocalLeader><Tab>', 'LeanGotoInfoview'],
    ['<LocalLeader>s', 'LeanInfoviewAcceptSuggestion'],
    ["<LocalLeader>\\", 'LeanAbbreviationsReverseLookup'],
    ['<LocalLeader>r', 'LeanRestartFile'],
    ['<LocalLeader>g', 'LeanGoal'],
    ['<LocalLeader>a', 'LeanCodeAction'],
    ['K', 'LeanHover'],
  ]
  for [lhs, plug] in mappings
    execute $'nmap <silent><buffer> {lhs} <Plug>({plug})'
  endfor
enddef

def AutoOpen(bufnr: number)
  if bufloaded(bufnr) && getbufvar(bufnr, '&filetype') ==# 'lean'
    var windows = win_findbuf(bufnr)
    if !empty(windows)
      win_execute(windows[0], 'call lean#InfoviewOpen()')
    endif
  endif
enddef

export def Attach(bufnr: number = bufnr())
  Init()
  if getbufvar(bufnr, 'lean_vim_attached', false)
    return
  endif
  setbufvar(bufnr, 'lean_vim_attached', true)
  DefinePlugMappings()
  abbreviations.SetupBuffer(bufnr)
  lsp.Attach(bufnr)

  var group = $'lean_vim_buffer_{bufnr}'
  execute $'augroup {group}'
  autocmd!
  execute $'autocmd TextChanged,TextChangedI <buffer={bufnr}> call lean#OnChanged({bufnr})'
  execute $'autocmd BufWritePost <buffer={bufnr}> call lean#OnSaved({bufnr})'
  execute $'autocmd CursorMoved,CursorMovedI <buffer={bufnr}> call lean#OnCursorMoved({bufnr})'
  execute $'autocmd BufUnload <buffer={bufnr}> call lean#OnUnload({bufnr})'
  augroup END

  if config.Get().mappings
    UseSuggestedMappings()
  endif
  if config.Get().infoview.autoopen
    timer_start(0, (_) => AutoOpen(bufnr))
  endif
enddef

export def OnChanged(bufnr: number)
  lsp.DidChange(bufnr)
  infoview.ScheduleUpdate(bufnr)
enddef

export def OnSaved(bufnr: number)
  lsp.DidSave(bufnr)
  infoview.ScheduleUpdate(bufnr)
enddef

export def OnCursorMoved(bufnr: number)
  infoview.ScheduleUpdate(bufnr)
enddef

export def OnUnload(bufnr: number)
  lsp.Detach(bufnr)
enddef

export def OnServerUpdate()
  if &filetype ==# 'lean'
    infoview.ScheduleUpdate(bufnr())
  endif
enddef

export def SetupCommandWindow()
  var previous_buffer = winbufnr(winnr('#'))
  if previous_buffer > 0 && getbufvar(previous_buffer, '&filetype') ==# 'lean'
    abbreviations.SetupBuffer(bufnr())
  endif
enddef

export def Stop()
  infoview.CloseAll()
  lsp.StopAll()
enddef

export def Goal()
  infoview.ShowGoal()
enddef

export def TermGoal()
  infoview.ShowTermGoal()
enddef

export def LineDiagnostics()
  infoview.ShowLineDiagnostics()
enddef

export def Hover()
  editor.Hover()
enddef

export def Definition()
  editor.Goto('textDocument/definition')
enddef

export def Declaration()
  editor.Goto('textDocument/declaration')
enddef

export def TypeDefinition()
  editor.Goto('textDocument/typeDefinition')
enddef

export def References()
  editor.References()
enddef

export def Rename()
  editor.Rename()
enddef

export def CodeAction()
  editor.CodeAction()
enddef

export def SorryFill()
  editor.SorryFill()
enddef

export def ModuleImports()
  editor.ModuleHierarchy('imports')
enddef

export def ModuleImportedBy()
  editor.ModuleHierarchy('imported_by')
enddef

export def SearchPaths()
  editor.ShowSearchPaths()
enddef

export def RestartFile()
  lsp.RestartFile(bufnr())
  infoview.ScheduleUpdate(bufnr())
enddef

export def RestartServer()
  lsp.RestartServer(bufnr())
enddef

export def Status()
  util.Popup('Lean status', split(string(lsp.Status(bufnr())), "\n", true))
enddef

export def InfoviewOpen()
  infoview.Open()
enddef

export def InfoviewClose()
  infoview.Close()
enddef

export def InfoviewCloseAll()
  infoview.CloseAll()
enddef

export def InfoviewToggle()
  infoview.Toggle()
enddef

export def GotoInfoview()
  infoview.GoTo()
enddef

export def InfoviewAddPin()
  infoview.AddPin()
enddef

export def InfoviewClearPins()
  infoview.ClearPins()
enddef

export def InfoviewPinTogglePause()
  infoview.TogglePause()
enddef

export def InfoviewSetDiffPin()
  infoview.SetDiffPin()
enddef

export def InfoviewClearDiffPin()
  infoview.ClearDiffPin()
enddef

export def InfoviewToggleAutoDiffPin(clear: bool = true)
  infoview.ToggleAutoDiff(clear)
enddef

export def InfoviewAcceptSuggestion()
  editor.CodeAction()
enddef

export def InfoviewViewOptions()
  var cfg = config.Get().infoview
  util.Popup('Lean infoview options', [
    $'orientation: {cfg.orientation}',
    $'auto-open: {cfg.autoopen}',
    $'show processing: {cfg.show_processing}',
    'ProofWidgets: unavailable in Vim; plain goals are enabled.',
  ])
enddef

export def InfoviewWidgets(_enabled: bool)
  if !widgets_warning_shown
    widgets_warning_shown = true
    util.Notify('ProofWidgets need Neovim UI primitives; this port displays plain goals and diagnostics')
  endif
enddef

export def InfoviewDebug()
  infoview.Debug()
enddef

export def AbbreviationsReverseLookup()
  abbreviations.ReverseLookup()
enddef

export def CurrentSearchPaths(): list<string>
  return editor.SearchPaths()
enddef

export def LspStatus(): dict<any>
  return lsp.Status(bufnr())
enddef

export def InfoviewState(): dict<any>
  return infoview.State()
enddef

defcompile
