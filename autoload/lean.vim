vim9script

import autoload 'lean/abbreviations.vim' as abbreviations
import autoload 'lean/completion.vim' as completion
import autoload 'lean/config.vim' as config
import autoload 'lean/editor.vim' as editor
import autoload 'lean/health.vim' as health
import autoload 'lean/infoview.vim' as infoview
import autoload 'lean/inlayhints.vim' as inlayhints
import autoload 'lean/loogle.vim' as loogle
import autoload 'lean/lsp.vim' as lsp
import autoload 'lean/util.vim' as util

var initialized = false
var widgets_warning_shown = false
const plug_commands = [
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
const suggested_mappings = [
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
  for [plug, command] in plug_commands
    execute $'nnoremap <silent><buffer> <Plug>({plug}) <Cmd>{command}<CR>'
  endfor
enddef

export def UseSuggestedMappings()
  DefinePlugMappings()
  for [lhs, plug] in suggested_mappings
    execute $'nmap <silent><buffer> {lhs} <Plug>({plug})'
  endfor
enddef

def RemoveMappings()
  for [lhs, plug] in suggested_mappings
    var mapping = maparg(lhs, 'n', false, true)
    if !empty(mapping) && get(mapping, 'buffer', 0)
        && get(mapping, 'rhs', '') ==# $'<Plug>({plug})'
      execute $'silent! nunmap <buffer> {lhs}'
    endif
  endfor
  for [plug, command] in plug_commands
    var lhs = $'<Plug>({plug})'
    var mapping = maparg(lhs, 'n', false, true)
    if !empty(mapping) && get(mapping, 'buffer', 0)
        && get(mapping, 'rhs', '') ==# $'<Cmd>{command}<CR>'
      execute $'silent! nunmap <buffer> {lhs}'
    endif
  endfor
enddef

def AutoOpen(bufnr: number, winid: number)
  if bufloaded(bufnr) && getbufvar(bufnr, '&filetype') ==# 'lean'
      && win_id2tabwin(winid)[0] > 0
    var info = getwininfo(winid)
    if !empty(info) && info[0].bufnr == bufnr
      win_execute(winid, 'call lean#AutoOpenInfoview()')
    endif
  endif
enddef

export def AutoOpenInfoview()
  if &filetype ==# 'lean' && !infoview.HasView()
    infoview.Open(bufnr())
  endif
enddef

export def Attach(bufnr: number = bufnr())
  Init()
  if getbufvar(bufnr, 'lean_vim_attached', false)
    # Re-entering a buffer is also an opportunity to recover from an exited
    # server without reinstalling buffer-local hooks or mappings.
    lsp.Attach(bufnr)
    return
  endif
  setbufvar(bufnr, 'lean_vim_attached', true)
  DefinePlugMappings()
  abbreviations.SetupBuffer(bufnr)
  # After abbreviations: for a shared event the handlers run in registration
  # order, and completion must observe the abbreviation state v:char edits.
  completion.SetupBuffer(bufnr)
  lsp.Attach(bufnr)

  var group = $'lean_vim_buffer_{bufnr}'
  execute $'augroup {group}'
  autocmd!
  execute $'autocmd TextChanged,TextChangedI <buffer={bufnr}> call lean#OnChanged({bufnr})'
  execute $'autocmd BufWritePost <buffer={bufnr}> call lean#OnSaved({bufnr})'
  execute $'autocmd CursorMoved,CursorMovedI <buffer={bufnr}> call lean#OnCursorMoved({bufnr})'
  execute $'autocmd InsertLeave <buffer={bufnr}> call lean#OnInsertLeaveBuffer({bufnr})'
  execute $'autocmd BufFilePost <buffer={bufnr}> call lean#OnFileRenamed({bufnr})'
  execute $'autocmd BufUnload <buffer={bufnr}> call lean#OnUnload({bufnr})'
  augroup END

  if config.Get().mappings
    UseSuggestedMappings()
  endif
  if config.Get().infoview.autoopen && !infoview.HasView()
    var winid = win_getid()
    timer_start(0, (_) => AutoOpen(bufnr, winid))
  endif
enddef

export def OnBufWinEnter(bufnr: number)
  if getbufvar(bufnr, '&filetype') !=# 'lean'
    return
  endif
  Attach(bufnr)
  # Progress signs only decorate visible spans; a re-displayed buffer needs
  # its cached decorations back.
  lsp.RefreshProgress(bufnr)
  if infoview.HasView()
    infoview.Follow(bufnr, win_getid())
  endif
  if config.Get().infoview.autoopen && !infoview.HasView()
    var winid = win_getid()
    timer_start(0, (_) => AutoOpen(bufnr, winid))
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

export def OnFileRenamed(bufnr: number)
  lsp.Attach(bufnr)
  infoview.ScheduleUpdate(bufnr)
enddef

export def OnCursorMoved(bufnr: number)
  infoview.ScheduleUpdate(bufnr)
enddef

export def OnInsertLeaveBuffer(bufnr: number)
  inlayhints.OnInsertLeave(bufnr)
enddef

export def OnWinScrolled()
  inlayhints.OnWinScrolled()
  lsp.OnWinScrolled()
enddef

export def InlayHintsToggle()
  inlayhints.Toggle()
enddef

export def OnUnload(bufnr: number)
  lsp.Detach(bufnr)
enddef

export def Detach(bufnr: number = bufnr())
  lsp.Detach(bufnr)
  abbreviations.TeardownBuffer(bufnr)
  completion.TeardownBuffer(bufnr)
  var group = $'lean_vim_buffer_{bufnr}'
  execute $'augroup {group}'
  autocmd!
  augroup END
  if bufnr == bufnr()
    RemoveMappings()
  endif
  setbufvar(bufnr, 'lean_vim_attached', false)
enddef

export def OnTabClosed()
  timer_start(0, (_) => infoview.PruneClosedTabs())
enddef

export def OnServerUpdate()
  # Diagnostics and progress already arrived in local caches. Re-render those
  # fields without issuing redundant goal and term-goal requests.
  infoview.RefreshServerState()
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

export def DiagnosticsList()
  editor.DiagnosticsList()
enddef

export def Outline()
  editor.Outline()
enddef

export def WorkspaceSymbols(query: string)
  editor.WorkspaceSymbols(query)
enddef

export def Health()
  health.Report()
enddef

export def Loogle(query: string)
  loogle.Search(query)
enddef

# For 'statusline' via %{lean#StatuslineProgress()}: elaboration percent and
# diagnostic counts for attached Lean buffers, an empty string elsewhere.
export def StatuslineProgress(): string
  var bufnr = bufnr()
  if !getbufvar(bufnr, 'lean_lsp_attached', false)
    return ''
  endif
  var parts: list<string> = []
  var summary = lsp.ProgressSummary(bufnr)
  if summary.processing
    add(parts, $'⋯{summary.percent}%')
  endif
  var counts = lsp.DiagnosticCounts(bufnr)
  if counts.error > 0
    add(parts, $'E:{counts.error}')
  endif
  if counts.warning > 0
    add(parts, $'W:{counts.warning}')
  endif
  return join(parts, ' ')
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
  infoview.ScheduleUpdate(bufnr())
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
