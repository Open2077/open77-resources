"""Static facts about the RP pack that the compatibility tests compare against frozen values.

Read-only: it parses manifests and Lua source with regular expressions, it never runs them.
The patterns cover the call forms the pack uses today (see docs/world-interaction/b8-compat-audit.md):
`exports.rp_x:fn(...)`, `exports.rp_x.fn(...)`, helper wrappers `call|callExport|callSync|ex|rp(
"rp_x", "fn", ...)` and `Open77.exports.call[Sync]("rp_x", "fn", ...)`.
"""
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]

_DECLARE = re.compile(r'(?<![\w.:])exports\(\s*"([A-Za-z_][A-Za-z0-9_]*)"')
_USES = (
    re.compile(r'exports\.(rp_[a-z_]+)\s*[:.]\s*([A-Za-z_][A-Za-z0-9_]*)'),
    re.compile(r'\b(?:call|callExport|callSync|ex|rp)\(\s*"(rp_[a-z_]+)"\s*,\s*"([A-Za-z_][A-Za-z0-9_]*)"'),
    re.compile(r'Open77\.exports\.call(?:Sync)?\s*,?\s*\(?\s*"(rp_[a-z_]+)"\s*,\s*"([A-Za-z_][A-Za-z0-9_]*)"'),
)
_MANIFEST_EXPORTS = re.compile(r'server_exports\s*\{([^}]*)\}')
_CREATE = re.compile(r'CREATE TABLE IF NOT EXISTS\s+`?(rp_[a-z_]+)`?\s*\((.*?)\)\s*(?:\]\]|")', re.S)


def resources():
    return sorted(p.name for p in ROOT.iterdir() if p.is_dir() and p.name.startswith("rp_"))


def lua_files(resource):
    return sorted(p for p in (ROOT / resource).rglob("*.lua") if p.name != "open77.lua")


def _code_lines(path):
    for number, line in enumerate(path.read_text(encoding="utf-8-sig").splitlines(), 1):
        if not line.lstrip().startswith("--"):
            yield number, line


def manifest(resource):
    text = (ROOT / resource / "open77.lua").read_text(encoding="utf-8-sig")
    code = "\n".join(line for line in text.splitlines() if not line.lstrip().startswith("--"))
    ships_client = bool(re.search(r'^\s*(client_scripts?|shared_scripts?)\b', code, re.M))
    dependencies = re.findall(r'^\s*dependency\s+"([^"\s]+)', code, re.M)
    for block in re.findall(r'dependencies\s*\{([^}]*)\}', code):
        dependencies += re.findall(r'"([^"\s]+)', block)
    exported = []
    for block in _MANIFEST_EXPORTS.findall(code):
        exported += re.findall(r'"([A-Za-z_][A-Za-z0-9_]*)"', block)
    return {"ships_client": ships_client, "dependencies": dependencies, "server_exports": exported}


def declared_server_exports(resource):
    names = set(manifest(resource)["server_exports"])
    for path in lua_files(resource):
        if path.parent.name == "client":
            continue
        for _, line in _code_lines(path):
            names.update(_DECLARE.findall(line))
    return names


def consumed_exports():
    """{(provider, export): [ "consumer/path.lua:line", ... ]} for calls across resources."""
    uses = {}
    for resource in resources():
        for path in lua_files(resource):
            rel = path.relative_to(ROOT).as_posix()
            for number, line in _code_lines(path):
                for pattern in _USES:
                    for provider, name in pattern.findall(line):
                        if provider != resource:
                            uses.setdefault((provider, name), []).append(f"{rel}:{number}")
    return uses


def schema():
    """{table: normalised column list} from every CREATE TABLE IF NOT EXISTS in the pack."""
    tables = {}
    for resource in resources():
        for path in lua_files(resource):
            text = path.read_text(encoding="utf-8-sig")
            for table, body in _CREATE.findall(text):
                tables[table] = " ".join(body.split())
    return tables
