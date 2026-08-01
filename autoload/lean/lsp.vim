vim9script

import autoload 'lean/config.vim' as config
import autoload 'lean/inlayhints.vim' as inlayhints
import autoload 'lean/util.vim' as util

# A deliberately small LSP 3.17 client for Lean.  Vim has jobs, channels,
# popups, signs, and text properties, but (unlike Neovim) no built-in LSP
# client.  Keeping this transport Lean-specific makes its behavior auditable.

var servers: dict<any> = {}
var buffer_roots: dict<string> = {}
var change_timers: dict<any> = {}
var last_change_flush_ms: dict<float> = {}
var diagnostics_by_uri: dict<any> = {}
var progress_by_uri: dict<any> = {}
var bufnr_by_uri: dict<number> = {}
var failed_since_ms: dict<float> = {}
var progress_timers: dict<number> = {}
var semantic_timers: dict<number> = {}
var signs_initialized = false
var stderr_history: list<string> = []
var next_request_id = 1

# Window switches re-attach buffers, which restarts a dead server. Without a
# backoff, a missing lean binary or a crash-looping server would respawn (and
# renotify) on every WinEnter.
const RESTART_BACKOFF_MS = 30000.0

def NowMs(): float
  return reltimefloat(reltime()) * 1000
enddef

# bufnr({path}) matches patterns, not exact names; prefer the URIs this
# client opened itself and fall back to an exact whole-list scan.
def BufnrForUri(uri: string): number
  var bufnr = get(bufnr_by_uri, uri, -1)
  if bufnr > 0 && bufexists(bufnr) && util.UriFromBuf(bufnr) ==# uri
    return bufnr
  endif
  return util.FindBuffer(util.PathFromUri(uri))
enddef

def ForgetUri(uri: string, bufnr: number)
  if !empty(uri) && get(bufnr_by_uri, uri, -1) == bufnr
    remove(bufnr_by_uri, uri)
  endif
enddef

def AddHistory(message: string)
  if empty(message)
    return
  endif
  add(stderr_history, message)
  if len(stderr_history) > 200
    remove(stderr_history, 0, len(stderr_history) - 201)
  endif
enddef

def IsCurrentServer(server: dict<any>): bool
  var root = get(server, 'root', '')
  return !empty(root) && has_key(servers, root) && servers[root] is server
enddef

def FailRequests(server: dict<any>, message: string)
  var error = {code: -32097, message: message}
  var pending = values(copy(server.pending))
  server.pending = {}
  var queued = server.queue
  server.queue = []
  for callback in pending
    if type(callback) == v:t_func
      try
        call(callback, [v:null, error])
      catch
        AddHistory($'request failure callback raised: {v:exception}')
      endtry
    endif
  endfor
  for request in queued
    if type(get(request, 'callback', v:null)) == v:t_func
      try
        call(request.callback, [v:null, error])
      catch
        AddHistory($'queued request failure callback raised: {v:exception}')
      endtry
    endif
  endfor
enddef

# Default highlight group for a semantic token type; '' means the type is
# not rendered. Lean emits keyword/function/variable/property, and variables
# plus property projections cover most identifiers in a file — coloring them
# buries the informative tokens, so they default to unstyled. Users opt back
# in per type with g:lean_config.semantic_highlighting.links.
def SemanticHighlight(token_type: string): string
  if index(['namespace', 'type', 'class', 'enum', 'interface', 'struct', 'typeParameter'], token_type) >= 0
    return 'Type'
  elseif index(['function', 'method'], token_type) >= 0
    return 'Function'
  elseif token_type ==# 'enumMember'
    return 'Constant'
  elseif token_type ==# 'macro'
    return 'Macro'
  elseif token_type ==# 'keyword'
    return 'Keyword'
  elseif token_type ==# 'modifier'
    return 'StorageClass'
  elseif token_type ==# 'comment'
    return 'Comment'
  elseif index(['string', 'regexp'], token_type) >= 0
    return 'String'
  elseif token_type ==# 'number'
    return 'Number'
  elseif token_type ==# 'operator'
    return 'Operator'
  elseif token_type ==# 'decorator'
    return 'PreProc'
  endif
  return ''
enddef

# The configured link wins over the default mapping; an empty string (or a
# non-string) disables the token type.
def SemanticGroupFor(token_type: string): string
  var links = get(config.Get().semantic_highlighting, 'links', {})
  if type(links) == v:t_dict && has_key(links, token_type)
    var target = links[token_type]
    return type(target) == v:t_string ? target : ''
  endif
  return SemanticHighlight(token_type)
enddef

def SemanticTypeName(token_type: string): string
  return 'LeanSemantic_' .. substitute(token_type, '[^A-Za-z0-9_]', '_', 'g')
enddef

def EnsureSemanticTypes(server: dict<any>)
  var provider = get(server.capabilities, 'semanticTokensProvider', {})
  var legend = type(provider) == v:t_dict ? get(provider, 'legend', {}) : {}
  var token_types = type(legend) == v:t_dict ? get(legend, 'tokenTypes', []) : []
  server.semantic_token_types = type(token_types) == v:t_list
    ? filter(copy(token_types), (_, token_type) => type(token_type) == v:t_string)
    : []
  # Only rendered token types get a group and a text-property type; the
  # rest are skipped entirely when replies are decoded.
  server.semantic_groups = {}
  for token_type in server.semantic_token_types
    var target = SemanticGroupFor(token_type)
    if empty(target)
      continue
    endif
    server.semantic_groups[token_type] = target
    var name = SemanticTypeName(token_type)
    execute $'highlight default link {name} {target}'
    if empty(prop_type_get(name))
      prop_type_add(name, {highlight: name, combine: true})
    endif
  endfor
enddef

def ClearSemanticTokens(server: dict<any>, bufnr: number)
  for token_type in keys(get(server, 'semantic_groups', {}))
    try
      prop_remove({type: SemanticTypeName(token_type), all: true, bufnr: bufnr})
    catch
    endtry
  endfor
enddef

def AddPropertyBatches(bufnr: number, positions_by_type: dict<any>)
  for [type_name, positions] in items(positions_by_type)
    if empty(positions)
      continue
    endif
    try
      prop_add_list({type: type_name, bufnr: bufnr}, positions)
    catch
      # A single stale range must not prevent other valid positions in the
      # same batch from rendering.
      for position in positions
        try
          prop_add(position[0], position[1], {
            type: type_name,
            end_lnum: position[2],
            end_col: position[3],
            bufnr: bufnr,
          })
        catch
        endtry
      endfor
    endtry
  endfor
enddef

