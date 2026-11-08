# Run isolated Lua unit tests with the Lua 5.4 DLL shipped alongside the server.
param([string] $LuaDll = (Join-Path $PSScriptRoot '../../../../lua54.dll'), [string] $Test = 'map3d_test.lua')
$ErrorActionPreference = 'Stop'
$resolvedDll = (Resolve-Path -LiteralPath $LuaDll).Path
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class LightRpLuaTests {
  [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate IntPtr NewState();
  [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate void StateCall(IntPtr state);
  [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int Load(IntPtr state, [MarshalAs(UnmanagedType.LPUTF8Str)] string file, IntPtr mode);
  [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int Call(IntPtr state, int nargs, int results, int err, IntPtr context, IntPtr continuation);
  [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate IntPtr Text(IntPtr state, int index, out UIntPtr length);
  static T Fn<T>(IntPtr dll, string name) where T : Delegate => Marshal.GetDelegateForFunctionPointer<T>(NativeLibrary.GetExport(dll, name));
  public static void Run(string path, string test) {
    var dll = NativeLibrary.Load(path);
    var state = Fn<NewState>(dll, "luaL_newstate")();
    try {
      Fn<StateCall>(dll, "luaL_openlibs")(state);
      int code = Fn<Load>(dll, "luaL_loadfilex")(state, test, IntPtr.Zero);
      if (code == 0) code = Fn<Call>(dll, "lua_pcallk")(state, 0, -1, 0, IntPtr.Zero, IntPtr.Zero);
      if (code != 0) throw new Exception(Marshal.PtrToStringUTF8(Fn<Text>(dll, "lua_tolstring")(state, -1, out var length)));
    } finally { Fn<StateCall>(dll, "lua_close")(state); NativeLibrary.Free(dll); }
  }
}
'@
$previous = [Environment]::CurrentDirectory
try {
    [Environment]::CurrentDirectory = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    [LightRpLuaTests]::Run($resolvedDll, (Join-Path $PSScriptRoot $Test))
} finally { [Environment]::CurrentDirectory = $previous }
