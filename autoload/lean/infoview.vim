vim9script

import autoload 'lean/config.vim' as config
import autoload 'lean/lsp.vim' as lsp
import autoload 'lean/requests.vim' as requests
import autoload 'lean/pins.vim' as pins
import autoload 'lean/infoview_render.vim' as renderer
import autoload 'lean/util.vim' as util

var views: dict<any> = {}
var next_view_id = 1
var popup_scope = requests.NewScope()

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
  requests.Cancel(view.scope)
enddef

def CancelPinRequests(view: dict<any>)
  for pin in view.pins
    pins.Suspend(pin)
  endfor
enddef

export def RefreshPins(bufnr: number)
  for view in values(views)
    if !IsVisibleAnywhere(view)
      continue
    endif
    var Changed = function(Render, [view])
    for pin in view.pins
      if pin.bufnr == bufnr && !view.paused
        pins.Refresh(pin, Changed)
      endif
    endfor
    Render(view)
  endfor
enddef

export def InvalidatePins(bufnr: number)
  for view in values(views)
    for pin in view.pins
      if pin.bufnr == bufnr
        pins.Suspend(pin)
      endif
    endfor
  endfor
enddef

def SetSource(view: dict<any>, bufnr: number, winid: number): bool
  var changed = view.source_bufnr != bufnr || view.source_winid != winid
  if view.source_bufnr != bufnr
    CancelGoalRequests(view)
    view.sequence += 1
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
  nnoremap <silent><buffer> <CR> <Cmd>call lean#infoview#JumpToTarget()<CR>
enddef

# :close on the last window of the last tab raises E444 — reachable both
# interactively (source window closed first) and from VimLeavePre. Show an
# empty buffer there instead.
def CloseInfoWindow(winid: number)
  win_execute(winid,
    'if winnr("$") == 1 && tabpagenr("$") == 1 | enew | else | close | endif')
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
  # Long diagnostics must wrap rather than run off the edge; 'wrap' is
  # window-local, so it has to be reapplied on every (re)creation.
  setlocal wrap linebreak breakindent
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

def Snapshot(view: dict<any>): dict<any>
  var snapshot = {source_loaded: bufloaded(view.source_bufnr),
    source_name: fnamemodify(bufname(view.source_bufnr), ':t'),
    position: copy(view.position), goal: copy(view.goal), term_goal: copy(view.term_goal),
    diff_pin: copy(view.diff_pin), diagnostics: deepcopy(view.diagnostics),
    processing: view.processing, pins: []}
  var source_uri = util.UriFromBuf(view.source_bufnr)
  for live_pin in view.pins
    var pin = pins.Snapshot(live_pin)
    add(snapshot.pins, {uri: pin.uri, line: pin.line, character: pin.character,
      lines: copy(pin.lines), label: pin.uri ==# source_uri ? ''
        : fnamemodify(util.PathFromUri(pin.uri), ':~:.') .. ' '})
  endfor
  return snapshot
enddef

def Render(view: dict<any>)
  var rendered = renderer.Build(Snapshot(view), config.Get().infoview)
  view.line_targets = rendered.targets
  SetLines(view, rendered.lines)
enddef

def OnGoal(view: dict<any>, result: any, error: any)
  if type(error) == v:t_dict
    var message = get(error, 'message', string(error))
    view.goal = [$'Goal error: {type(message) == v:t_string ? message : string(message)}']
  else
    view.goal = renderer.GoalLines(result, config.Get().infoview.no_goals_text)
  endif
  view.processing = lsp.ProgressAt(view.source_bufnr, view.position.line)
  Render(view)
enddef

def OnTermGoal(view: dict<any>, result: any, error: any)
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
      scope: requests.NewScope(),
      timer: -1,
      pending_bufnr: -1,
      position: util.Position(bufnr),
      goal: [],
      term_goal: [],
      diagnostics: [],
      pins: [],
      line_targets: {},
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
  for pin in view.pins
    if !view.paused
      pins.Refresh(pin, () => Render(view))
    endif
  endfor
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
    CancelGoalRequests(view)
    CancelPinRequests(view)
  endif
  if IsVisible(view)
    CloseInfoWindow(bufwinid(view.bufnr))
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
    CancelGoalRequests(view)
    CancelPinRequests(view)
    if get(view, 'bufnr', -1) <= 0
      continue
    endif
    for winid in win_findbuf(view.bufnr)
      CloseInfoWindow(winid)
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

# Focus the window showing the view's source buffer in this tab, repairing a
# stale stored window id first. Notifies and returns false when none exists.
def GoToSource(view: dict<any>): bool
  var source_winid = view.source_winid
  if win_id2win(source_winid) == 0
      || winbufnr(win_id2win(source_winid)) != view.source_bufnr
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
    return true
  endif
  util.Notify('the infoview source window is no longer open')
  return false
enddef