def OnSemanticTokens(server: dict<any>, bufnr: number, version: number,
    generation: number, result: any, error: any)
  if !IsCurrentServer(server) || !bufloaded(bufnr)
    return
  endif
  var buffer_key = string(bufnr)
  if get(server.semantic_generations, buffer_key, -1) != generation
    return
  endif
  if has_key(server.semantic_requests, buffer_key)
    remove(server.semantic_requests, buffer_key)
  endif
  if type(error) == v:t_dict
    return
  endif
  if getbufvar(bufnr, 'lean_lsp_version', -1) != version
    return
  endif
  if type(result) != v:t_dict
    ClearSemanticTokens(server, bufnr)
    return
  endif
  var data = get(result, 'data', [])
  if type(data) != v:t_list || len(data) % 5 != 0
    ClearSemanticTokens(server, bufnr)
    return
  endif
  for value in data
    if type(value) != v:t_number || value < 0
      ClearSemanticTokens(server, bufnr)
      return
    endif
  endfor
  ClearSemanticTokens(server, bufnr)
  if empty(data)
    return
  endif
  var line_index = 0
  var utf16_column = 0
  var lines = getbufline(bufnr, 1, '$')
  var positions_by_type: dict<any> = {}
  for index in range(0, len(data) - 5, 5)
    var delta_line = data[index]
    if delta_line > 0
      line_index += delta_line
      utf16_column = data[index + 1]
    else
      utf16_column += data[index + 1]
    endif
    var length = data[index + 2]
    var type_index = data[index + 3]
    if type_index < 0 || type_index >= len(server.semantic_token_types)
      continue
    endif
    var token_type = server.semantic_token_types[type_index]
    if !has_key(get(server, 'semantic_groups', {}), token_type)
      continue
    endif
    if line_index < 0 || line_index >= len(lines)
      continue
    endif
    var text = lines[line_index]
    var start_col = util.ByteColumn(text, utf16_column)
    var end_col = util.ByteColumn(text, utf16_column + length)
    if length == 0
        || utf16idx(text, start_col) != utf16_column
        || utf16idx(text, end_col) != utf16_column + length
      continue
    endif
    var type_name = SemanticTypeName(token_type)
    if !has_key(positions_by_type, type_name)
      positions_by_type[type_name] = []
    endif
    add(positions_by_type[type_name], [
      line_index + 1,
      start_col + 1,
      line_index + 1,
      start_col + 1 + max([1, end_col - start_col]),
    ])
  endfor
  AddPropertyBatches(bufnr, positions_by_type)
enddef

# Trailing debounce: an edit burst issues one full-document token request
# instead of one per flush. The server object is re-resolved at fire time.
const SEMANTIC_DEBOUNCE_MS = 200

def RequestSemanticTokens(server: dict<any>, bufnr: number)
  var key = string(bufnr)
  if has_key(semantic_timers, key)
    timer_stop(semantic_timers[key])
  endif
  semantic_timers[key] = timer_start(SEMANTIC_DEBOUNCE_MS,
    (_) => DebouncedSemanticTokens(bufnr))
enddef

def DebouncedSemanticTokens(bufnr: number)
  var key = string(bufnr)
  if has_key(semantic_timers, key)
    remove(semantic_timers, key)
  endif
  if !has_key(buffer_roots, key)
    return
  endif
  var server = get(servers, buffer_roots[key], {})
  if !empty(server) && get(server, 'initialized', false)
      && IsCurrentServer(server)
    SendSemanticTokensRequest(server, bufnr)
  endif
enddef

def SendSemanticTokensRequest(server: dict<any>, bufnr: number)
  if !config.Get().semantic_highlighting.enable || !bufloaded(bufnr)
    return
  endif
  var provider = get(server.capabilities, 'semanticTokensProvider', v:null)
  if type(provider) != v:t_dict || empty(get(server, 'semantic_groups', {}))
    # No rendered token types means no reason to request tokens at all.
    return
  endif
  var full = get(provider, 'full', false)
  if type(full) != v:t_bool && type(full) != v:t_dict
    return
  elseif type(full) == v:t_bool && !full
    return
  endif
  var key = string(bufnr)
  if has_key(server.semantic_requests, key)
    CancelRequest(server, server.semantic_requests[key])
  endif
  var generation = get(server.semantic_generations, key, 0) + 1
  server.semantic_generations[key] = generation
  var version = getbufvar(bufnr, 'lean_lsp_version', 0)
  var request_id = RequestNow(server, 'textDocument/semanticTokens/full', {
    textDocument: {uri: util.UriFromBuf(bufnr)},
  }, (result, error) => OnSemanticTokens(server, bufnr, version, generation, result, error))
  server.semantic_requests[key] = request_id
enddef

def RefreshSemanticTokens(server: dict<any>)
  for key in keys(server.buffers)
    RequestSemanticTokens(server, str2nr(key))
  endfor
enddef

def IsCoreLeanDirectory(dir: string): bool
  var source_tree = filereadable(dir .. '/Init.lean')
    && filereadable(dir .. '/Lean.lean')
    && isdirectory(dir .. '/kernel')
    && isdirectory(dir .. '/runtime')
  var repository_root = filereadable(dir .. '/LICENSE')
    && isdirectory(dir .. '/LICENSES')
    && isdirectory(dir .. '/src')
  return source_tree || repository_root
enddef

export def ProjectRoot(path: string): string
  var absolute = fnamemodify(path, ':p')
  var normalized = substitute(absolute, '\\', '/', 'g')
  var packages = matchstr(normalized, '^.\{-}\ze/.lake/packages/')
  if !empty(packages)
    return packages
  endif

  var dir = fnamemodify(absolute, ':h')
  var git_marker_enabled = false
  while !empty(dir)
    for marker in config.Get().lsp.root_markers
      if marker ==# '.git'
        git_marker_enabled = true
      elseif filereadable(dir .. '/' .. marker) || isdirectory(dir .. '/' .. marker)
        return dir
      endif
    endfor
    var parent = fnamemodify(dir, ':h')
    if parent ==# dir
      break
    endif
    dir = parent
  endwhile

  # lean.nvim treats both the Lean source tree and an installed toolchain's
  # library as one workspace. Without these boundaries, standalone library
  # files would start a separate server in every subdirectory.
  var stdlib = matchstr(normalized, '^.\{-}\%(\/lean\/library\|\/lib\/lean\)\ze\%(/\|$\)')
  if !empty(stdlib)
    return stdlib
  endif

  dir = fnamemodify(absolute, ':h')
  while !empty(dir)
    if IsCoreLeanDirectory(dir)
      return dir
    endif
    var parent = fnamemodify(dir, ':h')
    if parent ==# dir
      break
    endif
    dir = parent
  endwhile

  if git_marker_enabled
    dir = fnamemodify(absolute, ':h')
    while !empty(dir)
      if isdirectory(dir .. '/.git') || filereadable(dir .. '/.git')
        return dir
      endif
      var parent = fnamemodify(dir, ':h')
      if parent ==# dir
        break
      endif
      dir = parent
    endwhile
  endif
  return fnamemodify(absolute, ':h')
enddef

def ServerCommand(root: string): list<string>
  var configured = config.Get().lsp.command
  if type(configured) == v:t_func
    return call(configured, [root])
  elseif type(configured) == v:t_list && !empty(configured)
    return copy(configured)
  endif
  if filereadable(root .. '/lakefile.lean') || filereadable(root .. '/lakefile.toml')
    return ['lake', 'serve', '--', root]
  endif
  return ['lean', '--server', root]
enddef

def Send(server: dict<any>, message: dict<any>)
  if !has_key(server, 'channel') || ch_status(server.channel) ==# 'closed'
    return
  endif
  var payload = json_encode(message)
  ch_sendraw(server.channel, $"Content-Length: {strlen(payload)}\r\n\r\n{payload}")
enddef

def Respond(server: dict<any>, id: any, result: any, error: any = v:null)
  var response: dict<any> = {jsonrpc: '2.0', id: id}
  if type(error) == v:t_dict
    response.error = error
  else
    response.result = result
  endif
  Send(server, response)
enddef

def NotifyServer(server: dict<any>, method: string, params: any)
  Send(server, {jsonrpc: '2.0', method: method, params: params})
enddef

def CancelRequest(server: dict<any>, id: number)
  if id <= 0
    return
  endif
  var key = string(id)
  if has_key(server.pending, key)
    NotifyServer(server, '$/cancelRequest', {id: id})
    remove(server.pending, key)
    return
  endif
  var queued_index = indexof(server.queue,
    (_, request) => get(request, 'id', -1) == id)
  if queued_index >= 0
    remove(server.queue, queued_index)
  endif
enddef

def SendRequest(server: dict<any>, id: number, method: string, params: any,
    callback: any): number
  if type(callback) == v:t_func
    server.pending[string(id)] = callback
  endif
  Send(server, {jsonrpc: '2.0', id: id, method: method, params: params})
  return id
