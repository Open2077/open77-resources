local style, reason = Open77.locomotion.register('package.json')
assert(style, 'Locomotion package registration failed: ' .. tostring(reason))
