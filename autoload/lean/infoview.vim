vim9script

import autoload 'lean/config.vim' as config
import autoload 'lean/lsp.vim' as lsp
import autoload 'lean/util.vim' as util

var views: dict<any> = {}
var next_view_id = 1

def ViewKey(): string
  var tabnr = tabpagenr()
  var key = gettabvar(tabnr, 'lean_infoview_key', '')
  if empty(key)
    key = string(next_view_id)
    next_view_id += 1
    settabvar(tabnr, 'lean_infoview_key', key)
  endif
  return key
enddef

def CurrentView(): dict<any>
  return get(views, ViewKey(), {})
enddef

def IsVisible(view: dict<any>): bool
  return !empty(view) && bufexists(view.bufnr) && bufwinid(view.bufnr) >= 0
enddef

def IsVisibleAnywhere(view: dict<any>): bool
  return !empty(view) && bufexists(view.bufnr) && !empty(win_findbuf(view.bufnr))
enddef

def CancelGoalRequests(view: dict<any>)
  for field in ['goal_request', 'term_request']
    var request_id = get(view, field, -1)
    if request_id > 0
      lsp.Cancel(view.source_bufnr, request_id)
    endif
    view[field] = -1
  endfor
enddef

def CancelPinRequests(view: dict<any>)
  for request_id in get(view, 'pin_requests', [])
    lsp.Cancel(view.source_bufnr, request_id)
  endfor
  view.pin_requests = []
enddef

def SetSource(view: dict<any>, bufnr: number, winid: number): bool
  var changed = view.source_bufnr != bufnr || view.source_winid != winid
  if view.source_bufnr != bufnr
    CancelGoalRequests(view)
    CancelPinRequests(view)
    view.sequence += 1
    view.pin_generation += 1
  endif
  view.source_bufnr = bufnr
  view.source_winid = winid
  return changed
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
  return type(rendered) == v:t_string && !empty(rendered)
    ? split(rendered, "\n", true)
    : []
enddef

