vim9script

if exists('g:loaded_lean_vim9')
  finish
endif
g:loaded_lean_vim9 = 1

import autoload 'lean.vim' as lean

lean.Init()

command! LeanGoal call lean#Goal()
command! LeanTermGoal call lean#TermGoal()
command! LeanLineDiagnostics call lean#LineDiagnostics()
command! LeanHover call lean#Hover()
command! LeanDefinition call lean#Definition()
command! LeanDeclaration call lean#Declaration()
command! LeanTypeDefinition call lean#TypeDefinition()
command! LeanReferences call lean#References()
command! LeanRename call lean#Rename()
command! LeanCodeAction call lean#CodeAction()
command! LeanSorryFill call lean#SorryFill()

command! LeanRestartFile call lean#RestartFile()
command! LeanRefreshFileDependencies call lean#RestartFile()
command! LeanRestartServer call lean#RestartServer()
command! LeanStatus call lean#Status()
command! LeanSearchPaths call lean#SearchPaths()

command! LeanInfoviewOpen call lean#InfoviewOpen()
command! LeanInfoviewClose call lean#InfoviewClose()
command! LeanInfoviewCloseAll call lean#InfoviewCloseAll()
command! LeanInfoviewToggle call lean#InfoviewToggle()
command! LeanGotoInfoview call lean#GotoInfoview()
command! LeanInfoviewPinTogglePause call lean#InfoviewPinTogglePause()
command! LeanInfoviewAddPin call lean#InfoviewAddPin()
command! LeanInfoviewClearPins call lean#InfoviewClearPins()
command! LeanInfoviewSetDiffPin call lean#InfoviewSetDiffPin()
command! LeanInfoviewClearDiffPin call lean#InfoviewClearDiffPin()
command! LeanInfoviewToggleAutoDiffPin call lean#InfoviewToggleAutoDiffPin(true)
command! LeanInfoviewToggleNoClearAutoDiffPin call lean#InfoviewToggleAutoDiffPin(false)
command! LeanInfoviewAcceptSuggestion call lean#InfoviewAcceptSuggestion()
command! LeanInfoviewViewOptions call lean#InfoviewViewOptions()
command! LeanInfoviewEnableWidgets call lean#InfoviewWidgets(true)
command! LeanInfoviewDisableWidgets call lean#InfoviewWidgets(false)
command! LeanInfoviewOpenDebug call lean#InfoviewDebug()

command! LeanAbbreviationsReverseLookup call lean#AbbreviationsReverseLookup()
command! LeanModuleImports call lean#ModuleImports()
command! LeanModuleImportedBy call lean#ModuleImportedBy()

augroup lean_vim9
  autocmd!
  autocmd FileType lean call lean#Attach(bufnr())
  autocmd BufWinEnter,WinEnter * call lean#OnBufWinEnter(bufnr())
  autocmd TabEnter * call lean#OnBufWinEnter(bufnr())
  autocmd CmdwinEnter * call lean#SetupCommandWindow()
  autocmd User LeanDiagnosticsUpdate,LeanProgressUpdate call lean#OnServerUpdate()
  autocmd TabClosed * call lean#OnTabClosed()
  autocmd VimLeavePre * call lean#Stop()
augroup END