enddef

def RequestNow(server: dict<any>, method: string, params: any, callback: any): number
  var id = next_request_id
  next_request_id += 1
  return SendRequest(server, id, method, params, callback)
enddef

def InitParams(root: string): dict<any>
  var root_uri = util.UriFromPath(root)
  return {
    processId: getpid(),
    clientInfo: {name: 'lean.vim', version: '0.1.0'},
    locale: 'en',
    rootPath: root,
    rootUri: root_uri,
    workspaceFolders: [{uri: root_uri, name: fnamemodify(root, ':t')}],
    capabilities: {
      workspace: {
        applyEdit: true,
        configuration: true,
        workspaceFolders: true,
        inlayHint: {refreshSupport: true},
        workspaceEdit: {
          documentChanges: true,
          # Every edit is preflighted and unexpected commit failures are
          # rolled back. LSP's `undo` value accurately allows rollback itself
          # to fail, unlike the stronger transactional capability.
          failureHandling: 'undo',
        },
      },
      textDocument: {
        synchronization: {didSave: true, dynamicRegistration: false},
        completion: {
          dynamicRegistration: false,
          contextSupport: true,
          completionItem: {
            snippetSupport: false,
            commitCharactersSupport: false,
            documentationFormat: ['markdown', 'plaintext'],
            deprecatedSupport: true,
            preselectSupport: false,
            insertReplaceSupport: true,
            resolveSupport: {properties: ['documentation', 'detail']},
          },
          completionItemKind: {valueSet: range(1, 25)},
        },
        hover: {contentFormat: ['markdown', 'plaintext']},
        definition: {linkSupport: true},
        declaration: {linkSupport: true},
        codeAction: {
          dynamicRegistration: false,
          codeActionLiteralSupport: {codeActionKind: {valueSet: [
            '', 'quickfix', 'refactor', 'refactor.extract',
            'refactor.inline', 'refactor.rewrite', 'source',
            'source.organizeImports', 'source.fixAll',
          ]}},
          isPreferredSupport: true,
          disabledSupport: true,
          dataSupport: true,
          resolveSupport: {properties: ['edit', 'command']},
        },
        publishDiagnostics: {
          relatedInformation: true,
          versionSupport: true,
          tagSupport: {valueSet: [1, 2]},
        },
        inlayHint: {dynamicRegistration: false},
        semanticTokens: {
          dynamicRegistration: false,
          requests: {range: false, full: true},
          tokenTypes: [
            'namespace', 'type', 'class', 'enum', 'interface', 'struct',
            'typeParameter', 'parameter', 'variable', 'property', 'enumMember',
            'event', 'function', 'method', 'macro', 'keyword', 'modifier',
            'comment', 'string', 'number', 'regexp', 'operator', 'decorator',
          ],
          tokenModifiers: [
            'declaration', 'definition', 'readonly', 'static', 'deprecated',
            'abstract', 'async', 'modification', 'documentation',
            'defaultLibrary',
          ],
          formats: ['relative'],
          overlappingTokenSupport: false,
          multilineTokenSupport: false,
          serverCancelSupport: true,
          augmentsSyntaxTokens: true,
        },
      },
      general: {positionEncodings: ['utf-16']},
      lean: {silentDiagnosticSupport: true, rpcWireFormat: 'v1'},
    },
    initializationOptions: {editDelay: 10, hasWidgets: false},
    trace: 'off',
  }
enddef

def SyncKind(server: dict<any>): number
  var sync = get(server.capabilities, 'textDocumentSync', 0)
  if type(sync) == v:t_number
    return sync
  elseif type(sync) == v:t_dict
    var change = get(sync, 'change', 0)
    return type(change) == v:t_number ? change : 0
  endif
  return 0
enddef

def IncrementalSync(server: dict<any>): bool
  return SyncKind(server) == 2
enddef

def SupportsOpenClose(server: dict<any>): bool
  var sync = get(server.capabilities, 'textDocumentSync', 0)
  if type(sync) == v:t_number
    return sync > 0
  elseif type(sync) == v:t_dict
    var open_close = get(sync, 'openClose', false)
    return type(open_close) == v:t_bool && open_close
  endif
  return false
enddef

def SendDidOpen(server: dict<any>, bufnr: number, dependency_mode: string = 'never')
  if !bufloaded(bufnr) || empty(bufname(bufnr))
    return
  endif
  var key = string(bufnr)
  var version = getbufvar(bufnr, 'lean_lsp_version', 0)
  var text = util.BufText(bufnr)
  setbufvar(bufnr, 'lean_lsp_version', version)
  var uri = util.UriFromBuf(bufnr)
  if SupportsOpenClose(server)
    NotifyServer(server, 'textDocument/didOpen', {
      textDocument: {
        uri: uri,
        languageId: 'lean',
        version: version,
        text: text,
      },
      dependencyBuildMode: dependency_mode,
    })
  endif
  # Track ownership even for a server which opts out of open/close messages;
  # otherwise every WinEnter would repeat setup and semantic-token requests.
  server.opened[key] = uri
  bufnr_by_uri[uri] = bufnr
  server.synced_texts[key] = text
  setbufvar(bufnr, 'lean_lsp_attached', true)
  setbufvar(bufnr, 'lean_lsp_uri', uri)
  RequestSemanticTokens(server, bufnr)
  inlayhints.OnBufferSynced(bufnr)
enddef

def OnInitialized(server: dict<any>, result: any, error: any)
  if !IsCurrentServer(server)
    return
  endif
  if type(error) == v:t_dict
    server.failed = true
    failed_since_ms[server.root] = NowMs()
    FailRequests(server,
      $'Lean language server initialization failed: {get(error, "message", string(error))}')
    util.Notify($'language server initialization failed: {get(error, "message", string(error))}', 'ErrorMsg')
    server.stopping = true
    if has_key(server, 'job') && job_status(server.job) ==# 'run'
      job_stop(server.job)
    endif
    return
  endif
  server.initialized = true
  var capabilities = type(result) == v:t_dict ? get(result, 'capabilities', {}) : {}
  server.capabilities = type(capabilities) == v:t_dict ? capabilities : {}
  var position_encoding = get(server.capabilities, 'positionEncoding', 'utf-16')
  if type(position_encoding) != v:t_string || position_encoding !=# 'utf-16'
    server.initialized = false
    server.failed = true
    failed_since_ms[server.root] = NowMs()
    var message = $'Lean language server selected unsupported position encoding {string(position_encoding)}'
    FailRequests(server, message)
    util.Notify(message, 'ErrorMsg')
    server.stopping = true
    if has_key(server, 'job') && job_status(server.job) ==# 'run'
      job_stop(server.job)
    endif
    return
  endif
  EnsureSemanticTypes(server)
  NotifyServer(server, 'initialized', {})
  for key in keys(server.buffers)
    SendDidOpen(server, str2nr(key))
  endfor
  var queued = server.queue
  server.queue = []
  for request in queued
    SendRequest(server, request.id, request.method, request.params, request.callback)
  endfor
enddef

def OnStderr(server: dict<any>, _channel: channel, message: string)
  if (!IsCurrentServer(server) && !server.stopping) || empty(message)
    return
  endif
  AddHistory(message)
  if config.Get().lsp.stderr && message !~# '^warning: failed to query latest release'
    echomsg $'[lean server] {message}'
  endif
enddef

