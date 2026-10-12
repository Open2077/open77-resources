-- Shared presentation for the running target and the course editor. The low
-- cylinder shows the acceptance radius; the raised arrow identifies the landing.
RaceFootMarkers = {}

function RaceFootMarkers.definitions(position, radius, finish, distance)
    local color = finish and { r = 255, g = 196, b = 64, a = 220 }
        or { r = 34, g = 216, b = 226, a = 220 }
    return {
        {
            position = { x = position.x, y = position.y, z = position.z + 0.08 },
            shape = "cylinder", radius = radius, height = 0.35,
            maxDistance = distance, color = color,
        },
        {
            position = { x = position.x, y = position.y, z = position.z + 2.0 },
            shape = finish and "diamond" or "arrow", radius = 0.65, height = 1.25,
            maxDistance = distance, color = color,
        },
    }
end
