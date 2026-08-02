#!/usr/bin/env python3
"""A deterministic JSON-RPC peer used by the headless Vim integration test."""

from __future__ import annotations

import json
import pathlib
import sys
import time
from typing import Any, BinaryIO


stream_in: BinaryIO = sys.stdin.buffer
stream_out: BinaryIO = sys.stdout.buffer
log_path = pathlib.Path(sys.argv[1])
sync_kind = int(sys.argv[2]) if len(sys.argv) > 2 else 2
initialize_delay = float(sys.argv[3]) if len(sys.argv) > 3 else 0.0
emit_open_notifications = bool(int(sys.argv[4])) if len(sys.argv) > 4 else True


def log(message: dict[str, Any]) -> None:
    with log_path.open("a", encoding="utf-8") as output:
        output.write(json.dumps(message, ensure_ascii=False) + "\n")


def send(message: dict[str, Any], split: bool = False) -> None:
    payload = json.dumps(message, ensure_ascii=False, separators=(",", ":")).encode()
    framed = f"Content-Length: {len(payload)}\r\n\r\n".encode() + payload
    if split:
        midpoint = len(framed) // 2
        stream_out.write(framed[:midpoint])
        stream_out.flush()
        stream_out.write(framed[midpoint:])
    else:
        stream_out.write(framed)
    stream_out.flush()


def read_message() -> dict[str, Any] | None:
    headers: dict[str, str] = {}
    while True:
        line = stream_in.readline()
        if not line:
            return None
        if line == b"\r\n":
            break
        key, value = line.decode("ascii").split(":", 1)
        headers[key.lower()] = value.strip()
    body = stream_in.read(int(headers["content-length"]))
    return json.loads(body)


def response(request: dict[str, Any], result: Any) -> None:
    send({"jsonrpc": "2.0", "id": request["id"], "result": result})


last_opened_uri = ""
open_counts: dict[str, int] = {}


def message_uri_fallback(message: dict[str, Any]) -> str:
    """workspace/symbol has no textDocument; reuse the last opened URI."""
    params = message.get("params", {})
    if isinstance(params, dict):
        document = params.get("textDocument", {})
        if isinstance(document, dict) and "uri" in document:
            return document["uri"]
    return last_opened_uri


