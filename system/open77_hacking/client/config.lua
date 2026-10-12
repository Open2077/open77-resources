-- Operator defaults; a player's saved KEY BINDINGS selection takes precedence.
-- `hack` is held: press-and-hold opens the upload, release cancels it. `feedback`
-- gates the victim's client-local hit sound. Impact cues never use the quest fade: it can
-- interrupt native knockdown. Body effects and the HUD carry the visual feedback.
-- `freezeAfterKnockdownMs` is how long after a `freeze` effect the victim's client
-- waits before applying its own movement lock: the platform freeze always rides the
-- stationary knockdown, whose floor reaction and stand-up were measured at about 3 s
-- (2026-09-14), and the knockdown and the lock's stunned state must not be applied
-- in the same tick. A freeze shorter than this never locks (the knockdown covers it).
-- `opticsFallback` runs the bounded screen-flash substitute for Reboot Optics when the
-- client has no native status primitive (an older DLL): a short glitch burst at onset
-- and one flash at recovery, through `Open77.screen.transition`; it never replaces the
-- native blind on a client that has it.
HackingInput = {hack="F8",purgeSelf="INSERT",purgeAlly="DELETE",cancel="END",targetConeRadians=0.15,
    feedback={sound=true},freezeAfterKnockdownMs=3000,opticsFallback=true}
