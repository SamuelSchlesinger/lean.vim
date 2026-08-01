vim9script

# Syntax highlighting for the plain-text Lean infoview buffer. The patterns
# mirror exactly what autoload/lean/infoview.vim renders.

if exists('b:current_syntax')
  finish
endif

syntax match leanInfoFilename '\%1l^.*$'
syntax match leanInfoRule '^─\+$'
syntax match leanInfoPin '^Pin \d\+:\d\+$'
syntax match leanInfoGoalCount '^\d\+ goals$'
syntax match leanInfoCase '^case\s.*$'
syntax match leanInfoTurnstile '^⊢'
syntax match leanInfoHypNames '^[^ ─+▼⊢-][^:]*\ze :\%( \|$\)'
syntax match leanInfoDiffHeader '^Changes from diff pin:$'
syntax match leanInfoDiffAdd '^+ .*$'
syntax match leanInfoDiffDelete '^- .*$'
syntax match leanInfoProcessing '^Processing file\.\.\.$'
syntax match leanInfoAccomplished '^Goals accomplished.*$'
syntax match leanInfoAccomplished '^No goals\.$'
syntax match leanInfoExpected '^Expected type:$'
syntax match leanInfoError '^▼ error:$'
syntax match leanInfoWarning '^▼ warning:$'
syntax match leanInfoInformation '^▼ information:$'
syntax match leanInfoHint '^▼ hint:$'

# The diagnostic groups are shared with the sign definitions in lsp.vim;
# default-link them here too so this file works standalone.
highlight default link LeanDiagnosticError DiagnosticError
highlight default link LeanDiagnosticWarning DiagnosticWarn
highlight default link LeanDiagnosticInformation DiagnosticInfo
highlight default link LeanDiagnosticHint DiagnosticHint
highlight default link LeanGoalAccomplished DiagnosticOk

highlight default link leanInfoFilename Title
highlight default link leanInfoRule NonText
highlight default link leanInfoPin Title
highlight default link leanInfoGoalCount Title
highlight default link leanInfoCase Label
highlight default link leanInfoTurnstile Statement
highlight default link leanInfoHypNames Identifier
highlight default link leanInfoDiffHeader Title
highlight default link leanInfoDiffAdd DiffAdd
highlight default link leanInfoDiffDelete DiffDelete
highlight default link leanInfoProcessing Comment
highlight default link leanInfoAccomplished LeanGoalAccomplished
highlight default link leanInfoExpected Title
highlight default link leanInfoError LeanDiagnosticError
highlight default link leanInfoWarning LeanDiagnosticWarning
highlight default link leanInfoInformation LeanDiagnosticInformation
highlight default link leanInfoHint LeanDiagnosticHint

b:current_syntax = 'leaninfo'
