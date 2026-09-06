vim9script

# Pure text rendering: snapshots in, lines and navigation targets out.

export def GoalLines(result: any, accomplished: string): list<string>
  if type(result) != v:t_dict
    return []
  endif
  var goals = get(result, 'goals', v:null)
  if type(goals) == v:t_list
    if empty(goals)
      return [empty(accomplished) ? 'No goals.' : accomplished]
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

# Each diagnostic has a header, an indented body, and an optional jump target.
def DiagnosticBlocks(diagnostics: list<any>): list<dict<any>>
  var blocks: list<dict<any>> = []
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
    var target: dict<any> = {}
    var range = get(diagnostic, 'range', {})
    if type(range) == v:t_dict
        && type(get(range, 'start', v:null)) == v:t_dict
        && type(get(range.start, 'line', v:null)) == v:t_number
        && type(get(range.start, 'character', v:null)) == v:t_number
        && range.start.line >= 0 && range.start.character >= 0
      target = {line: range.start.line, character: range.start.character}
    endif
    add(blocks, {
      header: $'▼ {label}:',
      body: mapnew(split(message, "\n", true), (_, line) => '  ' .. line),
      target: target,
    })
  endfor
  return blocks
enddef

export def DiagnosticLines(diagnostics: list<any>): list<string>
  var lines: list<string> = []
  for block in DiagnosticBlocks(diagnostics)
    add(lines, block.header)
    extend(lines, block.body)
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

export def Build(view: dict<any>, options: dict<any>): dict<any>
  var lines: list<string> = []
  var targets: dict<any> = {}
  if !view.source_loaded
    return {lines: ['The Lean source buffer is no longer loaded.'], targets: {}}
  endif

  add(lines, view.source_name ..
    $'  {view.position.line + 1}:{view.position.character + 1}')
  targets[len(lines)] = {line: view.position.line, character: view.position.character}
  add(lines, repeat('─', 32))

  for pin in view.pins
    add(lines, $'Pin {pin.label}{pin.line + 1}:{pin.character + 1}')
    targets[len(lines)] = {line: pin.line, character: pin.character, uri: pin.uri}
    extend(lines, pin.lines)
    add(lines, '')
  endfor

  var diff = DiffLines(view.diff_pin, view.goal)
  if !empty(diff)
    extend(lines, diff)
    add(lines, '')
  endif

  if view.processing && options.show_processing
    add(lines, 'Processing file...')
  endif
  if !empty(view.goal)
    extend(lines, view.goal)
  elseif !view.processing && options.show_no_info
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
    for block in DiagnosticBlocks(view.diagnostics)
      add(lines, block.header)
      if !empty(block.target)
        targets[len(lines)] = block.target
      endif
      extend(lines, block.body)
    endfor
  endif
  return {lines: lines, targets: targets}
enddef

defcompile