def DiagnosticLines(diagnostics: list<any>): list<string>
  var lines: list<string> = []
  var labels = {1: 'error', 2: 'warning', 3: 'information', 4: 'hint'}
  for diagnostic in diagnostics
    if type(diagnostic) != v:t_dict
      continue
    endif
    var severity = get(diagnostic, 'severity', 1)
    var label = type(severity) == v:t_number
      ? get(labels, severity, 'error')
      : 'error'
    var message = get(diagnostic, 'message', '')
    if type(message) != v:t_string
      continue
    endif
    add(lines, $'▼ {label}:')
    extend(lines, mapnew(split(message, "\n", true),
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

def OnGoal(key: string, sequence: number, request_id: number,
    result: any, error: any)
  if !has_key(views, key) || views[key].sequence != sequence
    return
  endif
  var view = views[key]
  if view.goal_request == request_id
    view.goal_request = -1
  endif
  if type(error) == v:t_dict
    var message = get(error, 'message', string(error))
    view.goal = [$'Goal error: {type(message) == v:t_string ? message : string(message)}']
  else
    view.goal = GoalLines(result)
  endif
  view.processing = lsp.ProgressAt(view.source_bufnr, view.position.line)
  Render(view)
enddef

def OnTermGoal(key: string, sequence: number, request_id: number,
    result: any, error: any)
  if !has_key(views, key) || views[key].sequence != sequence
    return
  endif
  var view = views[key]
  if view.term_request == request_id
    view.term_request = -1
  endif
  if type(error) == v:t_dict || type(result) != v:t_dict
    view.term_goal = []
  else
    var goal = get(result, 'goal', '')
    view.term_goal = type(goal) == v:t_string && !empty(goal)
      ? split(goal, "\n", true)
      : []
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
      goal_request: -1,
      term_request: -1,
      timer: -1,
      pending_bufnr: -1,
      position: util.Position(bufnr),
      goal: [],
      term_goal: [],
      diagnostics: [],
      pins: [],
      pin_generation: 0,
      pin_requests: [],
      diff_pin: [],
      auto_diff: false,
      paused: false,
      processing: true,
    }
    views[key] = view
  else
    SetSource(view, bufnr, source_winid)
  endif
  if !IsVisible(view)
    CreateWindow(view)
    win_gotoid(source_winid)
  endif
  Update(bufnr)
enddef

# Follow a Lean window which became active without reopening an infoview that
# the user explicitly closed. This matters when multiple Lean buffers remain
# visible in splits: switching windows emits WinEnter but not BufWinEnter.
export def Follow(bufnr: number, winid: number = win_getid())
  if getbufvar(bufnr, '&filetype') !=# 'lean'
    return
  endif
  var key = ViewKey()
  var view = get(views, key, {})
  if empty(view) || !IsVisible(view)
    return
  endif
  var info = getwininfo(winid)
  if empty(info) || info[0].bufnr != bufnr
    return
  endif
  if SetSource(view, bufnr, winid)
    UpdateView(key, bufnr)
  endif
enddef

export def Close()
  var view = CurrentView()
  if !empty(view)
    if get(view, 'timer', -1) >= 0
      timer_stop(view.timer)
      view.timer = -1
    endif
    view.pending_bufnr = -1
    view.sequence += 1
    view.pin_generation += 1
    CancelGoalRequests(view)
    CancelPinRequests(view)
  endif
  if IsVisible(view)
    win_execute(bufwinid(view.bufnr), 'close')
  endif
enddef

export def CloseAll()
  for view in values(views)
    if get(view, 'timer', -1) >= 0
      timer_stop(view.timer)
      view.timer = -1
    endif
    view.pending_bufnr = -1
    view.sequence += 1
    view.pin_generation += 1
    CancelGoalRequests(view)
    CancelPinRequests(view)
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
    if empty(view)
      return
    endif
  endif
  if bufnr() == view.bufnr
    var source_winid = view.source_winid
    if win_id2win(source_winid) == 0 || winbufnr(win_id2win(source_winid)) != view.source_bufnr
      source_winid = -1
      for candidate in win_findbuf(view.source_bufnr)
        if win_id2tabwin(candidate)[0] == tabpagenr()
          source_winid = candidate
          break
        endif
      endfor
    endif
    if source_winid > 0
      view.source_winid = source_winid
      win_gotoid(source_winid)
    else
      util.Notify('the infoview source window is no longer open')
    endif
  else
    if &filetype ==# 'lean'
      SetSource(view, bufnr(), win_getid())
      Update(bufnr())
    endif
    if !IsVisible(view)
      Open(bufnr())
    endif
    win_gotoid(bufwinid(view.bufnr))
  endif
enddef

def UpdateView(key: string, bufnr: number)
  if !has_key(views, key)
    return
  endif
  var view = views[key]
  if !IsVisibleAnywhere(view) || bufnr != view.source_bufnr || view.paused
    return
  endif
  if getbufvar(bufnr, '&filetype') !=# 'lean'
    return
  endif
  var current_key = gettabvar(tabpagenr(), 'lean_infoview_key', '')
  if bufnr == bufnr() && current_key ==# key
    view.source_winid = win_getid()
  endif
  if view.auto_diff && !empty(view.goal)
    view.diff_pin = copy(view.goal)
  endif
  CancelGoalRequests(view)
  view.sequence += 1
  var sequence = view.sequence
  var source_line = view.position.line + 1
  var source_column = 0
  var found_source_cursor = false
  var window_info = getwininfo(view.source_winid)
  if !empty(window_info) && window_info[0].bufnr == bufnr
    var source_cursor = getcurpos(view.source_winid)
    if source_cursor[1] > 0
      source_line = source_cursor[1]
      source_column = max([0, source_cursor[2] - 1])
      found_source_cursor = true
    endif
  elseif bufnr == bufnr() && current_key ==# key
    source_line = line('.')
    source_column = col('.') - 1
    found_source_cursor = true
  endif
  if found_source_cursor
    view.position = util.Position(bufnr, source_line, source_column)
  endif
  view.processing = lsp.ProgressAt(bufnr, view.position.line)
  view.diagnostics = lsp.DiagnosticsAt(bufnr, view.position.line)
  view.goal = []
  view.term_goal = []
  Render(view)

  var params = {
    textDocument: {uri: util.UriFromBuf(bufnr)},
    position: copy(view.position),
  }
  var goal_params = deepcopy(params)
  goal_params.position.character += 1
  var goal_request = -1
  goal_request = lsp.Request(bufnr, '$/lean/plainGoal', goal_params,
    (result, error) => OnGoal(key, sequence, goal_request, result, error))
  view.goal_request = goal_request
  var term_request = -1
  term_request = lsp.Request(bufnr, '$/lean/plainTermGoal', params,
    (result, error) => OnTermGoal(key, sequence, term_request, result, error))
  view.term_request = term_request
enddef

export def Update(bufnr: number = bufnr())
  UpdateView(ViewKey(), bufnr)
enddef

def TimerUpdate(key: string)
  if has_key(views, key)
    var view = views[key]
    view.timer = -1
    if view.pending_bufnr >= 0
      var bufnr = view.pending_bufnr
      view.pending_bufnr = -1
      UpdateView(key, bufnr)
    endif
  endif
enddef

export def ScheduleUpdate(bufnr: number = bufnr())
  var key = ViewKey()
  if !has_key(views, key) || views[key].source_bufnr != bufnr
    return
  endif
  var view = views[key]
  if view.paused || !IsVisibleAnywhere(view)
    return
  endif
  var cooldown = config.Get().infoview.update_cooldown
  if cooldown == 0
    UpdateView(key, bufnr)
    return
  endif
  if view.timer < 0
    # Match lean.nvim's leading edge: a deliberate cursor move updates now.
    UpdateView(key, bufnr)
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
    var message = get(error, 'message', string(error))
    util.Popup(title, [type(message) == v:t_string ? message : string(message)])
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
    var message = get(error, 'message', string(error))
    util.Popup('Lean term goal', [type(message) == v:t_string ? message : string(message)])
  elseif type(result) == v:t_dict
    var goal = get(result, 'goal', '')
    if type(goal) == v:t_string && !empty(goal)
      util.Popup('Lean term goal', split(goal, "\n", true))
    endif
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

export def RefreshServerState()
  for view in values(views)
    if view.paused || !bufloaded(view.source_bufnr)
      continue
    endif
    view.processing = lsp.ProgressAt(view.source_bufnr, view.position.line)
    view.diagnostics = lsp.DiagnosticsAt(view.source_bufnr, view.position.line)
    Render(view)
  endfor
enddef

def OnPin(key: string, source_bufnr: number, generation: number,
    request_id: number, line_index: number, character: number,
    result: any, error: any)
  if !has_key(views, key)
    return
  endif
  var view = views[key]
  var request_index = index(view.pin_requests, request_id)
  if request_index >= 0
    remove(view.pin_requests, request_index)
  endif
  if type(error) == v:t_dict
    return
  endif
  if view.source_bufnr != source_bufnr || view.pin_generation != generation
    return
  endif
  add(view.pins, {
    line: line_index,
    character: character,
    lines: GoalLines(result),
  })
  Render(view)
enddef

export def AddPin(bufnr: number = bufnr())
  if getbufvar(bufnr, '&filetype') !=# 'lean'
    util.Notify('pins can only be added from a Lean buffer')
    return
  endif
  var view = CurrentView()
  if empty(view)
    Open(bufnr)
    view = CurrentView()
    if empty(view)
      return
    endif
  endif
  var params = util.PositionParams(bufnr)
  var line_index = params.position.line
  var character = params.position.character
  params.position.character += 1
  var key = ViewKey()
  var generation = view.pin_generation
  var request_id = -1
  request_id = lsp.Request(bufnr, '$/lean/plainGoal', params,
    (result, error) => OnPin(key, bufnr, generation, request_id,
      line_index, character, result, error))
  if request_id > 0
    add(view.pin_requests, request_id)
  endif
enddef

export def ClearPins()
  var view = CurrentView()
  if !empty(view)
    view.pin_generation += 1
    CancelPinRequests(view)
    view.pins = []
    Render(view)
  endif
enddef

export def TogglePause()
  var view = CurrentView()
  if !empty(view)
    view.paused = !view.paused
    if view.paused
      if view.timer >= 0
        timer_stop(view.timer)
        view.timer = -1
      endif
      view.pending_bufnr = -1
      view.sequence += 1
      CancelGoalRequests(view)
    endif
    util.Notify(view.paused ? 'infoview updates paused' : 'infoview updates resumed', 'ModeMsg')
    if !view.paused
      UpdateView(ViewKey(), view.source_bufnr)
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

export def HasView(): bool
  return !empty(CurrentView())
enddef

export def PruneClosedTabs()
  var live: dict<bool> = {}
  for tabnr in range(1, tabpagenr('$'))
    var key = gettabvar(tabnr, 'lean_infoview_key', '')
    if !empty(key)
      live[key] = true
    endif
  endfor
  for key in copy(keys(views))
    if has_key(live, key)
      continue
    endif
    var view = remove(views, key)
    if get(view, 'timer', -1) >= 0
      timer_stop(view.timer)
    endif
    view.sequence += 1
    view.pin_generation += 1
    CancelGoalRequests(view)
    CancelPinRequests(view)
    var info_bufnr = get(view, 'bufnr', -1)
    if info_bufnr > 0 && bufexists(info_bufnr)
      execute $'silent! bwipeout! {info_bufnr}'
    endif
  endfor
enddef

defcompile