def handle_request(message: dict[str, Any]) -> None:
    method = message["method"]
    if method == "initialize":
        if initialize_delay:
            time.sleep(initialize_delay)
        response(
            message,
            {
                "capabilities": {
                    "textDocumentSync": sync_kind,
                    "hoverProvider": True,
                    "definitionProvider": True,
                    "codeActionProvider": True,
                    "completionProvider": {
                        "triggerCharacters": ["."],
                        "resolveProvider": True,
                    },
                    "inlayHintProvider": True,
                    "documentSymbolProvider": True,
                    "workspaceSymbolProvider": True,
                    "semanticTokensProvider": {
                        "legend": {
                            "tokenTypes": ["keyword", "variable", "property"],
                            "tokenModifiers": [],
                        },
                        "full": True,
                    },
                },
                "serverInfo": {"name": "fake-lean", "version": "1"},
            },
        )
    elif method == "textDocument/completion":
        position = message["params"]["position"]
        line = position["line"]
        if line == 3:
            # Slow reply: lets the client supersede and cancel this request.
            time.sleep(0.4)
        if line == 1:
            # The fixture line is `-- α😊abc`; the edit starts at the α
            # (UTF-16 unit 3), before the client's local word start, and the
            # replacement keeps the typed base as its prefix so Vim's popup
            # filtering can display it.
            response(
                message,
                {
                    "isIncomplete": False,
                    "items": [
                        {
                            "label": "abcγδ",
                            "kind": 6,
                            "textEdit": {
                                "range": {
                                    "start": {"line": 1, "character": 3},
                                    "end": {
                                        "line": 1,
                                        "character": position["character"],
                                    },
                                },
                                "newText": "abcγδ",
                            },
                        }
                    ],
                },
            )
        else:
            response(
                message,
                {
                    "isIncomplete": line == 5,
                    "items": [
                        {
                            "label": "succ",
                            "kind": 3,
                            "detail": "Nat → Nat",
                            "insertText": "succ",
                            "sortText": "1",
                            "data": {"marker": "succ"},
                        },
                        {
                            "label": "theorem_item",
                            "kind": 23,
                            "insertText": "thm",
                            "sortText": "2",
                        },
                    ],
                },
            )
    elif method == "completionItem/resolve":
        resolved = dict(message["params"])
        resolved["documentation"] = {
            "kind": "markdown",
            "value": "resolved documentation",
        }
        response(message, resolved)
    elif method == "textDocument/inlayHint":
        # Fixture line 2 is `-- α😊abc`: character 6 sits after the emoji, so
        # the byte column must be UTF-16 converted. The out-of-range hint and
        # the surrogate-bisecting one (character 5) must both be dropped.
        response(
            message,
            [
                {
                    "position": {"line": 0, "character": 7},
                    "label": ": Nat",
                    "kind": 1,
                    "paddingLeft": True,
                },
                {
                    "position": {"line": 1, "character": 6},
                    "label": [{"value": "param"}, {"value": ":"}],
                    "kind": 2,
                },
                {
                    "position": {"line": 1, "character": 5},
                    "label": "inside surrogate",
                    "kind": 1,
                },
                {
                    "position": {"line": 9999, "character": 0},
                    "label": "out of range",
                    "kind": 1,
                },
            ],
        )
    elif method == "$/lean/plainGoal":
        uri = message["params"]["textDocument"]["uri"]
        line = message["params"]["position"]["line"]
        if (uri.endswith("/Editor.lean") or uri.endswith("/Basic.lean")) and line == 3:
            time.sleep(0.1)
        goals = ["case test\n⊢ Nat"]
        if uri.endswith("/Editor.lean") and line == 1:
            goals.append("case second\n⊢ Nat")
        response(
            message,
            {
                "rendered": "case test\n⊢ Nat",
                "goals": goals,
            },
        )
    elif method == "$/lean/plainTermGoal":
        response(
            message,
            {
                "goal": "Nat",
                "range": {
                    "start": {"line": 1, "character": 10},
                    "end": {"line": 1, "character": 11},
                },
            },
        )
    elif method == "textDocument/hover":
        response(message, {"contents": {"kind": "markdown", "value": "```lean\nNat\n```"}})
    elif method == "textDocument/semanticTokens/full":
        # keyword "def" (0-3), variable "answer" (4-10), property ":" (11);
        # by default only the keyword may be rendered.
        response(
            message,
            {"data": [0, 0, 3, 0, 0, 0, 4, 6, 1, 0, 0, 7, 1, 2, 0]},
        )
    elif method in {"textDocument/definition", "textDocument/declaration"}:
        response(
            message,
            {
                "uri": message["params"]["textDocument"]["uri"],
                "range": {
                    "start": {"line": 0, "character": 0},
                    "end": {"line": 0, "character": 3},
                },
            },
        )
    elif method == "textDocument/references":
        response(
            message,
            [
                {
                    "uri": message["params"]["textDocument"]["uri"],
                    "range": {
                        "start": {"line": 0, "character": 6},
                        "end": {"line": 0, "character": 12},
                    },
                }
            ],
        )
    elif method == "textDocument/codeAction":
        response(message, [])
    elif method == "codeAction/resolve":
        resolved = dict(message["params"])
        resolved["command"] = {
            "title": "resolved action",
            "command": "fake.resolvedAction",
        }
        response(message, resolved)
    elif method == "textDocument/documentSymbol":
        response(
            message,
            [
                {
                    "name": "answer",
                    "kind": 14,
                    "range": {
                        "start": {"line": 0, "character": 0},
                        "end": {"line": 1, "character": 10},
                    },
                    "selectionRange": {
                        "start": {"line": 0, "character": 4},
                        "end": {"line": 0, "character": 10},
                    },
                    "children": [
                        {
                            "name": "nested",
                            "kind": 12,
                            "range": {
                                "start": {"line": 1, "character": 2},
                                "end": {"line": 1, "character": 8},
                            },
                            "selectionRange": {
                                "start": {"line": 1, "character": 2},
                                "end": {"line": 1, "character": 8},
                            },
                        }
                    ],
                }
            ],
        )
    elif method == "workspace/symbol":
        response(
            message,
            [
                {
                    "name": "Nat.succ_le",
                    "kind": 24,
                    "containerName": "Nat",
                    "location": {
                        "uri": message_uri_fallback(message),
                        "range": {
                            "start": {"line": 0, "character": 0},
                            "end": {"line": 0, "character": 3},
                        },
                    },
                }
            ],
        )
    elif method == "$/lean/prepareModuleHierarchy":
        response(
            message,
            {
                "name": "Basic",
                "uri": message["params"]["textDocument"]["uri"],
            },
        )
    elif method.startswith("$/lean/moduleHierarchy/"):
        response(message, [])
    elif method in {"shutdown", "workspace/executeCommand"}:
        response(message, None)
    else:
        send(
            {
                "jsonrpc": "2.0",
                "id": message["id"],
                "error": {"code": -32601, "message": f"unknown method {method}"},
            }
        )


