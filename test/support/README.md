# Controlled fake-server tests

Import `harness.vim` after adding the repository to `runtimepath`. The helper
provides bounded predicate polling, RPC-log reads, named scenarios, response
plans, delivery barriers, and shutdown-handshake checks.

The server keeps reading while replies are held. It deliberately retains held
replies after receiving cancellation, so tests can verify that the client
rejects them when eventually delivered.

```vim
harness.Plan(bufnr(), 'textDocument/hover', [
  {hold: 'older', result: {contents: 'old'}},
  {hold: 'newer', result: {contents: 'new'}},
])
# Issue the first request, then supersede it with another.
harness.Release(bufnr(), 'newer')
harness.Release(bufnr(), 'older')
```

A plan is consumed in request order. Each entry may specify a named `scenario`,
a complete `result` or `error`, and a `hold` label. `Release` can deliver a
label's replies in reverse order. It also waits for a barrier reply, proving
that the preceding control messages and released responses have been processed.
Use `harness.Barrier` to inspect a held request before changing editor state.
For timer-driven requests, first wait until the expected request appears in the
RPC log; a barrier cannot force a client timer to fire.

`harness.Hold` holds all requests of a method under a label. `harness.Scenario`
replaces that method's persistent profile. Plans take precedence over profiles.

Named completion scenarios are `default`, `unicode-prefix`, `replace-suffix`,
`insert-range`, `multiline`, `insert-text`, `mixed-ranges`, and `incomplete`.
Goal scenarios are `default`, `two-goals`, and `source-goal`. The last returns
the requested location and its synchronized source line, which allows pin
tests to verify both movement and document synchronization.

The command arguments after the log path select sync kind (`1` or `2`), startup
(`ready` or `hold-initialize`), and notification profile (`basic`, `none`,
`progress`, `stale-once`, or `stale-always`). A held initialization reply is
released with the `initialize` label. `test/configure` can assign notification
profiles to explicit document URIs; fixture filenames have no hidden behavior.

`listener_flush(bufnr)` delivers Vim's buffered change-listener events in a
headless test. Call `lean#OnChanged(bufnr)` after a programmatic edit when the
scenario needs the equivalent of a user-generated `TextChanged` event.
Remaining timer tests exercise client debounce and throttle behavior; the fake
server itself never sleeps to decide when a response should arrive.