def OnExit(server: dict<any>, _job: job, status: number)
  var current = IsCurrentServer(server)
  if !current && !server.stopping
    return
  endif
  server.running = false
  server.initialized = false
  if get(server, 'stop_timer', -1) >= 0
    timer_stop(server.stop_timer)
    server.stop_timer = -1
  endif
  if server.stopping
    server.pending = {}
    server.queue = []
    return
  endif
  for key in keys(server.buffers)
    var bufnr = str2nr(key)
    ClearBufferDecorations(server, bufnr, true)
    if bufexists(bufnr)
      setbufvar(bufnr, 'lean_lsp_attached', false)
    endif
  endfor
  if !server.stopping
    failed_since_ms[server.root] = NowMs()
    FailRequests(server, $'Lean language server exited with status {status}')
    util.Notify($'language server exited with status {status}', status == 0 ? 'WarningMsg' : 'ErrorMsg')
    silent doautocmd <nomodeline> User LeanDiagnosticsUpdate
    silent doautocmd <nomodeline> User LeanProgressUpdate
  else
    server.pending = {}
    server.queue = []
  endif
enddef

def EnsureSigns()
  if signs_initialized
    return
  endif
  signs_initialized = true
  highlight default link LeanDiagnosticError DiagnosticError
  highlight default link LeanDiagnosticWarning DiagnosticWarn
  highlight default link LeanDiagnosticInformation DiagnosticInfo
  highlight default link LeanDiagnosticHint DiagnosticHint
  highlight default link LeanGoalUnsolved DiagnosticInfo
  highlight default link LeanGoalAccomplished DiagnosticOk
  highlight default LeanProgress ctermfg=215 guifg=orange
  sign_define('LeanDiagnosticError', {text: 'E', texthl: 'LeanDiagnosticError'})
  sign_define('LeanDiagnosticWarning', {text: 'W', texthl: 'LeanDiagnosticWarning'})
  sign_define('LeanDiagnosticInformation', {text: 'I', texthl: 'LeanDiagnosticInformation'})
  sign_define('LeanDiagnosticHint', {text: 'H', texthl: 'LeanDiagnosticHint'})
  sign_define('LeanGoalUnsolved', {text: 'G', texthl: 'LeanGoalUnsolved'})
  sign_define('LeanGoalAccomplished', {text: '✓', texthl: 'LeanGoalAccomplished'})
  sign_define('LeanProgress', {text: config.Get().progress_bars.character, texthl: 'LeanProgress'})
  for severity in ['Error', 'Warning', 'Information', 'Hint']
    var type_name = 'LeanDiagnosticUnderline' .. severity
    if empty(prop_type_get(type_name))
      prop_type_add(type_name, {highlight: 'LeanDiagnostic' .. severity, combine: true})
    endif
  endfor
enddef

def DiagnosticSeverity(diag: dict<any>): string
  var severity = get(diag, 'severity', 1)
  return type(severity) == v:t_number
    ? get({1: 'Error', 2: 'Warning', 3: 'Information', 4: 'Hint'}, severity, 'Error')
    : 'Error'
enddef

def DiagnosticSeverityNumber(diag: dict<any>): number
  var severity = get(diag, 'severity', 1)
  return type(severity) == v:t_number && severity >= 1 && severity <= 4
    ? severity
    : 1
enddef

def ValidRange(range: any, line_count: number): bool
  if type(range) != v:t_dict
      || type(get(range, 'start', v:null)) != v:t_dict
      || type(get(range, 'end', v:null)) != v:t_dict
    return false
  endif
  var values = [
    get(range.start, 'line', v:null),
    get(range.start, 'character', v:null),
    get(range.end, 'line', v:null),
    get(range.end, 'character', v:null),
  ]
  if indexof(values, (_, value) => type(value) != v:t_number || value < 0) >= 0
    return false
  endif
  return range.start.line < line_count
    && range.end.line >= range.start.line
    && range.end.line <= line_count
    && (range.end.line < line_count || range.end.character == 0)
    && (range.end.line != range.start.line
      || range.end.character >= range.start.character)
enddef

def ClearDiagnosticProperties(bufnr: number)
  for severity in ['Error', 'Warning', 'Information', 'Hint']
    try
      prop_remove({type: 'LeanDiagnosticUnderline' .. severity, all: true, bufnr: bufnr})
    catch
      # A just-unloaded buffer can disappear while a notification is in flight.
    endtry
  endfor
enddef

def ClearUriState(uri: string)
  if empty(uri)
    return
  endif
  if has_key(diagnostics_by_uri, uri)
    remove(diagnostics_by_uri, uri)
  endif
  if has_key(progress_by_uri, uri)
    remove(progress_by_uri, uri)
  endif
enddef

def ClearBufferDecorations(server: dict<any>, bufnr: number, clear_state: bool = false)
  if !bufexists(bufnr)
    return
  endif
  sign_unplace('lean-diagnostics', {buffer: bufnr})
  sign_unplace('lean-progress', {buffer: bufnr})
  ClearDiagnosticProperties(bufnr)
  ClearSemanticTokens(server, bufnr)
  inlayhints.Clear(bufnr)
  if clear_state && !empty(bufname(bufnr))
    ClearUriState(util.UriFromBuf(bufnr))
  endif
enddef

def NotificationIsStale(uri: string, version: any): bool
  if type(version) != v:t_number
    return false
  endif
  var bufnr = BufnrForUri(uri)
  return bufnr >= 0 && bufloaded(bufnr)
    && version < getbufvar(bufnr, 'lean_lsp_version', 0)
enddef

def RenderDiagnostics(uri: string, diagnostics: list<any>)
  EnsureSigns()
  var bufnr = BufnrForUri(uri)
  if bufnr < 0 || !bufloaded(bufnr)
    return
  endif
  sign_unplace('lean-diagnostics', {buffer: bufnr})
  ClearDiagnosticProperties(bufnr)

  var show_signs = config.Get().signs.enable
  var buffer_lines = getbufline(bufnr, 1, '$')
  var line_count = len(buffer_lines)
  var sign_id = 1
  var signs: list<any> = []
  var positions_by_type: dict<any> = {}
  for diagnostic in diagnostics
    if type(diagnostic) != v:t_dict
      continue
    endif
    var tags = get(diagnostic, 'leanTags', [])
    var range = get(diagnostic, 'fullRange', get(diagnostic, 'range', {}))
    if !ValidRange(range, line_count)
      continue
    endif
    if tags ==# [1]
      if show_signs
        add(signs, {
          id: sign_id,
          group: 'lean-diagnostics',
          name: 'LeanGoalUnsolved',
          buffer: bufnr,
          lnum: min([range.end.line, line_count - 1]) + 1,
          priority: 11,
        })
        sign_id += 1
      endif
      continue
    elseif tags ==# [2]
      if show_signs
        add(signs, {
          id: sign_id,
          group: 'lean-diagnostics',
          name: 'LeanGoalAccomplished',
          buffer: bufnr,
          lnum: range.start.line + 1,
          priority: 11,
        })
        sign_id += 1
      endif
      continue
    elseif get(diagnostic, 'isSilent', false)
      continue
    endif

    var severity = DiagnosticSeverity(diagnostic)
    var severity_number = DiagnosticSeverityNumber(diagnostic)
    if show_signs
      add(signs, {
        id: sign_id,
        group: 'lean-diagnostics',
        name: 'LeanDiagnostic' .. severity,
        buffer: bufnr,
        lnum: range.start.line + 1,
        priority: 15 - severity_number,
      })
      sign_id += 1
    endif

    try
      var start_line = range.start.line + 1
      var end_line = min([range.end.line, line_count - 1]) + 1
      var start_text = buffer_lines[start_line - 1]
      var end_text = buffer_lines[end_line - 1]
      var start_col = util.ByteColumn(start_text, range.start.character) + 1
      var end_col = range.end.line >= line_count
        ? strlen(end_text) + 1
        : util.ByteColumn(end_text, range.end.character) + 1
      if end_line == start_line && end_col <= start_col
        end_col = start_col + 1
      endif
      var type_name = 'LeanDiagnosticUnderline' .. severity
      if !has_key(positions_by_type, type_name)
        positions_by_type[type_name] = []
      endif
      add(positions_by_type[type_name], [start_line, start_col, end_line, end_col])
    catch
      # Ignore stale ranges after an edit; the server will republish them.
    endtry
  endfor
  if !empty(signs)
    sign_placelist(signs)
  endif
  AddPropertyBatches(bufnr, positions_by_type)