def opened(message: dict[str, Any]) -> None:
    global last_opened_uri
    document = message["params"]["textDocument"]
    last_opened_uri = document["uri"]
    if not emit_open_notifications:
        return
    uri = document["uri"]
    version = document["version"]
    if "StaleImports" in uri:
        # Lean's watchdog reports stale imports on the file's first line.
        # "Fixed" clears on reopen (imports were rebuilt); "Broken" reports
        # stale on every open, like a build that keeps failing.
        open_counts[uri] = open_counts.get(uri, 0) + 1
        stale = "Broken" in uri or open_counts[uri] == 1
        diagnostics = []
        if stale:
            diagnostics = [
                {
                    "range": {
                        "start": {"line": 0, "character": 0},
                        "end": {"line": 0, "character": 1},
                    },
                    "severity": 1,
                    "source": "lean",
                    "message": (
                        "Imports are out of date and must be rebuilt; "
                        'use the "Restart File" command in your editor.'
                    ),
                }
            ]
        send(
            {
                "jsonrpc": "2.0",
                "method": "textDocument/publishDiagnostics",
                "params": {"uri": uri, "version": version, "diagnostics": diagnostics},
            }
        )
        return
    if "Progress" in uri:
        # Whole-file processing, like Lean's first fileProgress notification.
        line_count = document.get("text", "").count("\n") + 1
        send(
            {
                "jsonrpc": "2.0",
                "method": "$/lean/fileProgress",
                "params": {
                    "textDocument": {"uri": uri, "version": version},
                    "processing": [
                        {
                            "range": {
                                "start": {"line": 0, "character": 0},
                                "end": {"line": line_count - 1, "character": 0},
                            },
                            "kind": 1,
                        }
                    ],
                },
            }
        )
        return
    send(
        {
            "jsonrpc": "2.0",
            "method": "textDocument/publishDiagnostics",
            "params": {
                "uri": uri,
                "version": version,
                "diagnostics": [
                    {
                        "range": {
                            "start": {"line": 1, "character": 0},
                            "end": {"line": 1, "character": 3},
                        },
                        "severity": 2,
                        "source": "lean",
                        "message": "test warning",
                    },
                    {
                        "range": {
                            "start": {"line": 2, "character": 0},
                            "end": {"line": 2, "character": 0},
                        },
                        "severity": 1,
                        "isSilent": True,
                        "leanTags": [1],
                        "message": "unsolved goals",
                    }
                ],
            },
        },
        split=True,
    )
    send(
        {
            "jsonrpc": "2.0",
            "method": "$/lean/fileProgress",
            "params": {
                "textDocument": {"uri": uri, "version": version},
                "processing": [
                    {
                        "range": {
                            "start": {"line": 2, "character": 0},
                            "end": {"line": 2, "character": 0},
                        },
                        "kind": 1,
                    }
                ],
            },
        }
    )


def changed(message: dict[str, Any]) -> None:
    """Send a deliberately stale diagnostic to exercise client versioning."""
    document = message["params"]["textDocument"]
    version = document["version"]
    send(
        {
            "jsonrpc": "2.0",
            "method": "textDocument/publishDiagnostics",
            "params": {
                "uri": document["uri"],
                "version": version - 1,
                "diagnostics": [
                    {
                        "range": {
                            "start": {"line": 0, "character": 0},
                            "end": {"line": 0, "character": 3},
                        },
                        "severity": 1,
                        "source": "lean",
                        "message": "stale warning",
                    }
                ],
            },
        }
    )


while True:
    incoming = read_message()
    if incoming is None:
        break
    log(incoming)
    if "id" in incoming and "method" in incoming:
        handle_request(incoming)
    elif incoming.get("method") == "initialized":
        send(
            {
                "jsonrpc": "2.0",
                "id": 900,
                "method": "workspace/configuration",
                "params": {"items": [{"section": "lean"}]},
            }
        )
        send(
            {
                "jsonrpc": "2.0",
                "id": 901,
                "method": "client/registerCapability",
                "params": {"registrations": []},
            }
        )
    elif incoming.get("method") == "textDocument/didOpen":
        opened(incoming)
    elif incoming.get("method") == "textDocument/didChange":
        changed(incoming)
    elif incoming.get("method") == "exit":
        break
