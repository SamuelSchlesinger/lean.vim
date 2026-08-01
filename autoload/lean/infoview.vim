vim9script

import autoload 'lean/config.vim' as config
import autoload 'lean/lsp.vim' as lsp
import autoload 'lean/util.vim' as util

var views: dict<any> = {}

def ViewKey(): string
  return string(tabpagenr())
enddef

def CurrentView(): dict<any>
  return get(views, ViewKey(), {})
enddef

def IsVisible(view: dict<any>): bool
  return !empty(view) && bufexists(view.bufnr) && bufwinid(view.bufnr) >= 0
enddef

def SetInfoOptions(bufnr: number)
  setbufvar(bufnr, '&buftype', 'nofile')
  setbufvar(bufnr, '&bufhidden', 'hide')
  setbufvar(bufnr, '&swapfile', false)
  setbufvar(bufnr, '&modifiable', false)
  setbufvar(bufnr, '&filetype', 'leaninfo')
enddef

def InstallMappings()
  nnoremap <silent><buffer> q <Cmd>LeanInfoviewClose<CR>
  nnoremap <silent><buffer> <Esc> <Cmd>LeanGotoInfoview<CR>
  nnoremap <silent><buffer> <LocalLeader><Tab> <Cmd>LeanGotoInfoview<CR>
enddef

def CreateWindow(view: dict<any>)
  var cfg = config.Get().infoview
  var orientation = cfg.orientation
  var reuse = get(view, 'bufnr', -1) > 0 && bufexists(view.bufnr)
  if orientation ==# 'auto'
    orientation = &columns >= 120 ? 'vertical' : 'horizontal'
  endif
  if orientation ==# 'horizontal'
    if reuse
      execute $'botright sbuffer {view.bufnr}'
    else
      botright new
    endif
    execute 'resize ' .. cfg.height
  else
    if reuse
      execute $'botright vertical sbuffer {view.bufnr}'
    else
      botright vertical new
    endif
    execute 'vertical resize ' .. cfg.width
  endif
  if !reuse
    view.bufnr = bufnr()
    execute $'file [Lean\ Infoview\ {ViewKey()}]'
  endif
  view.winid = win_getid()
  SetInfoOptions(view.bufnr)
  InstallMappings()
enddef

def SetLines(view: dict<any>, lines: list<string>)
  if !bufexists(view.bufnr)
    return
  endif
  var output = empty(lines) ? [''] : lines
  setbufvar(view.bufnr, '&modifiable', true)
  setbufline(view.bufnr, 1, output)
  var old_count = len(getbufline(view.bufnr, 1, '$'))
  if old_count > len(output)
    deletebufline(view.bufnr, len(output) + 1, old_count)
  endif
  setbufvar(view.bufnr, '&modifiable', false)
  setbufvar(view.bufnr, '&modified', false)
enddef

def GoalLines(result: any): list<string>
  if type(result) != v:t_dict
    return []
  endif
  var goals = get(result, 'goals', v:null)
  if type(goals) == v:t_list
    if empty(goals)
      return ['No goals.']
    endif
    var lines: list<string> = []
    if len(goals) > 1
      add(lines, $'{len(goals)} goals')
      add(lines, '')
    endif
    for goal in goals
      if !empty(lines) && !empty(lines[-1])
        add(lines, '')
      endif
      var rendered_goal = type(goal) == v:t_string ? goal : string(goal)
      extend(lines, split(rendered_goal, "\n", true))
    endfor
    return lines
  endif
  var rendered = get(result, 'rendered', '')
  return empty(rendered) ? [] : split(rendered, "\n", true)
enddef

def DiagnosticLines(diagnostics: list<any>): list<string>
  var lines: list<string> = []
  var labels = {1: 'error', 2: 'warning', 3: 'information', 4: 'hint'}
  for diagnostic in diagnostics
    add(lines, $'▼ {get(labels, get(diagnostic, "severity", 1), "error")}:')
    extend(lines, mapnew(split(get(diagnostic, 'message', ''), "\n", true),
      (_, line) => '  ' .. line))
  endfor
  return lines
enddef

def DiffLines(before: list<string>, after: list<string>): list<string>
  if empty(before) || before ==# after
    return []
  endif
  var lines = ['Changes from diff pin:']
  var maximum = max([len(before), len(after)])
  for index in range(maximum)
    var old_line = index < len(before) ? before[index] : v:null
    var new_line = index < len(after) ? after[index] : v:null
    if old_line ==# new_line
      continue
    endif
    if type(old_line) == v:t_string
      add(lines, '- ' .. old_line)
    endif
    if type(new_line) == v:t_string
      add(lines, '+ ' .. new_line)
    endif
  endfor
  return lines
enddef

