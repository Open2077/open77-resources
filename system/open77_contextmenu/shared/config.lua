ContextMenuConfig = {
    key = "ALT",
    blockNativeWeaponWheel = true, -- Resource lifetime claim, before the first ALT press.
    appearance = {
        accentColor = "#18d6e7", -- #RRGGBB: eye, hover highlight and spinner.
        scale = 1.0, -- Compact by default; 0.75 to 1.5 for readability.
        showGroups = false, -- Optional small headings; labels/icons only by default.
    },
    rayDistance = 12.0, -- From the camera. Actions separately enforce player distance.
    maxActions = 24,
    idlePollMs = 100,
    activePollMs = 25,
    revalidateMs = 200,
    exportTimeoutMs = 750,
    lookupBudgetMs = 1500, -- Total budget across all display predicates.
}
