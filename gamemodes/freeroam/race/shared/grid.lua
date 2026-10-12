-- Shared by the authoritative grid and the editor's direction preview.
RaceStartingGrid = {}

function RaceStartingGrid.footSlot(start, index)
    local heading = start.heading or 0.0
    local yaw = math.rad(heading)
    local backward = (index - 1) * RaceConfig.engine.footStartSpacing
    -- REDengine yaw 0 faces +Y. Each subsequent runner stands behind it.
    return {
        position = {
            x = start.position.x + math.sin(yaw) * backward,
            y = start.position.y - math.cos(yaw) * backward,
            z = start.position.z,
        },
        heading = heading,
    }
end
