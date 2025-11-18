#!/usr/bin/env python3
"""AST-based detector for Python resource lifecycle issues."""
from __future__ import annotations

import ast
import sys
from pathlib import Path
from typing import Dict, List, Optional, Tuple

TARGET_SIGS: Dict[Tuple[Optional[str], str], str] = {
    (None, "open"): "file_handle",
    (None, "connect"): "socket_handle",
    (None, "Popen"): "popen_handle",
    (None, "popen"): "popen_handle",
    ("socket", "socket"): "socket_handle",
    ("subprocess", "Popen"): "popen_handle",
    ("asyncio", "create_task"): "asyncio_task",
    ("context", "WithCancel"): "context_cancel",
    ("context", "WithTimeout"): "context_cancel",
    ("context", "WithDeadline"): "context_cancel",
}

RELEASE_METHODS = {
    "file_handle": {"close"},
    "socket_handle": {"close"},
    "popen_handle": {"wait", "communicate", "terminate", "kill"},
    "asyncio_task": {"cancel"},
}

class ResourceRecord:
    __slots__ = ("name", "kind", "lineno", "released")

    def __init__(self, name: Optional[str], kind: str, lineno: int) -> None:
        self.name = name
        self.kind = kind
        self.lineno = lineno
        self.released = False


class Analyzer(ast.NodeVisitor):
    def __init__(self, tree: ast.AST) -> None:
        self.tree = tree
        self.aliases: Dict[str, Tuple[Optional[str], Optional[str]]] = {}
        self.records: List[ResourceRecord] = []
        self.by_name: Dict[str, List[ResourceRecord]] = {}
        self.safe_calls: set[int] = set()
        self.assigned_calls: set[int] = set()

    # Imports -------------------------------------------------------------
    def visit_Import(self, node: ast.Import) -> None:
        for alias in node.names:
            asname = alias.asname or alias.name
            self.aliases[asname] = (alias.name, None)

    def visit_ImportFrom(self, node: ast.ImportFrom) -> None:
        module = node.module or ""
        for alias in node.names:
            if alias.name == "*":
                continue
            asname = alias.asname or alias.name
            self.aliases[asname] = (module, alias.name)

    # With/async with -----------------------------------------------------
    def visit_With(self, node: ast.With) -> None:
        self._mark_safe(node.items)
        self.generic_visit(node)

    def visit_AsyncWith(self, node: ast.AsyncWith) -> None:
        self._mark_safe(node.items)
        self.generic_visit(node)

    def _mark_safe(self, items: List[ast.withitem]) -> None:
        for item in items:
            sig = self._call_signature_from_expr(item.context_expr)
            if sig and sig in TARGET_SIGS:
                self.safe_calls.add(id(item.context_expr))

    # Assignments --------------------------------------------------------
    def visit_Assign(self, node: ast.Assign) -> None:
        self._handle_assignment(node.targets, node.value)
        self.generic_visit(node)

    def visit_AnnAssign(self, node: ast.AnnAssign) -> None:
        if node.value is not None:
            self._handle_assignment([node.target], node.value)
        self.generic_visit(node)

    def _handle_assignment(self, targets: List[ast.expr], value: ast.AST) -> None:
        sig = self._call_signature(value)
        if not sig:
            return
        kind = TARGET_SIGS.get(sig)
        if not kind:
            return
        self.assigned_calls.add(id(value))
        names = [name for tgt in targets for name in self._collect_names(tgt)]
        if kind == "context_cancel":
            # expect second target to be cancel func
            if len(names) >= 2:
                self._add_record(names[1], kind, value.lineno)
            elif len(names) == 1:
                self._add_record(names[0], kind, value.lineno)
            else:
                self._add_record(None, kind, value.lineno)
            return
        if not names:
            self._add_record(None, kind, value.lineno)
            return
        for name in names:
            self._add_record(name, kind, value.lineno)

    def _collect_names(self, node: ast.expr) -> List[str]:
        if isinstance(node, ast.Name):
            return [node.id]
        if isinstance(node, (ast.Tuple, ast.List)):
            names: List[str] = []
            for elt in node.elts:
                names.extend(self._collect_names(elt))
            return names
        return []

    # Calls/releases -----------------------------------------------------
    def visit_Call(self, node: ast.Call) -> None:
        if id(node) not in self.assigned_calls:
            sig = self._call_signature(node)
            if sig and sig in TARGET_SIGS and id(node) not in self.safe_calls:
                self._add_record(None, TARGET_SIGS[sig], node.lineno)
        self._handle_release(node)
        self.generic_visit(node)

    def visit_Await(self, node: ast.Await) -> None:
        if isinstance(node.value, ast.Name):
            self._mark_released(node.value.id, "asyncio_task")
        self.generic_visit(node)

    def _handle_release(self, node: ast.Call) -> None:
        func = node.func
        if isinstance(func, ast.Attribute) and isinstance(func.value, ast.Name):
            name = func.value.id
            method = func.attr
            for kind, methods in RELEASE_METHODS.items():
                if method in methods:
                    self._mark_released(name, kind)
                    break
        elif isinstance(func, ast.Name):
            self._mark_released(func.id, "context_cancel")

    # Helpers ------------------------------------------------------------
    def _mark_released(self, name: str, kind: str) -> None:
        entries = self.by_name.get(name)
        if not entries:
            return
        for rec in entries:
            if not rec.released and rec.kind == kind:
                rec.released = True
                return

    def _add_record(self, name: Optional[str], kind: str, lineno: int) -> None:
        rec = ResourceRecord(name, kind, lineno)
        self.records.append(rec)
        if name:
            self.by_name.setdefault(name, []).append(rec)

    def _call_signature_from_expr(self, expr: ast.AST) -> Optional[Tuple[Optional[str], str]]:
        if isinstance(expr, ast.Call):
            return self._call_signature(expr)
        return None

    def _call_signature(self, call: ast.Call) -> Optional[Tuple[Optional[str], str]]:
        func = call.func
        if isinstance(func, ast.Name):
            module, obj = self.aliases.get(func.id, (None, None))
            if obj:
                return (module, obj)
            return (module, func.id)
        if isinstance(func, ast.Attribute):
            base = func.value
            attr = func.attr
            if isinstance(base, ast.Name):
                module, obj = self.aliases.get(base.id, (base.id, None))
                if attr in {"open", "connect", "Popen", "popen"}:
                    return (None, attr)
                if obj:
                    module = module or obj
                return (module, attr)
            if attr in {"open", "connect", "Popen", "popen"}:
                return (None, attr)
        return None

    def report(self, path: Path) -> List[str]:
        issues: List[str] = []
        for rec in self.records:
            if rec.released:
                continue
            issues.append(f"{path}:{rec.lineno}\t{rec.kind}\t")
        return issues


def collect_files(root: Path) -> List[Path]:
    ignored = {".git", "__pycache__", "node_modules", "dist", "build", ".venv", "env", "venv"}
    files: List[Path] = []
    for path in root.rglob("*.py"):
        if any(part in ignored for part in path.parts):
            continue
        files.append(path)
    return files


def analyze(path: Path) -> List[str]:
    try:
        text = path.read_text(encoding="utf-8")
    except OSError:
        return []
    try:
        tree = ast.parse(text)
    except SyntaxError:
        return []
    analyzer = Analyzer(tree)
    analyzer.visit(tree)
    return analyzer.report(path)


def main() -> None:
    if len(sys.argv) != 2:
        print("usage: resource_lifecycle_py.py <project_dir>", file=sys.stderr)
        sys.exit(2)
    root = Path(sys.argv[1])
    issues: List[str] = []
    for path in collect_files(root):
        issues.extend(analyze(path))
    if issues:
        print("\n".join(issues))


if __name__ == "__main__":
    main()
