vim9script

if exists('g:loaded_lean_vim9')
  finish
endif
g:loaded_lean_vim9 = 1

# uri_encode() and the UTF-16 builtins first shipped as a release in Vim 9.2
# (late 9.1 patch levels also carry them); without them the modules below
# abort compilation with bare E117 errors. Refuse loudly once instead.
if !has('job') || !has('channel') || !has('popupwin') || !has('textprop')
    || !exists('*uri_encode') || !exists('*uri_decode')
    || !exists('*utf16idx') || !exists('*indexof') || !exists('*prop_add_list')
  g:lean_vim9_unsupported = 1
  echomsg 'lean.vim requires Vim 9.2 (or a late Vim 9.1 with uri_encode())'
    .. ' built with +job, +channel, +popupwin, and +textprop'
  finish
endif

command! LeanGoal call lean#Goal()
command! LeanTermGoal call lean#TermGoal()
command! LeanLineDiagnostics call lean#LineDiagnostics()
command! LeanDiagnosticsList call lean#DiagnosticsList()
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
command! LeanOutline call lean#Outline()
command! -nargs=? LeanWorkspaceSymbols call lean#WorkspaceSymbols(<q-args>)
command! LeanHealth call lean#Health()
command! -nargs=+ LeanLoogle call lean#Loogle(<q-args>)

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
command! LeanInlayHintsToggle call lean#InlayHintsToggle()

# The filetype and exists() guards keep sessions that never touch Lean from
# loading the autoload modules on ordinary window, tab, and exit events.
augroup lean_vim9
  autocmd!
  autocmd FileType lean call lean#Attach(bufnr())
  autocmd BufWinEnter,WinEnter,TabEnter * if &filetype ==# 'lean' | call lean#OnBufWinEnter(bufnr()) | endif
  autocmd CmdwinEnter * if exists('*lean#SetupCommandWindow') | call lean#SetupCommandWindow() | endif
  autocmd User LeanDiagnosticsUpdate,LeanProgressUpdate call lean#OnServerUpdate()
  autocmd WinScrolled * if exists('*lean#OnWinScrolled') | call lean#OnWinScrolled() | endif
  autocmd TabClosed * if exists('*lean#OnTabClosed') | call lean#OnTabClosed() | endif
  autocmd VimLeavePre * if exists('*lean#Stop') | call lean#Stop() | endif
augroup END
