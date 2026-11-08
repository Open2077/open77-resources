"""Export the real Lua strings and Audio section for the browser regression."""
import json
from pathlib import Path
from lupa.lua54 import LuaRuntime

root = Path(__file__).resolve().parents[1]
lua = LuaRuntime()
lua.execute((root / "shared/strings.lua").read_text(encoding="utf-8"))
lua.execute("Open77={webui={getVolume=function() return 35 end,setVolume=function() return true end}}")
lua.execute((root / "client/web_audio.lua").read_text(encoding="utf-8"))

def convert(value):
    if not hasattr(value, "items"):
        return value
    items = list(value.items())
    if items and all(isinstance(k, int) for k, _ in items):
        return [convert(value[i]) for i in range(1, len(items) + 1)]
    return {k: convert(v) for k, v in items}

print(json.dumps({"strings": convert(lua.globals().PauseStrings),
                  "section": convert(lua.globals().PauseWebAudio.section())}))