def Render(view: dict<any>)
  var lines: list<string> = []
  if !bufloaded(view.source_bufnr)
    SetLines(view, ['The Lean source buffer is no longer loaded.'])
    return
  endif

  add(lines, fnamemodify(bufname(view.source_bufnr), ':t') ..
    $'  {view.position.line + 1}:{view.position.character + 1}')
  add(lines, repeat('─', 32))

  for pin in view.pins
    add(lines, $'Pin {pin.line + 1}:{pin.character + 1}')
    extend(lines, pin.lines)
    add(lines, '')
  endfor

  var diff = DiffLines(view.diff_pin, view.goal)
  if !empty(diff)
    extend(lines, diff)
    add(lines, '')
  endif

  if view.processing && config.Get().infoview.show_processing
    add(lines, 'Processing file...')
  endif
  if !empty(view.goal)
    extend(lines, view.goal)
  elseif !view.processing && config.Get().infoview.show_no_info
    add(lines, 'No goals.')
  endif

  if !empty(view.term_goal)
    if !empty(lines) && !empty(lines[-1])
      add(lines, '')
    endif
    add(lines, 'Expected type:')
    extend(lines, view.term_goal)
  endif

  if !empty(view.diagnostics)
    if !empty(lines) && !empty(lines[-1])
      add(lines, '')
    endif
    extend(lines, DiagnosticLines(view.diagnostics))
  endif
  SetLines(view, lines)
enddef

def OnGoal(key: string, sequence: number, result: any, error: any)
  if !has_key(views, key) || views[key].sequence != sequence
    return
  endif
  var view = views[key]
  if type(error) == v:t_dict
    view.goal = [$'Goal error: {get(error, "message", string(error))}']
  else
    view.goal = GoalLines(result)
  endif
  view.processing = lsp.ProgressAt(view.source_bufnr, view.position.line)
  Render(view)
enddef

def OnTermGoal(key: string, sequence: number, result: any, error: any)
  if !has_key(views, key) || views[key].sequence != sequence
    return
  endif
  var view = views[key]
  if type(error) == v:t_dict || type(result) != v:t_dict
    view.term_goal = []
  else
    var goal = get(result, 'goal', '')
    view.term_goal = empty(goal) ? [] : split(goal, "\n", true)
  endif
  Render(view)
enddef

export def Open(bufnr: number = bufnr())
  if getbufvar(bufnr, '&filetype') !=# 'lean'
    util.Notify('the infoview can only follow a Lean buffer')
    return
  endif
  var key = ViewKey()
  var source_winid = win_getid()
  var view = get(views, key, {})
  if empty(view)
    view = {
      bufnr: -1,
      winid: -1,
      source_bufnr: bufnr,
      source_winid: source_winid,
      sequence: 0,
      timer: -1,
      pending_bufnr: -1,
      position: util.Position(bufnr),
      goal: [],
      term_goal: [],
      diagnostics: [],
      pins: [],
      diff_pin: [],
      auto_diff: false,
      paused: false,
      processing: true,
    }
    views[key] = view
  else
    view.source_bufnr = bufnr
    view.source_winid = source_winid
  endif
  if !IsVisible(view)
    CreateWindow(view)
    win_gotoid(source_winid)
  endif
  Update(bufnr)
enddef

export def Close()
  var view = CurrentView()
  if IsVisible(view)
    win_execute(bufwinid(view.bufnr), 'close')
  endif
enddef

export def CloseAll()
  for view in values(views)
    if get(view, 'bufnr', -1) <= 0
      continue
    endif
    for winid in win_findbuf(view.bufnr)
      win_execute(winid, 'close')
    endfor
  endfor
enddef

export def Toggle(bufnr: number = bufnr())
  if IsVisible(CurrentView())
    Close()
  else
    Open(bufnr)
  endif
enddef

export def GoTo()
  var view = CurrentView()
  if empty(view)
    Open()
    view = CurrentView()
  endif
  if bufnr() == view.bufnr
    if win_id2win(view.source_winid) > 0
      win_gotoid(view.source_winid)
    endif
  else
    if !IsVisible(view)
      Open(bufnr())
    endif
    win_gotoid(bufwinid(view.bufnr))
  endif
enddef

export def Update(bufnr: number = bufnr())
  var view = CurrentView()
  if empty(view) || !IsVisible(view) || bufnr != view.source_bufnr || view.paused
    return
  endif
  if getbufvar(bufnr, '&filetype') !=# 'lean'
    return
  endif
  if view.auto_diff && !empty(view.goal)
    view.diff_pin = copy(view.goal)
  endif
  view.sequence += 1
  var sequence = view.sequence
  view.position = util.Position(bufnr)
  view.processing = lsp.ProgressAt(bufnr, view.position.line)
  view.diagnostics = lsp.DiagnosticsAt(bufnr, view.position.line)
  view.goal = []
  view.term_goal = []
  Render(view)

  var params = util.PositionParams(bufnr)
  var goal_params = deepcopy(params)
  goal_params.position.character += 1
  var key = ViewKey()
  lsp.Request(bufnr, '$/lean/plainGoal', goal_params,
    (result, error) => OnGoal(key, sequence, result, error))
  lsp.Request(bufnr, '$/lean/plainTermGoal', params,
    (result, error) => OnTermGoal(key, sequence, result, error))
