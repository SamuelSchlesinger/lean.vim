vim9script

import autoload 'lean/config.vim' as config
import autoload 'lean/decorations.vim' as decorations
import autoload 'lean/documents.vim' as documents
import autoload 'lean/workspace.vim' as workspace
import autoload 'lean/util.vim' as util

# A deliberately small LSP 3.17 client for Lean.  Vim has jobs, channels,
# popups, signs, and text properties, but (unlike Neovim) no built-in LSP
# client.  Keeping this transport Lean-specific makes its behavior auditable.

var document_handlers: dict<any> = {}

export def SetDocumentHandlers(handlers: dict<any>)
  document_handlers = handlers
enddef

def DocumentEvent(event: string, bufnr: number)
  var Handler = get(document_handlers, event, v:null)
  if type(Handler) == v:t_func
    Handler(bufnr)
  endif
enddef

def SyncedText(bufnr: number): any
  var key = string(bufnr)
  var server = get(servers, get(buffer_roots, key, ''), {})
  return get(get(server, 'synced_texts', {}), key, v:null)
enddef

export def ApplyWorkspaceEdit(edit: any): bool
  return workspace.Apply(edit, SyncedText, FlushChange)
enddef

export def RefreshProgress(bufnr: number)
  decorations.RefreshProgress(bufnr)
enddef

export def OnWinScrolled()
  decorations.OnWinScrolled()
enddef

export def Diagnostics(uri: string): list<any>
  return decorations.Diagnostics(uri)
enddef

export def DiagnosticsAt(bufnr: number, line_index: number): list<any>
  return decorations.DiagnosticsAt(bufnr, line_index)
enddef

export def ProgressAt(bufnr: number, line_index: number): bool
  return decorations.ProgressAt(bufnr, line_index)
enddef

export def ProgressSummary(bufnr: number): dict<any>
  return decorations.ProgressSummary(bufnr)
enddef

export def DiagnosticCounts(bufnr: number): dict<number>
  return decorations.DiagnosticCounts(bufnr)
enddef

var servers: dict<any> = {}
var buffer_roots: dict<string> = {}
var change_timers: dict<any> = {}
var last_change_flush_ms: dict<float> = {}
var stale_import_refreshed: dict<bool> = {}
var bufnr_by_uri: dict<number> = {}
var failed_since_ms: dict<float> = {}
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
  server.request_buffers = {}
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
  if has_key(server.request_buffers, key)
    remove(server.request_buffers, key)
  endif
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
  documents.Attach(bufnr, uri, server)
  server.opened[key] = uri
  bufnr_by_uri[uri] = bufnr
  server.synced_texts[key] = text
  setbufvar(bufnr, 'lean_lsp_attached', true)
  setbufvar(bufnr, 'lean_lsp_uri', uri)
  DocumentEvent('synced', bufnr)
enddef

def OnInitialized(server: dict<any>, result: any, error: any)
  if !IsCurrentServer(server) || !server.running
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

def ClearUriState(uri: string)
  if empty(uri)
    return
  endif
  decorations.Forget(uri)
  if has_key(stale_import_refreshed, uri)
    remove(stale_import_refreshed, uri)
  endif
enddef

def ClearBufferDecorations(server: dict<any>, bufnr: number, clear_state: bool = false)
  documents.Detach(bufnr)
  if !bufexists(bufnr)
    return
  endif
  decorations.Clear(bufnr)
  DocumentEvent('cleared', bufnr)
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

def OwnsUri(server: dict<any>, uri: string): bool
  return index(values(get(server, 'opened', {})), uri) >= 0
enddef