enddef

# Lean's first progress notification typically covers the whole rest of the
# file; per-line signs over thousands of lines are wasteful. Only the visible
# span (plus margin) is decorated, re-rendered on scroll, with a hard cap.
const PROGRESS_MARGIN_LINES = 20
const MAX_PROGRESS_SIGNS = 1000

def RenderProgress(uri: string, processing: list<any>)
  EnsureSigns()
  var bufnr = BufnrForUri(uri)
  if bufnr < 0 || !bufloaded(bufnr)
    return
  endif
  sign_unplace('lean-progress', {buffer: bufnr})
  if !config.Get().progress_bars.enable
    return
  endif
  var span = util.VisibleLineSpan(bufnr, PROGRESS_MARGIN_LINES)
  if empty(span)
    return
  endif
  var line_count = len(getbufline(bufnr, 1, '$'))
  var sign_id = 1
  var signs: list<any> = []
  for info in processing
    if type(info) != v:t_dict
      continue
    endif
    var range = get(info, 'range', {})
    if !ValidRange(range, line_count)
      continue
    endif
    var first = max([span[0] - 1, max([0, range.start.line])])
    var last = min([span[1] - 1, min([line_count - 1, range.end.line])])
    if last < first
      continue
    endif
    for line_index in range(first, last)
      if len(signs) >= MAX_PROGRESS_SIGNS
        break
      endif
      add(signs, {
        id: sign_id,
        group: 'lean-progress',
        name: 'LeanProgress',
        buffer: bufnr,
        lnum: line_index + 1,
        priority: 5,
      })
      sign_id += 1
    endfor
  endfor
  if !empty(signs)
    sign_placelist(signs)
  endif
enddef

# Re-render cached progress decorations, e.g. after a scroll moved the
# visible span or a hidden buffer became visible again.
export def RefreshProgress(bufnr: number)
  if !bufloaded(bufnr) || empty(bufname(bufnr))
    return
  endif
  var uri = getbufvar(bufnr, 'lean_lsp_uri', '')
  if empty(uri)
    uri = util.UriFromBuf(bufnr)
  endif
  if has_key(progress_by_uri, uri)
    RenderProgress(uri, progress_by_uri[uri])
  endif
enddef

def DebouncedProgressRender(bufnr: number)
  var key = string(bufnr)
  if has_key(progress_timers, key)
    remove(progress_timers, key)
  endif
  RefreshProgress(bufnr)
enddef

def ScheduleProgressRender(bufnr: number)
  var key = string(bufnr)
  if has_key(progress_timers, key)
    timer_stop(progress_timers[key])
  endif
  progress_timers[key] = timer_start(100, (_) => DebouncedProgressRender(bufnr))
enddef

