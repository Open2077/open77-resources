"""Runs Lua 5.4 chunks for the offline compatibility tests.

Engines, in order: `lupa` when it is installed (the repository's existing test dependency),
otherwise a `lua54.dll` loaded through ctypes. The DLL comes from `OP77_LUA54_DLL`, else from
the KeraLua NuGet package cache (`~/.nuget/packages/keralua/*/runtimes/win-x64/native`), which
a machine that has built the Open77 server already holds. No network and no install step.
`unavailable()` returns why a test should be skipped when neither engine exists.
"""
import ctypes
import glob
import os
from pathlib import Path

HERE = Path(__file__).resolve().parent


def _dll_path():
    explicit = os.environ.get("OP77_LUA54_DLL")
    if explicit and Path(explicit).is_file():
        return explicit
    pattern = os.path.join(os.path.expanduser("~"), ".nuget", "packages", "keralua", "*",
                           "runtimes", "win-x64", "native", "lua54.dll")
    found = sorted(glob.glob(pattern))
    return found[-1] if found else None


def _has_lupa():
    try:
        import lupa  # noqa: F401
        return True
    except ImportError:
        return False


def unavailable():
    if _has_lupa():
        return None
    if os.name == "nt" and _dll_path():
        return None
    return "no Lua 5.4 engine: install lupa, or set OP77_LUA54_DLL to a lua54.dll"


class _CtypesLua:
    def __init__(self, path):
        dll = ctypes.CDLL(path)
        dll.luaL_newstate.restype = ctypes.c_void_p
        dll.luaL_openlibs.argtypes = [ctypes.c_void_p]
        dll.luaL_loadbufferx.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_size_t,
                                         ctypes.c_char_p, ctypes.c_char_p]
        dll.lua_pcallk.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_int, ctypes.c_int,
                                   ctypes.c_void_p, ctypes.c_void_p]
        dll.lua_tolstring.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_void_p]
        dll.lua_tolstring.restype = ctypes.c_char_p
        dll.lua_getglobal.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
        dll.lua_settop.argtypes = [ctypes.c_void_p, ctypes.c_int]
        dll.lua_close.argtypes = [ctypes.c_void_p]
        self.dll = dll
        self.state = dll.luaL_newstate()
        dll.luaL_openlibs(self.state)

    def execute(self, source, name):
        data = source.encode("utf-8")
        dll, state = self.dll, self.state
        if (dll.luaL_loadbufferx(state, data, len(data), name.encode(), b"t") != 0
                or dll.lua_pcallk(state, 0, 0, 0, None, None) != 0):
            message = dll.lua_tolstring(state, -1, None)
            dll.lua_settop(state, 0)
            raise RuntimeError((message or b"?").decode("utf-8", "replace"))

    def global_string(self, name):
        self.dll.lua_getglobal(self.state, name.encode())
        value = self.dll.lua_tolstring(self.state, -1, None)
        self.dll.lua_settop(self.state, 0)
        return None if value is None else value.decode("utf-8", "replace")

    def close(self):
        self.dll.lua_close(self.state)


class _LupaLua:
    def __init__(self):
        from lupa import LuaRuntime
        self.lua = LuaRuntime(unpack_returned_tuples=True)

    def execute(self, source, name):
        self.lua.execute(source)

    def global_string(self, name):
        value = self.lua.globals()[name]
        return None if value is None else str(value)

    def close(self):
        pass


def new_state():
    if _has_lupa():
        return _LupaLua()
    return _CtypesLua(_dll_path())


def lua_string(text):
    """A Lua long-bracket literal that `text` cannot close."""
    level = 0
    while ("]" + "=" * level + "]") in text:
        level += 1
    return "[" + "=" * level + "[" + text + "]" + "=" * level + "]"


def run_scenario(scenario_file, name, string_globals):
    """Fresh Lua state: fakehost.lua, the string globals, the scenario file, one scenario.
    Returns the scenario's results as a dict of strings."""
    lua = new_state()
    try:
        lua.execute((HERE / "fakehost.lua").read_text(encoding="utf-8"), "@fakehost.lua")
        for key, value in string_globals.items():
            lua.execute(f"{key} = {lua_string(str(value))}", "=globals")
        lua.execute((HERE / scenario_file).read_text(encoding="utf-8"), "@" + scenario_file)
        lua.execute(f"COMPAT_RESULT = RUN_SCENARIO({lua_string(name)})", "=run")
        text = lua.global_string("COMPAT_RESULT") or ""
    finally:
        lua.close()
    return dict(line.split("=", 1) for line in text.splitlines() if "=" in line)