# A stale-imports diagnostic means imports were rebuilt (or will be by lake
# on reopen); restarting the file is exactly the remedy the message asks the
# user for.  One automatic restart per buffer lifetime, aimed at the
# freshly-opened-project case: re-arming when the message clears would turn
# every save of an imported module into a rebuild-and-re-elaborate storm
# across the buffers that import it.  The flag resets when the buffer is
# closed (ClearUriState); afterwards the diagnostic stays visible and
# :LeanRestartFile remains the manual remedy.
def MaybeRefreshStaleImports(uri: string, diagnostics: list<any>)
  var stale = false
  for diagnostic in diagnostics
    if type(diagnostic) == v:t_dict
        && type(get(diagnostic, 'message', v:null)) == v:t_string
        && diagnostic.message =~? '^imports are out of date'
      stale = true
      break
    endif
  endfor
  if !stale
    return
  endif
  if !config.Get().lsp.refresh_stale_imports
      || has_key(stale_import_refreshed, uri)
    return
  endif
  stale_import_refreshed[uri] = true
  var bufnr = BufnrForUri(uri)
  if bufnr < 0 || !bufloaded(bufnr)
    return
  endif
  AddHistory($'imports out of date for {uri}; restarting the file')
  timer_start(0, (_) => RestartFile(bufnr))
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
    decorations.RenderDiagnostics(params.uri, diagnostics)
    MaybeRefreshStaleImports(params.uri, diagnostics)
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
    decorations.RenderProgress(uri, type(processing) == v:t_list ? processing : [])
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
    for buffer_key in keys(server.buffers)
      DocumentEvent('semantic', str2nr(buffer_key))
    endfor
  elseif method ==# 'workspace/inlayHint/refresh'
    Respond(server, message.id, v:null)
    for buffer_key in keys(server.buffers)
      DocumentEvent('inlay', str2nr(buffer_key))
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
    if has_key(server.request_buffers, key)
      remove(server.request_buffers, key)
    endif
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
    request_buffers: {},
    queue: [],
    recv: '',
    body_length: -1,
    buffers: {},
    opened: {},
    synced_texts: {},
    capabilities: {},
    initialized: false,
    failed: false,
    running: true,
    stopping: false,
    stop_timer: -1,
  }
  # Automatic recovery must restore all attached documents in this project,
  # including hidden buffers that may never emit another WinEnter.
  for [key, buffer_root] in items(buffer_roots)
    if buffer_root ==# root && bufloaded(str2nr(key))
        && getbufvar(str2nr(key), '&filetype') ==# 'lean'
      server.buffers[key] = true
      documents.Attach(str2nr(key), util.UriFromBuf(str2nr(key)), server)
    endif
  endfor
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
  if !config.Get().lsp.enable || !bufloaded(bufnr) || empty(bufname(bufnr))
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
    documents.Attach(bufnr, uri, existing_server)
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
  documents.Attach(bufnr, uri, server)
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
  for [request_key, owner] in items(copy(server.request_buffers))
    if owner == bufnr
      CancelRequest(server, str2nr(request_key))
    endif
  endfor
  if has_key(server.opened, key)
    if server.initialized && SupportsOpenClose(server)
      NotifyServer(server, 'textDocument/didClose', {textDocument: {uri: uri}})
    endif
    remove(server.opened, key)
  endif
  if has_key(server.synced_texts, key)
    remove(server.synced_texts, key)
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
  DocumentEvent('synced', bufnr)
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

def OnEditResponse(snapshots: list<dict<any>>, callback: any, result: any, error: any)
  if type(error) != v:t_dict && !documents.ProjectIsCurrent(snapshots)
    call(callback, [v:null, {code: -32801,
      message: 'a project buffer changed while the edit was pending; request it again'}])
    return
  endif
  call(callback, [result, error])
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
  var edit_request = index(['textDocument/rename', 'textDocument/codeAction',
    'codeAction/resolve'], method) >= 0
  var Reply = callback
  if edit_request && type(callback) == v:t_func
    var snapshots = documents.CaptureProject(server)
    Reply = (result, error) => OnEditResponse(snapshots, callback, result, error)
  endif
  if !server.initialized
    var id = next_request_id
    next_request_id += 1
    add(server.queue, {id: id, method: method, params: params, callback: Reply})
    server.request_buffers[string(id)] = bufnr
    return id
  endif
  if edit_request || method =~# '^workspace/'
    for buffer_key in keys(server.buffers)
      FlushChange(str2nr(buffer_key))
    endfor
  else
    FlushChange(bufnr)
  endif
  var id = RequestNow(server, method, params, Reply)
  server.request_buffers[string(id)] = bufnr
  return id
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
  documents.Detach(bufnr)
  DocumentEvent('cleared', bufnr)
  documents.Attach(bufnr, util.UriFromBuf(bufnr), server)
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
  decorations.Stop()
  failed_since_ms = {}
  for root in copy(keys(servers))
    StopServer(root)
  endfor
  for timer in values(change_timers)
    timer_stop(timer)
  endfor
  change_timers = {}
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
