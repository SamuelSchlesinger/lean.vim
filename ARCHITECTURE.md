# Architecture

The public commands, configuration, and `lean#` entry points are kept stable.
The implementation has three responsibilities: maintain the server's document
state, coordinate feature requests, and render editor UI. `make lint` checks
that the module import graph has no cycles and that the lower layers do not
import their consumers.

## Ownership

| Module | Owns | Receives from its caller |
| --- | --- | --- |
| `lsp.vim` | Processes, framing, RPC IDs, pending/queued calls, project membership, synchronized text and versions | Feature callbacks for document synchronization and cleanup |
| `documents.vim` | One identity per attached buffer lifetime | Registration from the LSP client |
| `requests.vim` | Replaceable request scopes, their RPC IDs and timers, freshness checks | A feature-owned scope, buffer, and optional window/cursor constraints |
| `workspace.vim` | Workspace-edit preflight, application, and rollback attempts | Callbacks to read synchronized text and flush successful changes |
| `decorations.vim` | Cached diagnostics/progress, signs, underlines, scroll rendering | Notifications already checked for ownership and version by the LSP client |
| `semantic.vim` / `inlayhints.vim` | Feature-specific requests, decoding, and properties | Document lifecycle callbacks from `autoload/lean.vim` |
| `infoview.vim` | View state, windows, source selection, and user actions | Goal results and plain snapshots |
| `infoview_render.vim` | Text formatting and navigation-target construction | An explicit snapshot and rendering options |
| `pins.vim` | Source anchors, buffer listeners, and live pin requests | Refresh/pause/disposal decisions from the owning view |

`autoload/lean.vim` installs the LSP's document handlers. The transport never
imports a feature to notify it. Its existing diagnostic and workspace-edit
entry points remain forwarding functions for compatibility.

## Document and request lifetimes

A document identity is replaced when its buffer is renamed, its file is
reopened through the server, or its server is replaced. Detaching invalidates
it. A snapshot combines that identity with the buffer URI and `changedtick`.
Matching text or an unchanged LSP version alone cannot authorize an old reply:
the editor may contain a newer change that has not yet been sent to Lean.

A feature starts an operation with `requests.Begin(scope, bufnr)`. Starting
another operation in that scope cancels the previous one's RPCs and timers.
`Begin` attaches and flushes the document before taking its snapshot.
`requests.Send` and `requests.After` deliver work only while the operation and
its document are current. A window-bound action also captures its originating
window; cursor-sensitive actions check the cursor as well.

Document cleanup cancels all scopes registered for that buffer. This applies
to server restarts and file restarts as well as unloading. The LSP layer still
rejects messages from replaced processes and cancels queued requests before
initialization, independently of feature scopes.

Completion resolution is a deliberate exception to the document-text check:
Vim changes the buffer while previewing popup selections. Resolve requests
remain scoped and are cancelled when the selection changes. Acceptance checks
the complete expected preview before applying the chosen item's actual edits.
The numeric completion generation identifies popup items; it is not a second
transport request registry.

Workspace-edit-producing requests capture all open project documents. Their
replies are rejected if any captured document changes lifetime or revision.
The edit transaction also checks versioned targets against synchronized text,
preflights every operation, and attempts rollback if application fails.

## Infoview and live pins

The controller assembles a snapshot containing display names, goals, pins,
diagnostics, and processing state. `infoview_render.Build` returns lines and
navigation targets without reading editor state, modifying the model, or
starting requests. The controller writes that result to the view buffer.

Each live pin has its own request scope and source buffer. Following another
file does not retarget existing pins. Native zero-width text properties track
ordinary edits. A buffer listener records updated positions; when a
programmatic replacement discards those properties, a text-difference fallback
rebases and recreates them. Insertions at an anchor move it after the inserted
text; a deleted position collapses to the end of its replacement.

Pausing cancels pending requests and retains goal text, while source anchors
and jump targets continue to track edits. Closing a view suspends its requests
and preserves its pins for reopening. Clearing pins or closing their tab
removes their properties and releases unused listeners. Unloaded buffers have
an explicit unavailable state; a reload reconstructs their anchors against the
new text. Server restarts refresh pins through document synchronization events.

## Validation and extension

`make lint` checks the import boundaries and compiles every autoload module.
`make test` discovers every offline `test_*.vim` script.
The test runner reports uncaught Vim errors as failures and bounds process
lifetimes. The fake server can hold replies, ignore cancellation, and release
results in a chosen order; see [the harness guide](test/support/README.md).

New editor actions should use request scopes instead of adding independent
cancellation/generation maps. New rendering behavior should first be expressed
as a snapshot transformation and tested without a running server. Integration
tests cover actual editor events and protocol behavior. `make test-live` checks
goals, pin movement and refresh, completion acceptance, diagnostics, Lake
startup, and search paths against the installed Lean toolchain.