# <CR> in the infoview: jump the source window to the entry under or above
# the cursor (the header, a pin, or a diagnostic).
export def JumpToTarget()
  var view = CurrentView()
  if empty(view) || bufnr() != get(view, 'bufnr', -1)
    return
  endif
  var target: any = v:null
  var best = -1
  for [key, value] in items(get(view, 'line_targets', {}))
    var lnum = str2nr(key)
    if lnum <= line('.') && lnum > best
      best = lnum
      target = value
    endif
  endfor
  if type(target) != v:t_dict
    util.Notify('nothing to jump to from this line')
    return
  endif
  if !bufloaded(view.source_bufnr) || !GoToSource(view)
    return
  endif
  if has_key(target, 'uri') && target.uri !=# util.UriFromBuf(bufnr())
    util.OpenLocation({uri: target.uri, range: {start: target}})
    return
  endif
  var lnum = min([line('$'), target.line + 1])
  cursor(lnum, util.ByteColumn(getline(lnum), target.character) + 1)
  normal! zv
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
    GoToSource(view)
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
  if !bufloaded(bufnr)
    Render(view)
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
  var context = requests.Begin(view.scope, bufnr)
  requests.Send(context, '$/lean/plainGoal', goal_params,
    (result, error) => OnGoal(view, result, error))
  requests.Send(context, '$/lean/plainTermGoal', params,
    (result, error) => OnTermGoal(view, result, error))
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

def ScheduleViewUpdate(key: string, bufnr: number)
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

export def ScheduleUpdate(bufnr: number = bufnr())
  ScheduleViewUpdate(ViewKey(), bufnr)
enddef

def OnPopupGoal(title: string, result: any, error: any)
  if type(error) == v:t_dict
    var message = get(error, 'message', string(error))
    util.Popup(title, [type(message) == v:t_string ? message : string(message)])
  else
    util.Popup(title, renderer.GoalLines(result, config.Get().infoview.no_goals_text))
  endif
enddef

export def ShowGoal(bufnr: number = bufnr())
  var context = requests.Begin(popup_scope, bufnr, true)
  var params = util.PositionParams(bufnr)
  params.position.character += 1
  requests.Send(context, '$/lean/plainGoal', params,
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
  var context = requests.Begin(popup_scope, bufnr, true)
  requests.Send(context, '$/lean/plainTermGoal', util.PositionParams(bufnr),
    (result, error) => OnPopupTermGoal(result, error))
enddef

export def ShowLineDiagnostics(bufnr: number = bufnr())
  var diagnostics = lsp.DiagnosticsAt(bufnr, line('.') - 1)
  var lines = renderer.DiagnosticLines(diagnostics)
  if empty(lines) && lsp.ProgressAt(bufnr, line('.') - 1)
    lines = ['Processing file...']
  endif
  if empty(lines)
    lines = ['No diagnostics on this line.']
  endif
  util.Popup('Lean diagnostics', lines)
enddef

export def RefreshServerState()
  for [key, view] in items(views)
    if !IsVisibleAnywhere(view)
      continue
    endif
    if !bufloaded(view.source_bufnr)
      Render(view)
      continue
    endif
    if view.paused
      continue
    endif
    var was_processing = view.processing
    view.processing = lsp.ProgressAt(view.source_bufnr, view.position.line)
    view.diagnostics = lsp.DiagnosticsAt(view.source_bufnr, view.position.line)
    if was_processing && !view.processing
      # Match lean.nvim's refresh when elaboration finishes at a pin. A
      # previous response can be empty or refer to an earlier snapshot;
      # merely removing "Processing file..." leaves it stale indefinitely.
      # Use the owning view's key so a background tab keeps its own cursor.
      ScheduleViewUpdate(key, view.source_bufnr)
    else
      Render(view)
    endif
  endfor
enddef

export def AddPin(bufnr: number = bufnr())
  if getbufvar(bufnr, '&filetype') !=# 'lean'
    util.Notify('pins can only be added from a Lean buffer')
    return
  endif
  var view = CurrentView()
  if empty(view) || !IsVisible(view) || view.source_bufnr != bufnr
    Open(bufnr)
    view = CurrentView()
    if empty(view)
      return
    endif
  endif
  var pin = pins.New(bufnr, util.Position(bufnr))
  add(view.pins, pin)
  if !view.paused
    pins.Refresh(pin, () => Render(view))
  endif
  Render(view)
enddef

export def ClearPins()
  var view = CurrentView()
  if !empty(view)
    CancelPinRequests(view)
    for pin in view.pins
      pins.Remove(pin)
    endfor
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
      CancelPinRequests(view)
    endif
    util.Notify(view.paused ? 'infoview updates paused' : 'infoview updates resumed', 'ModeMsg')
    if !view.paused
      UpdateView(ViewKey(), view.source_bufnr)
      for pin in view.pins
        pins.Refresh(pin, () => Render(view))
      endfor
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
  var state = copy(CurrentView())
  if !empty(state)
    remove(state, 'scope')
    state.pins = mapnew(state.pins, (_, pin) => pins.Snapshot(pin))
  endif
  return deepcopy(state)
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
    CancelGoalRequests(view)
    CancelPinRequests(view)
    for pin in view.pins
      pins.Remove(pin)
    endfor
    var info_bufnr = get(view, 'bufnr', -1)
    if info_bufnr > 0 && bufexists(info_bufnr)
      execute $'silent! bwipeout! {info_bufnr}'
    endif
  endfor
enddef

defcompile