export def OnWinScrolled()
  var scrolled = filter(keys(v:event), (_, key) => key !=# 'all')
  if empty(scrolled)
    # Called outside a WinScrolled autocmd: refresh every attached buffer.
    for key in keys(buffer_roots)
      ScheduleProgressRender(str2nr(key))
    endfor
    return
  endif
  for window_key in scrolled
    var bufnr = winbufnr(str2nr(window_key))
    if bufnr > 0 && getbufvar(bufnr, 'lean_lsp_attached', false)
      ScheduleProgressRender(bufnr)
    endif
  endfor
enddef

def OwnsUri(server: dict<any>, uri: string): bool
  return index(values(get(server, 'opened', {})), uri) >= 0
enddef

def HandleNotification(server: dict<any>, message: dict<any>)
  var method = message.method
  var params = get(message, 'params', {})
  if method ==# 'textDocument/publishDiagnostics'
    if type(params) != v:t_dict || type(get(params, 'uri', v:null)) != v:t_string
      return
    endif
    if !OwnsUri(server, params.uri)
      return
    endif
    var diagnostics = get(params, 'diagnostics', [])
    if type(diagnostics) != v:t_list
      diagnostics = []
    endif
    if NotificationIsStale(params.uri, get(params, 'version', v:null))
      return
    endif
    diagnostics_by_uri[params.uri] = diagnostics
    RenderDiagnostics(params.uri, diagnostics_by_uri[params.uri])
    silent doautocmd <nomodeline> User LeanDiagnosticsUpdate
  elseif method ==# '$/lean/fileProgress'
    if type(params) != v:t_dict
        || type(get(params, 'textDocument', v:null)) != v:t_dict
        || type(get(params.textDocument, 'uri', v:null)) != v:t_string
      return
    endif
    var uri = params.textDocument.uri
    if !OwnsUri(server, uri)
      return
    endif
    if NotificationIsStale(uri, get(params.textDocument, 'version', v:null))
      return
    endif
    var processing = get(params, 'processing', [])
    progress_by_uri[uri] = type(processing) == v:t_list ? processing : []
    RenderProgress(uri, progress_by_uri[uri])
    silent doautocmd <nomodeline> User LeanProgressUpdate
  elseif method ==# 'window/showMessage'
    if type(params) == v:t_dict && type(get(params, 'message', v:null)) == v:t_string
      util.Notify(params.message,
        get(params, 'type', 3) == 1 ? 'ErrorMsg' : 'WarningMsg')
    endif
  elseif method ==# 'window/logMessage'
    if type(params) == v:t_dict && type(get(params, 'message', v:null)) == v:t_string
      AddHistory(params.message)
    endif
  endif
enddef

export def ApplyWorkspaceEdit(edit: any): bool
  if type(edit) != v:t_dict
    return false
  endif
  var operations: list<any> = []
  if has_key(edit, 'documentChanges')
    if type(edit.documentChanges) != v:t_list
      return false
    endif
    for change in edit.documentChanges
      # Resource operations are deliberately unsupported. Reject them before
      # applying any preceding text-document edits.
      if type(change) != v:t_dict || !has_key(change, 'edits')
          || type(change.edits) != v:t_list
          || type(get(change, 'textDocument', v:null)) != v:t_dict
          || type(get(change.textDocument, 'uri', v:null)) != v:t_string
        return false
      endif
      var version = get(change.textDocument, 'version', v:null)
      if type(version) != v:t_number && type(version) != v:t_none
        return false
      endif
      add(operations, {
        uri: change.textDocument.uri,
        version: version,
        edits: change.edits,
      })
    endfor
  else
    var changes = get(edit, 'changes', {})
    if type(changes) != v:t_dict
      return false
    endif
    for [uri, edits] in items(changes)
      if type(edits) != v:t_list
        return false
      endif
      add(operations, {uri: uri, version: v:null, edits: edits})
    endfor
  endif

  var prepared_edits: list<any> = []
  var seen_uris: dict<bool> = {}
  for operation in operations
    if empty(operation.uri) || has_key(seen_uris, operation.uri)
      return false
    endif
    seen_uris[operation.uri] = true
    if type(operation.version) == v:t_number
      var target_bufnr = bufnr(util.PathFromUri(operation.uri))
      if target_bufnr < 0 || !bufloaded(target_bufnr)
          || getbufvar(target_bufnr, 'lean_lsp_version', -1) != operation.version
        return false
      endif
    endif
    var prepared = util.PrepareTextEdits(operation.uri, operation.edits)
    if !get(prepared, 'ok', false)
      return false
    endif
    add(prepared_edits, prepared)
  endfor

  # Nothing asynchronous can interleave with the commit below, but validate
  # every target once more before changing the first buffer. This prevents a
  # listener or prior preparation side effect from producing a partial edit.
  for prepared in prepared_edits
    if get(prepared, 'changed', false)
        && (!bufloaded(get(prepared, 'bufnr', -1))
          || !getbufvar(prepared.bufnr, '&modifiable')
          || util.BufText(prepared.bufnr) !=# prepared.original)
      return false
    endif
  endfor

  var applied_edits: list<any> = []
  for prepared in prepared_edits
    if get(prepared, 'changed', false)
      add(applied_edits, prepared)
    endif
    if !util.ApplyPreparedTextEdits(prepared)
      for applied in reverse(copy(applied_edits))
        util.RestorePreparedTextEdits(applied)
      endfor
      return false
    endif
  endfor
  # TextChanged may not run until control returns to Vim. Synchronize edits
  # before a following code-action command can observe stale server state.
  for prepared in applied_edits
    FlushChange(prepared.bufnr)
  endfor
  return true
enddef

def InvalidParams(server: dict<any>, message: dict<any>, detail: string)
  Respond(server, message.id, v:null, {code: -32602, message: detail})
enddef

def HandleShowMessageRequest(server: dict<any>, message: dict<any>, params: any)
  if type(params) != v:t_dict || type(get(params, 'message', v:null)) != v:t_string
    InvalidParams(server, message, 'window/showMessageRequest requires a string message')
    return
  endif
  var actions = get(params, 'actions', [])
  if type(actions) != v:t_list
    InvalidParams(server, message, 'window/showMessageRequest actions must be an array')
    return
  endif
  if empty(actions)
    util.Notify(params.message)
    Respond(server, message.id, v:null)
    return
  endif
  var choices = [params.message]
  for action in actions
    if type(action) != v:t_dict || type(get(action, 'title', v:null)) != v:t_string
      InvalidParams(server, message, 'window/showMessageRequest actions require string titles')
      return
    endif
    add(choices, $'{len(choices)}. {action.title}')
  endfor
  var selection = inputlist(choices)
  Respond(server, message.id,
    selection > 0 && selection <= len(actions) ? actions[selection - 1] : v:null)
enddef

def HandleServerRequest(root: string, server: dict<any>, message: dict<any>)
  var method = message.method
  var params = get(message, 'params', {})
  if method ==# 'workspace/configuration'
    if type(params) != v:t_dict || type(get(params, 'items', v:null)) != v:t_list
      InvalidParams(server, message, 'workspace/configuration requires an items array')
      return
    endif
    var result: list<any> = []
    for _ in params.items
      add(result, v:null)
    endfor
    Respond(server, message.id, result)
  elseif method ==# 'workspace/workspaceFolders'
    Respond(server, message.id, [{uri: util.UriFromPath(root), name: fnamemodify(root, ':t')}])
  elseif method ==# 'workspace/applyEdit'
    if type(params) != v:t_dict || type(get(params, 'edit', v:null)) != v:t_dict
      InvalidParams(server, message, 'workspace/applyEdit requires an edit object')
      return
    endif
    Respond(server, message.id, {applied: ApplyWorkspaceEdit(params.edit)})
  elseif method ==# 'workspace/semanticTokens/refresh'
    Respond(server, message.id, v:null)
    RefreshSemanticTokens(server)
  elseif method ==# 'workspace/inlayHint/refresh'
    Respond(server, message.id, v:null)
    for buffer_key in keys(server.buffers)
      inlayhints.OnBufferSynced(str2nr(buffer_key))
    endfor
  elseif method ==# 'window/showMessageRequest'
    HandleShowMessageRequest(server, message, params)
  else
    Respond(server, message.id, v:null, {code: -32601, message: $'unsupported client request: {method}'})
  endif
enddef

def Dispatch(server: dict<any>, message: any)
  if type(message) != v:t_dict
    return
  endif
  var root = server.root
  if server.stopping && has_key(message, 'method')
    if has_key(message, 'id')
      Respond(server, message.id, v:null, {code: -32800, message: 'Lean client is shutting down'})
    endif
    return
  endif
  if has_key(message, 'method') && has_key(message, 'id')
    HandleServerRequest(root, server, message)
  elseif has_key(message, 'method')
    HandleNotification(server, message)
  elseif has_key(message, 'id')
    var key = string(message.id)
    if has_key(server.pending, key)
      var callback = remove(server.pending, key)
      call(callback, [get(message, 'result', v:null), get(message, 'error', v:null)])
    endif
  endif
enddef

def OnStdout(server: dict<any>, _channel: channel, chunk: string)
  if !IsCurrentServer(server) && !server.stopping
    return
  endif
  var root = server.root
  server.recv ..= chunk
  while true
    # body_length caches the parsed header between chunks so a body arriving
    # in many pieces is not re-scanned for its header every time.
    if server.body_length < 0
      var header_end = stridx(server.recv, "\r\n\r\n")
      if header_end < 0
        return
      endif
      var header = strpart(server.recv, 0, header_end)
      var length_text = matchstr(header, '\cContent-Length:\s*\zs\d\+')
      server.recv = strpart(server.recv, header_end + 4)
      if empty(length_text)
        continue
      endif
      server.body_length = str2nr(length_text)
    endif
    if strlen(server.recv) < server.body_length
      return
    endif
    var body = strpart(server.recv, 0, server.body_length)
    server.recv = strpart(server.recv, server.body_length)
    server.body_length = -1
    var decoded: any = v:null
    try
      decoded = json_decode(body)
    catch
      util.Notify($'invalid JSON-RPC message: {v:exception}', 'ErrorMsg')
      continue
    endtry
    try
      Dispatch(server, decoded)
    catch
      util.Notify($'failed to handle JSON-RPC message: {v:exception}', 'ErrorMsg')
    endtry
  endwhile
enddef

def StartServer(root: string): dict<any>
  var server: dict<any> = {
    root: root,
    command: [],
    pending: {},
    queue: [],
    recv: '',
    body_length: -1,
    buffers: {},
    opened: {},
    synced_texts: {},
    semantic_requests: {},
    semantic_generations: {},
    semantic_groups: {},
    capabilities: {},
    initialized: false,
    failed: false,
    running: true,
    stopping: false,
    stop_timer: -1,
  }
  servers[root] = server
  try
    var command = ServerCommand(root)
    if empty(command)
      throw 'language-server command is empty'
    endif
    server.command = command
    server.job = job_start(command, {
      cwd: root,
      in_io: 'pipe',
      out_io: 'pipe',
      err_io: 'pipe',
      in_mode: 'raw',
      out_mode: 'raw',
      err_mode: 'nl',
      out_cb: (channel, message) => OnStdout(server, channel, message),
      err_cb: (channel, message) => OnStderr(server, channel, message),
      exit_cb: (job_object, status) => OnExit(server, job_object, status),
    })
    server.channel = job_getchannel(server.job)
    if job_status(server.job) ==# 'fail'
      throw $'unable to start {join(command, " ")}'
    endif
    RequestNow(server, 'initialize', InitParams(root),
      (result, error) => OnInitialized(server, result, error))
  catch
    server.failed = true
    server.running = false
    failed_since_ms[root] = NowMs()
    if has_key(server, 'job') && job_status(server.job) ==# 'run'
      job_stop(server.job)
    endif
    util.Notify($'cannot start Lean language server: {v:exception}'
      .. '; not retrying automatically, use :LeanRestartServer', 'ErrorMsg')
  endtry
  return server
enddef

def EnsureServer(root: string): dict<any>
  if has_key(servers, root) && servers[root].running
    return servers[root]
  endif
  if has_key(servers, root)
      && NowMs() - get(failed_since_ms, root, -RESTART_BACKOFF_MS) < RESTART_BACKOFF_MS
    return servers[root]
  endif
  return StartServer(root)
enddef

export def Attach(bufnr: number): bool
  if !config.Get().lsp.enable || empty(bufname(bufnr))
      || getbufvar(bufnr, '&filetype') !=# 'lean'
    return false
  endif
  var key = string(bufnr)
  var uri = util.UriFromBuf(bufnr)
  if has_key(buffer_roots, key)
      && getbufvar(bufnr, 'lean_lsp_uri', '') ==# uri
    var existing_root = buffer_roots[key]
    var existing_server = EnsureServer(existing_root)
    existing_server.buffers[key] = true
    if existing_server.initialized && !has_key(existing_server.opened, key)
      SendDidOpen(existing_server, bufnr)
    endif
    return !existing_server.failed
  endif

  var previous_uri = getbufvar(bufnr, 'lean_lsp_uri', '')
  if has_key(buffer_roots, key)
    Detach(bufnr)
  endif
  if !empty(previous_uri) && previous_uri !=# uri
    setbufvar(bufnr, 'lean_lsp_version', 0)
  endif
  var root = ProjectRoot(bufname(bufnr))
  buffer_roots[key] = root
  setbufvar(bufnr, 'lean_lsp_root', root)
  setbufvar(bufnr, 'lean_lsp_uri', uri)
  var server = EnsureServer(root)
  server.buffers[key] = true
  if server.initialized && !has_key(server.opened, key)
    SendDidOpen(server, bufnr)
  endif
  return !server.failed
enddef

export def Detach(bufnr: number)
  var key = string(bufnr)
  if has_key(change_timers, key)
    timer_stop(remove(change_timers, key))
  endif
  if has_key(progress_timers, key)
    timer_stop(remove(progress_timers, key))
  endif
  if has_key(semantic_timers, key)
    timer_stop(remove(semantic_timers, key))
  endif
  if has_key(last_change_flush_ms, key)
    remove(last_change_flush_ms, key)
  endif
  if !has_key(buffer_roots, key)
    if bufexists(bufnr)
      ClearBufferDecorations({}, bufnr, true)
      setbufvar(bufnr, 'lean_lsp_attached', false)
      setbufvar(bufnr, 'lean_lsp_uri', '')
    endif
    return
  endif
  var root = remove(buffer_roots, key)
  if !has_key(servers, root)
    if bufexists(bufnr)
      ClearBufferDecorations({}, bufnr, true)
      setbufvar(bufnr, 'lean_lsp_attached', false)
      setbufvar(bufnr, 'lean_lsp_uri', '')
    endif
    return
  endif
  var server = servers[root]
  var uri = get(server.opened, key, getbufvar(bufnr, 'lean_lsp_uri', ''))
  if has_key(server.opened, key)
    if server.initialized && SupportsOpenClose(server)
      NotifyServer(server, 'textDocument/didClose', {textDocument: {uri: uri}})
    endif
    remove(server.opened, key)
  endif
  if has_key(server.synced_texts, key)
    remove(server.synced_texts, key)
  endif
  if has_key(server.semantic_requests, key)
    CancelRequest(server, server.semantic_requests[key])
    remove(server.semantic_requests, key)
  endif
  if has_key(server.semantic_generations, key)
    remove(server.semantic_generations, key)
  endif
  if has_key(server.buffers, key)
    remove(server.buffers, key)
  endif
  ClearBufferDecorations(server, bufnr, true)
  ClearUriState(uri)
  ForgetUri(uri, bufnr)
  setbufvar(bufnr, 'lean_lsp_attached', false)
  setbufvar(bufnr, 'lean_lsp_uri', '')
enddef

def FlushChange(bufnr: number)
  var key = string(bufnr)
  if has_key(change_timers, key)
    timer_stop(remove(change_timers, key))
  endif
  if !has_key(buffer_roots, key) || !bufloaded(bufnr)
    return
  endif
  var root = buffer_roots[key]
  if !has_key(servers, root) || !servers[root].initialized
    return
  endif
  var server = servers[root]
  var current_text = util.BufText(bufnr)
  var previous_text = get(server.synced_texts, key, v:null)
  if type(previous_text) == v:t_string && previous_text ==# current_text
    return
  endif
  if SyncKind(server) == 0
    server.synced_texts[key] = current_text
    return
  endif
  var version = getbufvar(bufnr, 'lean_lsp_version', 0) + 1
  setbufvar(bufnr, 'lean_lsp_version', version)
  var content_changes = type(previous_text) == v:t_string && IncrementalSync(server)
    ? [util.IncrementalChange(previous_text, current_text)]
    : [{text: current_text}]
  NotifyServer(server, 'textDocument/didChange', {
    textDocument: {uri: util.UriFromBuf(bufnr), version: version},
    contentChanges: content_changes,
  })
  server.synced_texts[key] = current_text
  last_change_flush_ms[key] = NowMs()
  RequestSemanticTokens(server, bufnr)
  inlayhints.OnBufferSynced(bufnr)
enddef

export def DidChange(bufnr: number)
  var key = string(bufnr)
  if !has_key(buffer_roots, key)
    return
  endif
  var delay = max([0, config.Get().lsp.change_delay])
  if !has_key(change_timers, key)
      && NowMs() - get(last_change_flush_ms, key, -1.0) >= delay
    FlushChange(bufnr)
    return
  endif
  if has_key(change_timers, key)
    timer_stop(change_timers[key])
  endif
  change_timers[key] = timer_start(delay,
    (_) => FlushChange(bufnr))
enddef

export def DidSave(bufnr: number)
  var key = string(bufnr)
  if !has_key(buffer_roots, key)
    return
  endif
  FlushChange(bufnr)
  var root = buffer_roots[key]
  if !has_key(servers, root)
    return
  endif
  var server = servers[root]
  if !server.running || !server.initialized || !has_key(server.opened, key)
    return
  endif
  var sync = get(server.capabilities, 'textDocumentSync', {})
  if type(sync) != v:t_dict
    return
  endif
  var save = get(sync, 'save', false)
  if !(type(save) == v:t_bool && save) && type(save) != v:t_dict
    return
  endif
  var params: dict<any> = {textDocument: {uri: util.UriFromBuf(bufnr)}}
  if type(save) == v:t_dict
    var include_text = get(save, 'includeText', false)
    if type(include_text) == v:t_bool && include_text
      params.text = util.BufText(bufnr)
    endif
  endif
  NotifyServer(server, 'textDocument/didSave', params)
enddef

export def Request(bufnr: number, method: string, params: any, callback: any): number
  var key = string(bufnr)
  if !has_key(buffer_roots, key) && !Attach(bufnr)
    if type(callback) == v:t_func
      call(callback, [v:null, {code: -32000, message: 'Lean language server is unavailable'}])
    endif
    return -1
  endif
  var root = buffer_roots[key]
  if !has_key(servers, root)
    if type(callback) == v:t_func
      call(callback, [v:null, {code: -32000, message: 'Lean language server is unavailable'}])
    endif
    return -1
  endif
  var server = servers[root]
  if server.failed
    if type(callback) == v:t_func
      call(callback, [v:null, {code: -32000, message: 'Lean language server failed to start'}])
    endif
    return -1
  endif
  if !server.running
    if type(callback) == v:t_func
      call(callback, [v:null, {
        code: -32097,
        message: 'Lean language server has exited; run :LeanRestartServer',
      }])
    endif
    return -1
  endif
  if !server.initialized
    var id = next_request_id
    next_request_id += 1
    add(server.queue, {id: id, method: method, params: params, callback: callback})
    return id
  endif
  return RequestNow(server, method, params, callback)
enddef

export def Cancel(bufnr: number, request_id: number)
  if request_id <= 0
    return
  endif
  var key = string(bufnr)
  if !has_key(buffer_roots, key) || !has_key(servers, buffer_roots[key])
    return
  endif
  CancelRequest(servers[buffer_roots[key]], request_id)
enddef

export def Notify(bufnr: number, method: string, params: any)
  var key = string(bufnr)
  if has_key(buffer_roots, key) && has_key(servers, buffer_roots[key])
    var server = servers[buffer_roots[key]]
    if server.running
      NotifyServer(server, method, params)
    endif
  endif
enddef

export def RestartFile(bufnr: number)
  var key = string(bufnr)
  if !has_key(buffer_roots, key) && !Attach(bufnr)
    return
  endif
  var server = servers[buffer_roots[key]]
  if !server.running || !server.initialized
    util.Notify('Lean language server is not ready; use :LeanRestartServer', 'WarningMsg')
    return
  endif
  if !SupportsOpenClose(server) || !has_key(server.opened, key)
    util.Notify('Lean language server does not support restarting open documents', 'WarningMsg')
    return
  endif
  NotifyServer(server, 'textDocument/didClose', {
    textDocument: {uri: server.opened[key]},
  })
  remove(server.opened, key)
  SendDidOpen(server, bufnr, 'once')
enddef

def ForceStop(server: dict<any>)
  server.stop_timer = -1
  if has_key(server, 'job') && job_status(server.job) ==# 'run'
    job_stop(server.job)
  endif
enddef

def FinishStop(server: dict<any>, _result: any, _error: any)
  if !server.stopping || !server.running
    return
  endif
  if get(server, 'stop_timer', -1) >= 0
    timer_stop(server.stop_timer)
  endif
  NotifyServer(server, 'exit', v:null)
  # A conforming server exits after the notification. Keep a short fallback
  # for broken servers so restart and Vim exit cannot leak the process.
  server.stop_timer = timer_start(250, (_) => ForceStop(server))
enddef

def StopServer(root: string)
  if has_key(failed_since_ms, root)
    remove(failed_since_ms, root)
  endif
  if !has_key(servers, root)
    return
  endif
  var server = servers[root]
  server.stopping = true
  for key in keys(server.buffers)
    var bufnr = str2nr(key)
    ClearBufferDecorations(server, bufnr, true)
    if bufexists(bufnr)
      setbufvar(bufnr, 'lean_lsp_attached', false)
      setbufvar(bufnr, 'lean_lsp_uri', '')
    endif
  endfor
  server.pending = {}
  server.queue = []
  remove(servers, root)
  if server.initialized && has_key(server, 'channel')
      && ch_status(server.channel) !=# 'closed'
    RequestNow(server, 'shutdown', v:null,
      (result, error) => FinishStop(server, result, error))
    server.stop_timer = timer_start(1000, (_) => ForceStop(server))
  else
    ForceStop(server)
  endif
enddef

export def RestartServer(bufnr: number)
  var key = string(bufnr)
  if !has_key(buffer_roots, key)
    # A manual restart always retries, even inside the failure backoff.
    failed_since_ms = {}
    Attach(bufnr)
    return
  endif
  var root = buffer_roots[key]
  var buffers = keys(filter(copy(buffer_roots), (_, candidate_root) => candidate_root ==# root))
  StopServer(root)
  for buffer_key in buffers
    remove(buffer_roots, buffer_key)
    Attach(str2nr(buffer_key))
  endfor
enddef

export def StopAll()
  failed_since_ms = {}
  for root in copy(keys(servers))
    StopServer(root)
  endfor
  for timer in values(change_timers)
    timer_stop(timer)
  endfor
  change_timers = {}
  for timer in values(progress_timers)
    timer_stop(timer)
  endfor
  progress_timers = {}
  for timer in values(semantic_timers)
    timer_stop(timer)
  endfor
  semantic_timers = {}
  last_change_flush_ms = {}
  for key in keys(buffer_roots)
    var bufnr = str2nr(key)
    if bufexists(bufnr)
      setbufvar(bufnr, 'lean_lsp_attached', false)
    endif
  endfor
  buffer_roots = {}
enddef

export def Capabilities(bufnr: number): dict<any>
  var key = string(bufnr)
  if !has_key(buffer_roots, key)
    return {}
  endif
  var server = get(servers, buffer_roots[key], {})
  var capabilities = get(server, 'capabilities', {})
  return type(capabilities) == v:t_dict ? capabilities : {}
enddef

# Push any pending buffer text to the server immediately. Features that query
# at the cursor (completion) must not race the change debounce.
export def Flush(bufnr: number)
  FlushChange(bufnr)
enddef

export def Diagnostics(uri: string): list<any>
  return get(diagnostics_by_uri, uri, [])
enddef

export def DiagnosticsAt(bufnr: number, line_index: number): list<any>
  var result: list<any> = []
  var line_count = len(getbufline(bufnr, 1, '$'))
  for diagnostic in Diagnostics(util.UriFromBuf(bufnr))
    if type(diagnostic) != v:t_dict || get(diagnostic, 'isSilent', false)
      continue
    endif
    var range = get(diagnostic, 'fullRange', get(diagnostic, 'range', {}))
    if ValidRange(range, line_count)
        && line_index >= range.start.line && line_index <= range.end.line
      add(result, diagnostic)
    endif
  endfor
  return result
enddef

export def ProgressAt(bufnr: number, line_index: number): bool
  var line_count = len(getbufline(bufnr, 1, '$'))
  for info in get(progress_by_uri, util.UriFromBuf(bufnr), [])
    if type(info) != v:t_dict
      continue
    endif
    var range = get(info, 'range', {})
    if ValidRange(range, line_count)
        && line_index >= range.start.line && line_index <= range.end.line
      return true
    endif
  endfor
  return false
enddef

# Statusline helpers: how much of the buffer is still elaborating, and the
# non-silent diagnostic counts.
export def ProgressSummary(bufnr: number): dict<any>
  var line_count = max([1, len(getbufline(bufnr, 1, '$'))])
  var covered = 0
  for info in get(progress_by_uri, util.UriFromBuf(bufnr), [])
    if type(info) != v:t_dict
      continue
    endif
    var range = get(info, 'range', {})
    if !ValidRange(range, line_count)
      continue
    endif
    var first = max([0, range.start.line])
    var last = min([line_count - 1, range.end.line])
    if last >= first
      covered += last - first + 1
    endif
  endfor
  return {
    processing: covered > 0,
    percent: min([100, covered * 100 / line_count]),
  }
enddef

export def DiagnosticCounts(bufnr: number): dict<number>
  var counts = {error: 0, warning: 0}
  for diagnostic in Diagnostics(util.UriFromBuf(bufnr))
    if type(diagnostic) != v:t_dict
        || get(diagnostic, 'isSilent', false)
        || !empty(get(diagnostic, 'leanTags', []))
      continue
    endif
    var severity = get(diagnostic, 'severity', 1)
    if severity == 1
      counts.error += 1
    elseif severity == 2
      counts.warning += 1
    endif
  endfor
  return counts
enddef

export def Stderr(): list<string>
  return copy(stderr_history)
enddef

export def Status(bufnr: number): dict<any>
  var key = string(bufnr)
  if !has_key(buffer_roots, key)
    return {attached: false}
  endif
  var root = buffer_roots[key]
  var server = get(servers, root, {})
  return {
    attached: true,
    root: root,
    initialized: get(server, 'initialized', false),
    running: get(server, 'running', false),
    command: get(server, 'command', []),
  }
enddef

defcompile