enddef

def TimerUpdate(key: string)
  if has_key(views, key)
    var view = views[key]
    view.timer = -1
    if view.pending_bufnr >= 0
      var bufnr = view.pending_bufnr
      view.pending_bufnr = -1
      Update(bufnr)
    endif
  endif
enddef

export def ScheduleUpdate(bufnr: number = bufnr())
  var key = ViewKey()
  if !has_key(views, key) || views[key].source_bufnr != bufnr
    return
  endif
  var view = views[key]
  var cooldown = config.Get().infoview.update_cooldown
  if cooldown == 0
    Update(bufnr)
    return
  endif
  if view.timer < 0
    # Match lean.nvim's leading edge: a deliberate cursor move updates now.
    Update(bufnr)
  else
    view.pending_bufnr = bufnr
    timer_stop(view.timer)
  endif
  # Further events restart the cooldown. The most recent suppressed update is
  # flushed after movement stops, so rapid cursor motion does not flood Lean.
  view.timer = timer_start(cooldown, (_) => TimerUpdate(key))
enddef

def OnPopupGoal(title: string, result: any, error: any)
  if type(error) == v:t_dict
    util.Popup(title, [get(error, 'message', string(error))])
  else
    util.Popup(title, GoalLines(result))
  endif
enddef

export def ShowGoal(bufnr: number = bufnr())
  var params = util.PositionParams(bufnr)
  params.position.character += 1
  lsp.Request(bufnr, '$/lean/plainGoal', params,
    (result, error) => OnPopupGoal('Lean goal', result, error))
enddef

def OnPopupTermGoal(result: any, error: any)
  if type(error) == v:t_dict
    util.Popup('Lean term goal', [get(error, 'message', string(error))])
  elseif type(result) == v:t_dict && !empty(get(result, 'goal', ''))
    util.Popup('Lean term goal', split(result.goal, "\n", true))
  endif
enddef

export def ShowTermGoal(bufnr: number = bufnr())
  lsp.Request(bufnr, '$/lean/plainTermGoal', util.PositionParams(bufnr),
    (result, error) => OnPopupTermGoal(result, error))
enddef

export def ShowLineDiagnostics(bufnr: number = bufnr())
  var diagnostics = lsp.DiagnosticsAt(bufnr, line('.') - 1)
  var lines = DiagnosticLines(diagnostics)
  if empty(lines) && lsp.ProgressAt(bufnr, line('.') - 1)
    lines = ['Processing file...']
  endif
  if empty(lines)
    lines = ['No diagnostics on this line.']
  endif
  util.Popup('Lean diagnostics', lines)
enddef

def OnPin(key: string, line_index: number, character: number, result: any, error: any)
  if !has_key(views, key) || type(error) == v:t_dict
    return
  endif
  add(views[key].pins, {
    line: line_index,
    character: character,
    lines: GoalLines(result),
  })
  Render(views[key])
enddef

export def AddPin(bufnr: number = bufnr())
  var view = CurrentView()
  if empty(view)
    Open(bufnr)
    view = CurrentView()
  endif
  var params = util.PositionParams(bufnr)
  var line_index = params.position.line
  var character = params.position.character
  params.position.character += 1
  var key = ViewKey()
  lsp.Request(bufnr, '$/lean/plainGoal', params,
    (result, error) => OnPin(key, line_index, character, result, error))
enddef

export def ClearPins()
  var view = CurrentView()
  if !empty(view)
    view.pins = []
    Render(view)
  endif
enddef

export def TogglePause()
  var view = CurrentView()
  if !empty(view)
    view.paused = !view.paused
    util.Notify(view.paused ? 'infoview updates paused' : 'infoview updates resumed', 'ModeMsg')
    if !view.paused
      Update(view.source_bufnr)
    endif
  endif
enddef

export def SetDiffPin()
  var view = CurrentView()
  if !empty(view)
    view.diff_pin = copy(view.goal)
    Render(view)
  endif
enddef

export def ClearDiffPin()
  var view = CurrentView()
  if !empty(view)
    view.diff_pin = []
    Render(view)
  endif
enddef

export def ToggleAutoDiff(clear: bool = true)
  var view = CurrentView()
  if empty(view)
    return
  endif
  view.auto_diff = !view.auto_diff
  if clear
    view.diff_pin = view.auto_diff ? copy(view.goal) : []
  endif
  util.Notify(view.auto_diff ? 'automatic diff pins enabled' : 'automatic diff pins disabled', 'ModeMsg')
  Render(view)
enddef

export def Debug()
  var view = CurrentView()
  var lines = [$'LSP: {string(lsp.Status(get(view, "source_bufnr", bufnr())))}', '', 'stderr:']
  extend(lines, lsp.Stderr())
  util.Popup('Lean debug', lines)
enddef

export def State(): dict<any>
  return deepcopy(CurrentView())
enddef

defcompile
