local package=json.decode(LoadResourceFile(GetCurrentResourceName(),"package.json"))
assert(package and package.schema=="open77.prop-package/1","invalid arena asset package")
for id,definition in pairs(package.models) do
    local alias,reason=Open77.props.registerModel(id,definition)
    assert(alias,"arena model "..id..": "..tostring(reason))
end
print("[aetherfall-assets] registered revision="..package.revision)
