#!/usr/bin/env python3
"""Keep the module dependency graph acyclic and its lower layers independent."""

from pathlib import Path
import re

root = Path(__file__).resolve().parents[1]
modules = {p.relative_to(root / "autoload").as_posix(): p
           for p in (root / "autoload").rglob("*.vim")}
graph = {name: set(re.findall(r"import autoload '([^']+)'", path.read_text()))
         for name, path in modules.items()}


def visit(name: str, chain: tuple[str, ...] = ()) -> None:
    assert name not in chain, "module cycle: " + " -> ".join((*chain, name))
    assert name in graph, f"missing module: {name}"
    for dependency in graph[name]:
        visit(dependency, (*chain, name))


for name in graph:
    visit(name)

boundaries = {
    "lean/infoview_render.vim": set(),
    "lean/documents.vim": {"lean/util.vim"},
    "lean/workspace.vim": {"lean/util.vim"},
    "lean/decorations.vim": {"lean/util.vim", "lean/config.vim"},
    "lean/lsp.vim": {"lean/util.vim", "lean/config.vim", "lean/documents.vim",
                     "lean/workspace.vim", "lean/decorations.vim"},
}
for name, allowed in boundaries.items():
    assert graph[name] <= allowed, f"{name} imports a higher layer: {graph[name] - allowed}"

print(f"PASS architecture: {len(graph)} modules, no dependency cycles")
