#!/usr/bin/env python3
"""A deterministic JSON-RPC peer used by the headless Vim integration test."""

from __future__ import annotations

import json
import pathlib
import sys
from typing import Any, BinaryIO


stream_in: BinaryIO = sys.stdin.buffer
stream_out: BinaryIO = sys.stdout.buffer
log_path = pathlib.Path(sys.argv[1])
sync_kind = int(sys.argv[2]) if len(sys.argv) > 2 else 2


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


def handle_request(message: dict[str, Any]) -> None:
    method = message["method"]
    if method == "initialize":
        response(
            message,
            {
                "capabilities": {
                    "textDocumentSync": sync_kind,
                    "hoverProvider": True,
                    "definitionProvider": True,
                    "codeActionProvider": True,
                    "semanticTokensProvider": {
                        "legend": {"tokenTypes": ["keyword"], "tokenModifiers": []},
                        "full": True,
                    },
                },
                "serverInfo": {"name": "fake-lean", "version": "1"},
            },
        )
    elif method == "$/lean/plainGoal":
        response(
            message,
            {
                "rendered": "case test\n⊢ Nat",
                "goals": ["case test\n⊢ Nat"],
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
        response(message, {"data": [0, 0, 3, 0, 0]})
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
        response(message, [])
    elif method == "textDocument/codeAction":
        response(message, [])
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
    document = message["params"]["textDocument"]
    uri = document["uri"]
    version = document["version"]
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
    elif incoming.get("method") == "textDocument/didOpen":
        opened(incoming)
    elif incoming.get("method") == "exit":
        break
