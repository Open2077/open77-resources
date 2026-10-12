-- Emits Lua code, never executes imported text. %q safely quotes zone names.
local function position(p) return ('{x=%.6f,y=%.6f,z=%.6f}'):format(p.x,p.y,p.z or 0) end
local function serialize(zone)
    local options={'name='..string.format('%q',zone.name)}
    -- Box Z bounds are already scaled. Serialize the original bounds along
    -- with scale/offset, otherwise importing the export applies them twice.
    local bounds=zone.isBoxZone and zone._options or zone
    if bounds.minZ then options[#options+1]='minZ='..string.format('%.6f',bounds.minZ) end
    if bounds.maxZ then options[#options+1]='maxZ='..string.format('%.6f',bounds.maxZ) end
    if zone.isBoxZone then
        options[#options+1]='scale={'..table.concat(zone._scale,',')..'}'
        options[#options+1]='offset={'..table.concat(zone._offset,',')..'}'
    end
    if zone.isBoxZone then options[#options+1]='heading='..string.format('%.6f',zone:getHeading()) end
    if zone.isCircleZone then options[#options+1]='useZ='..tostring(zone.useZ) end
    local args
    if zone.isEntityZone or zone.isComboZone then error('polyzone: editor serializes polygon, box and circle zones')
    elseif zone.isCircleZone then args='CircleZone:Create('..position(zone.center)..', '..zone.radius
    elseif zone.isBoxZone then args='BoxZone:Create('..position(zone.center)..', '..zone.length..', '..zone.width
    else
        local points={}; for _,p in ipairs(zone.points) do points[#points+1]='    '..position(p) end
        args='PolyZone:Create({\n'..table.concat(points,',\n')..'\n}'
    end
    return 'local PZ = assert(require("@polyzone"))\nlocal PolyZone, BoxZone, CircleZone = PZ.PolyZone, PZ.BoxZone, PZ.CircleZone\n\nlocal zone = '..args..', {'..table.concat(options,', ')..'})\n'
end
return serialize
