-- Cordon -- THE EDGE. The boundary of the open blocks, drawn in the world by
-- the client that has to look at it.
--
-- ---------------------------------------------------------------------------
-- WHY THIS FILE IS ON THE CLIENT, WHICH IS THE WHOLE DESIGN
--
-- The plan (section 4, layer 3) proposed a SERVER-owned edge: red `kind =
-- "light"` props spaced along every closed edge, ~300 of them, moved with
-- `setTransform` as blocks close. Experiment E8 was written to measure whether
-- that survives 64 players. It never ran, and it no longer has to, because
-- three facts about this platform -- all of them readable in the tree, none of
-- them needing the game -- make the server-owned version the expensive way to
-- get a worse result:
--
--   1. `Open77.props.create` and `Open77.vfx.play` EXIST IN THE CLIENT RUNTIME.
--      `scripting/src/ResourceHost.cpp` registers both tables for a client
--      resource (`OpenSandbox`, the `Open77.props` and `Open77.vfx` tables) and
--      gates them on `world.props` / `world.effects`, which this resource's
--      manifest already declares. Its own comment at the props table states the
--      contract: a client resource "reaches only the *local*, decorative half
--      of this surface: `create` charges the calling resource's quota and never
--      replicates."
--   2. THE CLIENT ALREADY HAS THE DATA. `cordon:bounds` carries the grid
--      geometry and the entire open-cell list, and is published ON CHANGE only
--      (server/cordon.lua, `C.publish`). `shared/grid.lua` is a `shared_script`
--      and is pure arithmetic with no engine calls, so the block maths that
--      decides who bleeds is the same code that decides where the edge is
--      drawn. There is no second opinion to get wrong, and no new message.
--   3. A REPLICATED EDGE IS THE ONE COST THIS MODE CANNOT AFFORD. E1
--      (docs/research/battle-royale-and-scale.md) measured the un-culled
--      snapshot relay at ~326 KB/s per player and watched it kill the link at
--      the transport's 256 KB/s clamp. Three hundred props with their own
--      per-player interest sets, retransformed on every closure, is more of
--      exactly that. Drawn here it is zero bytes.
--
-- So: the server owns the RULE (which cells are open, who bleeds), the client
-- owns the PICTURE. That is the same split the tac-map already uses.
--
-- ---------------------------------------------------------------------------
-- WHAT IS DRAWN, AND HOW IT ANSWERS "WHICH WAY IS IN?"
--
-- Each boundary segment -- one side of one open block whose neighbour is closed
-- or off the grid -- gets a handful of POSTS at its quarter points. A post is
-- two things:
--
--   * a LIGHT, red, offset well onto the CLOSED side. This is the layer that
--     answers the question. The ground you must not stand on glows and the
--     ground behind you does not, so "in" is simply "away from the red". Stand
--     outside and the red is under your feet. A `kind = "light"` prop with
--     `collision = false` is a bare light with no geometry and no collider --
--     `client/src/api/Props.cpp` says so at `canDropCollision`: "switching them
--     off is how a light prop hides the crate it came with".
--   * a COLUMN, a world VFX, essentially on the line. `smoke.column.black` is
--     `e_smoke_exterior_column_black_5x5x50_d2` -- five metres wide and fifty
--     tall -- which is the only curated alias in `kVfxCatalog` that reads from
--     across a district. Lit red from its base it is "NCPD burned the block".
--
-- NOBODY IS WALLED (plan decision 3), and this cannot break that by accident. A
-- VFX has no collider at all, and the light prop's only physical component is
-- the one `collision = false` switches off. No value in `Config.cordon.edge`
-- produces a wall.
--
-- ===========================================================================
-- THE BUG THIS FILE WAS REWRITTEN FOR, AND THE MEASUREMENT BEHIND EVERY BUDGET
-- BELOW. Read this before changing a number.
--
-- The first version of this file NEVER DREW ANYTHING, in a seventeen-minute
-- session on 2026-09-02 in which the cordon armed, closed, bled and drove the
-- HUD correctly. It left exactly one line in the client log:
--
--   23:39:12.598 [error] [resource:open77_cordon]
--     open77_cordon/client/edge.lua:288: Open77 script execution budget exceeded
--       edge.lua:288 in upvalue 'wantedPosts'
--       edge.lua:461 in upvalue 'rebuild'
--       edge.lua:632 in function <edge.lua:596>
--
-- ONE line, at the first rebuild, and then silence for fourteen more minutes --
-- because `ResumeTask` in scripting/src/ResourceHost.cpp `return true`s on a
-- Lua error, which RETIRES THE TASK. A `CreateThread` loop that raises once is
-- gone for the rest of the session. The mode looked like it had no edge code at
-- all.
--
-- WHAT THE BUDGET ACTUALLY IS. `ResourceHost::Tick` computes
-- `instanceSlice = config.frameBudget / runningCount`, floored at 50 us (300 us
-- since 2026-09-18, one hook interval; the reasoning below is unchanged), and
-- `ResumeTask` gives every coroutine resume a wall-clock deadline of that
-- slice. On this client `frameBudget` is 2000 us (ClientResourceHost.cpp) and
-- the 23:36 session had 25 resources running, so ONE PASS OF THIS LOOP GETS
-- EIGHTY MICROSECONDS. `InstructionHook` fires every 10 000 VM instructions and
-- raises on `Clock::now() > deadline` -- so it is WALL CLOCK that kills, not the
-- 500 000-instruction ceiling, and a pass that merely *allocates a lot* dies
-- just as fast as one that loops forever.
--
-- WHY IT BLEW. The scan window is sized in METRES (`drawRadiusMetres = 150`)
-- and walked in CELLS. Commit 8542bf1 -- landed the same evening, by a second
-- agent, on the same message -- made the cordon close a LATTICE and cut the
-- cell pitch on Watson from 100 m to 25 m. The radius did not change, so the
-- number of cells inside it went up SIXTEENFOLD: the window stopped being the
-- 5x5 this file's original comment promised and became the entire 8x8 grid.
-- Sixty-four cells x five `Grid.key()` calls each is 320 `string.format`
-- allocations, plus a `table.sort` with a Lua comparator, plus sixteen prop and
-- sixteen VFX spawns -- all inside one 80 us resume. The claim "the cost does
-- not grow with the map" was true of blocks and false of a lattice.
--
-- SO THE REWRITE HOLDS FOUR RULES, and each one is a direct answer to that:
--
--   1. NO STRING KEYS IN THE HOT LOOP. The open set is indexed by the INTEGER
--      `col * 4096 + row`, built once per cordon revision (and in chunks, so
--      even a 784-cell lattice cannot blow one pass). The scan then costs
--      integer arithmetic and integer table lookups and allocates nothing.
--   2. THE WINDOW IS WALKED IN BOUNDED CHUNKS. See the second bug below: this
--      rule used to read "the window is bounded in CELLS", which is what broke
--      the feature the second time.
--   3. ONE JOB PER PASS. A pass does at most one of {index a chunk, walk a
--      chunk of the scan window, close the scan and diff, raise/retire
--      `postsPerTick` posts, write one status line}. Sixteen engine spawns in
--      one resume cannot happen any more; the edge fades in over a second or
--      two instead.
--   4. AN OVERRUN MUST NOT BE FATAL. The pass runs under `pcall`, and a
--      heartbeat watchdog restarts the poll thread if it dies anyway -- because
--      the hook can also fire in the few instructions between the `pcall`
--      returning and the `Wait`, which is outside anything this file can catch.
--      A silently dead layer is the defect that made the original invisible.
--
-- ===========================================================================
-- THE SECOND BUG, 2026-09-03: IT SAID IT WAS DRAWING AND DREW ALMOST NOTHING.
--
-- The rewrite above fixed the budget error and shipped a boundary the owner
-- still could not see, twice. The client log
-- (`red4ext/logs/open77-2026-09-03-02-45-12.log`) carried the reassuring line
-- `first post up (vfx=true light=true)` and, underneath it, the real story:
--
--   * 206 light hosts created in one 35-minute session, for a layer whose cap
--     is SIXTEEN posts;
--   * never more than NINE standing at the same time;
--   * median post lifetime 11.7 s, tenth percentile 3.4 s;
--   * the very first post stood ALONE for fifteen seconds.
--
-- Two causes, and the first is the one that matters.
--
-- CAUSE 1 -- THE DRAW RADIUS COLLAPSED TO A THIRD, SILENTLY. `maxCellRadius`
-- was introduced above as a COST bound and became a REACH bound:
-- `min(drawRadiusMetres, maxCellRadius * grid.size)` with `maxCellRadius = 2`.
-- `grid.size` is the LATTICE pitch that `cordon.lua` publishes
-- (`blockMetres = lattice.blockMetres`, i.e. `blockSize / factor`), which on
-- Watson is 100/4 = 25 m. So the configured 150 m boundary was drawn at 50 m.
-- The mode's own HUD reports "NEAREST OPEN BLOCK 113 m" to a player standing
-- outside the cordon -- more than twice the radius -- so at the exact moment the
-- boundary is the only thing worth drawing, the scan window contained no open
-- cell at all, the plan came back empty, and the layer retired every post it
-- had. Correct, empty, and invisible.
--
-- The fix is not a bigger clamp. Cost is now bounded where it belongs, in how
-- many cells ONE PASS may walk (`scanCellsPerPass`), and the window is walked
-- across as many passes as it takes. Reach is bounded in metres again. This is
-- the same shape as `indexStep` and `applyStep`, which the rewrite already got
-- right and then did not apply to the scan.
--
-- CAUSE 2 -- POSTS WERE RETIRED FASTER THAN THEY COULD APPEAR. A post is a
-- particle graph plus a spawned entity whose light component is resolved over
-- several game-thread ticks; the owner's client was running its Open77 frame at
-- 8 Hz. A post that lives 3.4 seconds never finishes. The diff now KEEPS a post
-- that has merely fallen out of the nearest-`maxSegments` set while it is still
-- within `holdRadiusFactor` of the draw radius, and raises two posts per pass
-- instead of one.
--
-- ---------------------------------------------------------------------------
-- WHAT A HANDLE PROVES, WHICH IS LESS THAN IT LOOKS.
--
-- `Open77.props.create` returning an id means `Api::Props::Create` allocated one
-- and queued a `DynamicEntityService::Spawn`; the entity can still fail
-- component resolution ticks later and set `failed = true`, and Lua is never
-- told. `Open77.vfx.play` returning a handle means `gameFxSystem.SpawnEffect`
-- accepted the resource reference -- not that a `.effect` authored for a quest
-- context renders standing on its own. `open77_groundcircle/client/main.lua`
-- opens with exactly this complaint about the native marker and is worth
-- reading before trusting anything here.
--
-- So `report` now writes one line every `statusIntervalMs` carrying what the
-- ENGINE says: props held, rendered, failed, live effects, the scan radius and
-- window, the segment count, the player's position and the nearest post's. If
-- that line reads `posts=16 rendered=16 failed=0 ... nearest post d=40m` and the
-- street is still empty, the geometry is right and the PRIMITIVE is what does
-- not draw -- which is the one reading that separates the two explanations, and
-- it was not obtainable at all before.
--
-- ---------------------------------------------------------------------------
-- STILL NOT MEASURED. Three things remain guesses until somebody looks:
-- whether a client-local VFX with `duration = 0` survives a streaming round
-- trip; whether `e_smoke_exterior_column_black_5x5x50_d2` renders standalone at
-- all (`docs/research/vfx-sfx-runtime.md` lists validating the curated aliases
-- on 2.31 as an OPEN experiment, and the only aliases proven visible through
-- `gameFxSystem.SpawnEffect` are the short-lived tracer/impact/explosion ones);
-- and what `intensity` reads as outdoors in daylight. Every one of them is a
-- config value, and `cordonEdge = "hud"` turns the whole layer off from the
-- Warden panel without touching a file.
--
-- AND ONE CORRECTION: the note that used to sit here said "17:30, which is when
-- a match starts". 17:30 is the LONG schedule's DURATION
-- (`Config.cordon.schedules.long`), not a clock time. The mode does not set the
-- time of day at all, so the light is seen at whatever hour the world is in.
-- ---------------------------------------------------------------------------

-- ===========================================================================
-- THE THIRD ROUND, 2026-09-03: THE ENGINE SAID YES AND THE STREET WAS EMPTY.
--
-- The scan-radius fix above landed and the layer now reports, in the owner's own
-- log, everything a healthy layer reports:
--
--   posts=32 (props=32 rendered=32 failed=0 vfx=32) radius=150m window=8x8
--   segments=22 open=30 rev=39 scanAt=(-1216.9,2044.2,7.8)
--   nearest post=(-1207.5,2003.5,7.9) d=42m
--
-- `rendered` and `failed` are the ENGINE's own words, read back from
-- `Open77.props.list()`. Thirty-two entities resolved. The owner then stood
-- twenty-two metres from a post, facing it, and photographed the street: the
-- HUD's own OUTSIDE THE CORDON / NEAREST OPEN BLOCK panel drew perfectly and
-- there was no column, no light, nothing.
--
-- That is exactly the discriminator the paragraph above promised. Geometry
-- right, engine says rendered, no pixels ==> THE PRIMITIVE IS WHAT DOES NOT
-- DRAW. Nothing more can be learned by tuning a budget in this file.
--
-- SO THE BOUNDARY IS NOW DRAWN WHERE NOTHING CAN SWALLOW IT: PROJECTED.
--
-- `resources/system/open77_groundcircle/client/main.lua` reached this conclusion first
-- and wrote it down: "when any link of that chain fails to produce pixels, the
-- native registry still reports the marker as rendered, so a caller cannot tell
-- a drawn ring from an invisible one." So it stopped asking the engine to draw.
-- It samples world points, projects each one through `Open77.camera.project`,
-- and strokes the result as an SVG polyline on a transparent WebUI surface.
-- WHAT IT COMPUTES IS WHAT IS DRAWN -- there is no engine-side render path left
-- to fail silently, and that resource ships.
--
-- This file now does the same, and the split is the one it already believes in
-- one level up. The server owns the RULE, this client owns the GEOMETRY, and
-- `open77_cordon_hud` owns the PIXELS:
--
--   * the scan below is UNCHANGED. It still finds the boundary segments inside
--     `drawRadiusMetres`, sorted nearest first, in bounded chunks;
--   * `wallStep` publishes the nearest `wall.maxPanels` of those segments as a
--     local event, `cordon:edge:wall`, carrying world metres and nothing else;
--   * `open77_cordon_hud/client/wall.lua` projects those endpoints against the
--     live camera and strokes them on its own surface.
--
-- WHY A LOCAL EVENT AND NOT AN EXPORT. `TriggerEvent` on the CLIENT is
-- dispatched to every running resource's handlers -- `ResourceHost::QueueEvent`
-- walks the whole resource table -- which is already how `cordon:hurt` reaches
-- the HUD from `open77_cordon/client/main.lua`. (The "one VM, no exports" rule
-- in this resource's manifest is about the SERVER runtime; it does not apply
-- here.) An export would invert the direction and make the HUD poll this file
-- from its own frame loop, which would put a string-formatting ground lookup
-- inside a 20 Hz tick for no gain.
--
-- WHY THE PROJECTION IS NOT DONE IN THIS FILE. It has to happen at display rate
-- -- roughly twenty times a second, four native round trips per panel. This file
-- gets EIGHTY MICROSECONDS per resume (the budget note above) and has already
-- died inside it twice. The HUD's surface tick is where per-display-frame work
-- belongs and is already built that way. What crosses between them is a handful
-- of metres that changes only when the player has walked twenty of them.
--
-- WHAT IT BUYS AND WHAT IT COSTS. It buys a CONTINUOUS boundary rather than
-- sixteen discrete points, at any map scale, for zero entities and zero bytes
-- on the wire. It costs the two things a screen overlay always costs, stated
-- here rather than discovered later: it is NOT occluded by geometry, so the
-- wall shows through a megabuilding; and it is sampled on a Lua tick, so it
-- trails the view under a fast camera whip. Both are the trade
-- `open77_groundcircle` accepted knowingly, in writing, and shipped.
--
-- THE WORLD LAYER IS KEPT AND DEMOTED, NOT DELETED. The red LIGHT is the only
-- half of a post that is diegetic -- lit, fogged and occluded by geometry for
-- free -- so it stays as a near-field accent for the day the primitive is
-- proven. The COLUMN does not: `smoke.column.black` is a quest-authored
-- `.effect` that `docs/research/vfx-sfx-runtime.md` still lists as an
-- UNVALIDATED alias on 2.31, it is sixteen effect handles per client, and it
-- has never once been seen by anybody. It is now OPT-IN
-- (`Config.cordon.edge.column.enabled = true`) instead of opt-out. No code is
-- removed; one boolean restores it the day somebody proves the alias renders.
--
-- AND THE SCAN NOW RUNS UNDER `cordonEdge = "hud"`, which it did not before:
-- the whole pass returned early unless the style was "world", so the one
-- setting with no entity cost was also the one setting with no boundary. "hud"
-- now means what its config comment always claimed -- the boundary on screen,
-- nothing in the world -- and it is the zero-entity way to play the mode.
--
-- ===========================================================================
-- THE FOURTH ROUND, 2026-09-03: THE PROJECTED WALL IS THE THING THE OWNER SAW,
-- AND IT IS THE WRONG PRIMITIVE. THE BOUNDARY MOVES BACK INTO THE WORLD, ON
-- GEOMETRY THIS PLATFORM HAS ACTUALLY PROVEN DRAWS.
--
-- The owner played the mode with the projected wall live and reported three
-- things, with screenshots. Every one of them is a cost the section above had
-- already written down as accepted:
--
--   1. "we see it while not even being in front of it" -- IT IS NOT OCCLUDED.
--      A screen overlay is not depth-tested, so the boundary paints over the
--      megabuilding standing between the player and it.
--   2. "there is a straight line in front of us [with] a gap under it" -- IT
--      DOES NOT SIT ON THE GROUND. Not a z bug: a ground line a hundred metres
--      away projects NEAR THE HORIZON, which on screen is eye height, and with
--      nothing drawn between the player and it there is no perspective cue that
--      it is a ground line at all. Correct arithmetic, unreadable picture.
--   3. "it is cut from one angle to another" -- the panels are the nearest
--      `maxPanels` SEGMENTS, sorted by distance, which around a corner or a
--      concave lattice is a set of DISJOINT lines rather than a run. Turning the
--      camera swaps which ones are on screen.
--
-- None of the three is a bug to fix in the page. They are what a screen overlay
-- is, and they were accepted on the strength of one belief: that no world
-- primitive on this platform can be trusted to produce pixels. THAT BELIEF WAS
-- TOO BROAD, and checking it is what this round did.
--
-- WHAT THE RESEARCH FOUND (docs/research/battle-royale-and-scale.md, the
-- 2026-09-03 section on the boundary; every claim there is sourced):
--
--   * THE GAME HAS NO RUNTIME AREA-DELIMITER TO CALL. The owner asked whether
--     Cyberpunk already ships something for this. It does not, and the reason is
--     structural rather than an oversight: `gameWorldBoundaryNode`,
--     `worldTriggerAreaNode` and `SecurityAreaController` all descend from
--     `worldAreaShapeNode` or are devices -- BAKED INTO STREAMING SECTORS at
--     editor time -- and expose ZERO callable methods across the 51 738
--     functions of the 2.31 RTTI manifest. There is no setter to hand a moving
--     rectangle to. The one vanilla system that reacts to a boundary at runtime,
--     `gameWorldBoundarySystem`, teleports the player back with a glitch shader,
--     which is the exact thing decision 3 forbids -- and Open77 already patches
--     its tick out (`client/src/world/WorldBoundaryPatch.cpp`). The only vanilla
--     AREA RENDERING is `gameuiMinimapSecurityAreaMappinController`, an
--     `inkShapeWidget` on the minimap. Nothing world-space, nothing callable.
--   * BUT THE GAME'S OWN BARRICADES ARE REACHABLE, AND THEY ARE THE ONLY WORLD
--     PRIMITIVE IN THIS TREE WITH IN-GAME PROOF. `Open77.props.create` with
--     `kind = "prop"` spawns a real mesh from the curated alias table in
--     `client/src/api/Props.cpp`, and that table already carries Night City's
--     entire vocabulary for a closed street: `barrier.roadblock.concrete`,
--     `barrier.hesco`, `barrier.road.jersey`, `barrier.tire_blocker`,
--     `fence.wire.reinforcement`. `wiki/props.md`'s status block records the
--     measurement, on 2026-08-28, on two clients: "A prop draws the model you
--     ask for." Compare that with what the same tree says about the two
--     primitives this file has been leaning on -- `Open77.markers`' "rendering
--     status is contested and must not be assumed working", and not ONE of the
--     51 curated VFX aliases recorded as visually confirmed on 2.31.
--
-- So the boundary is now built out of engine geometry. A mesh prop is depth
-- sorted, lit, fogged and occluded BY THE ENGINE, for free -- which answers
-- complaints 1 and 2 outright rather than mitigating them -- and it stands on
-- the surveyed ground plane, which is what "sits on the ground" means.
--
-- NOBODY IS WALLED, AND THE GUARANTEE IS NOW STRONGER THAN IT WAS. It does not
-- rest on `collision = false`: `wiki/props.md` is explicit that the flag CANNOT
-- be honoured on a mesh prop, because the host's single `entPhysicalMeshComponent`
-- is both the solid component and the visible one, so dropping collision would
-- blank the prop -- the request is refused with a warning and the prop stays
-- solid. It rests instead on the ALIAS: `docs/generated/prop-hosts.json` carries
-- a `collision` boolean per host, and `barrier.roadblock.concrete` is one of the
-- 68 whose mesh ships no `meshMeshParamPhysics` at all. It is hollow in vanilla
-- too; the roadblocks you walk past in Night City are solid only because a level
-- author placed a separate collision node beside them, and nothing places one
-- here. THE RULE THAT FOLLOWS: any alias put in `Config.cordon.edge.barrier.model`
-- must read `"collision": false` in `docs/generated/prop-hosts.json`. Choosing
-- one that reads true gives this mode a wall, which is a design violation and
-- not a visual tweak.
--
-- WHAT A POST IS NOW -- three layers with three different jobs and three
-- different ranges, which is the whole reason the old post read badly:
--
--   * a BARRIER, on every post. A concrete roadblock, yawed to lie ALONG the
--     line and scaled so one prop spans most of the post pitch. This is the
--     layer the player reads at walking distance, and it is the only one proven
--     to draw.
--   * a RED LIGHT, on MARKER posts only. Unchanged, and still the layer that
--     answers "which way is in": it sits well onto the closed side, so the
--     ground you must not stand on glows and the ground behind you does not.
--   * a SMOKE COLUMN, on MARKER posts only. Unchanged, and demoted to the
--     marker pitch for a reason that is not budget: fifty metres of black smoke
--     every six metres would be an opaque lid over the street, and a player
--     cannot fight what they cannot see. At the marker pitch it is what it was
--     always meant to be -- the thing you read from across the district.
--
-- AND THE POSTS ARE NOW PLACED IN TWO PASSES, WHICH IS THE OTHER HALF OF THE
-- FIX. The old placement walked segments nearest-first and filled each one to
-- `spacingMetres` until the budget ran out, so a boundary was either evenly
-- sparse everywhere (a picket line with 25 m gaps: exactly complaint 3 moved
-- into the world) or dense on two segments and absent on the rest. Now:
--
--   PASS 1, THE MARKERS. One post at the middle of EVERY segment in range,
--     before any infill. This is the skeleton, and it is what makes a distant
--     boundary read continuous -- at a hundred metres, perspective foreshortening
--     closes a 25 m gap on its own.
--   PASS 2, THE CURTAIN. The remaining slots of the segments inside
--     `denseRadiusMetres`, nearest first, until `maxPosts`. This is what makes
--     the near boundary read as a barricade rather than as bollards.
--
-- THE SLOT LATTICE IS FIXED BY GEOMETRY, NOT BY DISTANCE, and that is not a
-- detail -- it is what stops the two passes from re-introducing the churn the
-- 2026-09-03 log measured (206 light hosts in one session for a sixteen-post
-- layer). A slot's position depends only on the segment and `spacingMetres`, so
-- the key `"<col>,<row>:<side>:<slot>"` a post is held under NEVER MOVES when
-- the player walks toward it. Approaching a segment ADDS slots around the ones
-- already standing; retreating drops them and the `holdRadiusFactor` hysteresis
-- keeps them anyway while they are still nearby. Nothing is ever destroyed and
-- respawned a metre from where it was.
--
-- THE PROJECTED WALL IS NOT DELETED. It is now the boundary of `cordonEdge =
-- "hud"` and of nothing else -- see `wallEnabled` -- because under "hud" there
-- is no world layer and a mode with no visible boundary is the one thing this
-- design cannot ship. Under "world" it is off, and the honest reason is the
-- owner's three complaints: it is redundant with geometry that does not have
-- them. `Config.cordon.edge.wall.enabled = true` forces it back for a bisect.
--
-- STILL NOT MEASURED, and named here because a config value that is a guess must
-- say so: which LOCAL AXIS of `concrete_roadblock_w100_h110.mesh` runs along its
-- length (`barrier.lengthAxis` flips it, and that is the one adjustment this is
-- expected to need); whether a non-uniform `scale` is honoured on a `.mesh` host
-- in practice -- `wiki/props.md` says it is, and the failure is graceful if it is
-- not, since an unscaled roadblock every six metres is still a visible dotted
-- line on the tarmac; and what the light's `intensity` reads as outdoors in
-- daylight, which no round has yet looked at.
--
-- ===========================================================================
-- THE FIFTH ROUND, 2026-09-03: THE BOUNDARY WAS BUILT AT THE HEIGHT OF A KERB
-- AND ASKED TO BE READ FROM FIFTY METRES. IT IS NOW BUILT OUT OF THE LARGEST
-- HOLLOW OBJECT IN THE CATALOGUE AND THE ONLY EFFECT WITH A SCREENSHOT.
--
-- The fourth round shipped, the owner played a full match, and the report was
-- the same one word: nothing. What is different this time is that the log of
-- that match survives (`red4ext/logs/open77-2026-09-03-18-33-40.log`) and it
-- settles two questions that four rounds of reasoning could not.
--
-- FIRST, AND IT RETIRES THE BELIEF THE LAST THREE ROUNDS WERE BUILT ON: THE
-- PROP DRAWS, AND IT HAS BEEN PHOTOGRAPHED. The capture band table in
-- `docs/research/battle-royale-and-scale.md` records the 1 m band as taken, on
-- Watson: "bloc de beton plein, pose au sol, occultant". A
-- `barrier.roadblock.concrete` was seen, on the ground, occluding. The alias ->
-- host -> mesh chain works. Nothing in this file needs to keep hedging about
-- whether `Open77.props.create` produces pixels.
--
-- SECOND, AND IT IS THE ONE THAT MATTERS: THE PICTURE IS TOO SMALL, AND THAT IS
-- ARITHMETIC RATHER THAN AN OPINION.
--
--   * `barrier.roadblock.concrete` is `concrete_roadblock_w100_h110.mesh`, and
--     the mesh names its own size: ONE METRE WIDE, 1.1 M HIGH. At `up = 1.4`
--     the barricade is a metre and a half of kerbstone.
--   * Twenty status lines from that match report the nearest post between
--     **51 and 56 metres** for the entire cordon, and never nearer than 5 m.
--   * A 1.5 m object at 51 m subtends **1.7 degrees**. That is the angular size
--     of a parked bollard. At the 150 m draw radius it is 0.57 degrees.
--   * Past `denseRadiusMetres = 45` only the MARKER post exists, so the far
--     field was one 5 m slab per 25 m lattice cell -- spacing that reads as
--     street furniture, not as a line.
--
-- Every one of those forty props could have been drawing perfectly and the
-- honest report would still have been "I see nothing". Four rounds were spent
-- asking whether the primitive renders; the question that needed asking was how
-- big the thing being rendered is.
--
-- The same research note already wrote the 150 m half of this down -- "a 133 m,
-- on ne voit rien ... une barricade est un objet au sol d'un ou deux metres, et
-- a 133 m elle ne lit pas" -- and stopped there. What was never carried across
-- is that THE SAME ARITHMETIC HOLDS AT FIFTY, which is the one band of the four
-- that has never been captured (eight attempts, eight different obstacles, not
-- one of them rendering). That missing photograph is the gap the cause walked
-- through for three rounds.
--
-- AND IT IS ALSO THE BEST AVAILABLE EVIDENCE AGAINST THE COLUMN. In the 133 m
-- capture the telemetry reads `vfx=15` against `markers=15`: fifteen smoke
-- columns were STANDING. A 5 x 5 x 50 m column at 133 m occupies a large
-- fraction of the frame, and the image shows none. Not proof -- Little China is
-- terraced and the post was 12 m lower than the camera -- but it is the only
-- observation there is, and it points one way.
--
-- THIRD: `rendered=62 failed=0` NEVER MEANT WHAT THIS FILE HOPED IT MEANT, and
-- the code says so. `Props::SnapshotAll` sets
-- `rendered = entry.entity.has_value() && !entry.failed`
-- (client/src/api/Props.cpp), and for `kind = "prop"` NOTHING converts a host
-- entity that resolved with no usable mesh component into a failure: the branch
-- in `Props::Tick` that does that is guarded on `kind == Kind::Light` and is the
-- only one. So the line this file added in round two to be the discriminator
-- between "geometry wrong" and "primitive dead" cannot discriminate, and never
-- could. A warning was added on that path in Props.cpp so the NEXT log can.
--
-- (What the log does prove: every barrier reached its authored host -- 263
-- `Prop N spawned from host entity ...open77_prop_barrier_roadblock_concrete.ent`
-- lines -- with no `host entity unavailable` fallback, and not one
-- `carries no entLightComponent`, which means the light host resolves its light
-- component and the asset archive is intact. Whatever else is true, the alias
-- chain is not broken.)
--
-- FOURTH, AND IT IS WHY THE LAYER LOOKED FROZEN: THE HYSTERESIS HELD THE
-- PREVIOUS CORDON. `nearest post=(-1271.5,2039.4,11.9)` is IDENTICAL across
-- eight consecutive status lines and thirty-three cordon revisions (rev=14 to
-- rev=47) while the open set fell from 53 cells to 22, with `posts=40` pinned at
-- exactly `maxTotalPosts`. The diff kept any post within 172 m of the scan
-- origin whether or not the boundary it stood on still existed. See the note at
-- the hysteresis itself; a post now carries the revision it was planned for.
--
-- SO WHAT A POST IS NOW -- four layers, each sized for the distance it has to be
-- read at, and ordered by how much evidence stands behind it:
--
--   * a BASTION, on MARKER posts. `container.shipping` is
--     `industrial_container_a.mesh`, a shipping container of roughly
--     6 x 2.4 x 2.6 m -- the largest hollow object in the curated catalogue, and
--     one of the four `wiki/props.md` names when it lists "things that look like
--     they should stop you". Laid along the line and stretched, it is a dozen
--     metres of steel per lattice cell. This is the layer that answers "I see
--     nothing".
--   * a BURN, on MARKER posts. `fire.small`, and it is the ONLY curated VFX
--     alias in this tree with a captured frame behind it: research section 31.1 played
--     it from server Lua and wrote down "a fire visibly burning on the steps"
--     with a screenshot, and E0.5 separately survived a 385 m stream round trip
--     on the same effect as a `duration = 0` loop. Fire is emissive, so it reads
--     in daylight and at night; it is depth sorted and fogged by the engine; and
--     it has a plume, which is vertical extent no 1.5 m prop can buy.
--   * a BARRICADE, on every slot. The roadblock, unchanged, doing the job it is
--     actually the right size for: the kerb line you walk up to.
--   * a RED LIGHT, on MARKER posts. Unchanged in kind, brighter and wider in
--     degree -- `intensity` was 140 against an admin default of 20, which is
--     bright in a room and nothing on a street at noon.
--
-- AND THE COLUMN IS OFF. `smoke.column.black` has been carried through four
-- rounds on the strength of its size and has never been seen by anybody;
-- `docs/research/vfx-sfx-runtime.md` still lists the curated aliases as an OPEN
-- experiment. One boolean brings it back the day somebody proves it renders, and
-- the fire takes its slot with better evidence behind it.
-- ===========================================================================

-- ===========================================================================
-- THE SIXTH ROUND, 2026-09-03: THE WALL NEVER APPEARED, THE CONTAINERS WERE
-- LYING ACROSS THE LINE, AND NOBODY HAD MEASURED A SINGLE MESH. THE MESHES ARE
-- NOW MEASURED, AND THE BUDGET IS SPENT WHERE THE PLAYER IS LOOKING.
--
-- The fifth round shipped and the owner's report was, for the third time, that
-- there is still no proper visual delimiter on the approach. His session's own
-- telemetry:
--
--   posts=16 (markers=16 barriers=16 bastions=16 burns=16 stale=16 props=48
--   rendered=48 failed=0 vfx=16) radius=150m window=8x8 nearest post d=54m
--
-- Three things in that one line, and none of them is a rendering question.
--
-- FIRST, THE CURTAIN NEVER EXISTED. `denseRadiusMetres` was 45 and the nearest
-- post sat at 54 m for the whole match, so pass 2 never placed a single infill
-- post: `posts=16` IS `markers=16`. What the owner saw for an entire match was
-- the MARKER tier alone -- one container and one 5 m roadblock per 25 m lattice
-- cell -- which is a row of landmarks at 20 % duty, and a row of landmarks is
-- not a line. The eye reads a barrier from CONTINUITY (gap smaller than object)
-- and from VERTICAL EXTENT; the marker tier had neither, by construction.
--
-- SECOND, THE CONTAINERS WERE LYING THE WRONG WAY. Every size in this file was
-- a guess ("roughly 6 x 2.4 x 2.6 m"), and every axis convention was a guess
-- (`lengthAxis = "y"`). This round read the bounding boxes out of the cooked
-- meshes themselves, offline, with WolvenKit (`extract` + `convert serialize`
-- against `basegame_3_nightcity.archive`, no game launched) -- the same
-- instrument research section 24 used to prove that prop origins sit at the base.
-- The numbers, in mesh-local metres, X / Y / Z, origin at Z=0 unless stated:
--
--   industrial_container_a.mesh       4.82 x 2.67 x 1.94   length is local X,
--                                                          centred in XY
--   hesco_barrier_a_high_single_a     1.58 x 1.59 x 2.01   origin at a vertical
--                                                          edge: X -1.54..0.04,
--                                                          Y -0.04..1.54
--   concrete_roadblock_w100_h110      1.01 x 1.00 x 1.14   square in plan
--   road_barrier_02_a (jersey)        5.10 x 0.69 x 0.99   origin at one END,
--                                                          X 0..5.1
--   pedestrian_barrier_a              1.00 x 4.10 x 1.26   length is local Y
--   wire_fence_reinforcement_a        1.50 x 0.43 x 1.10   origin at one end
--   electrical_pole_a                 1.44 x 1.21 x 6.12
--   rooftop_water_tower_a             5.52 x 5.56 x 10.91
--   checkpoint_a                      2.54 x 1.83 x 2.60
--   common_holograms_a_w500_h150      5.00 x 0.00 x 1.50   a flat plane, X -5..0
--
-- and the one that is not a mesh: the `race.route_arrow` host copies the
-- authored `localTransform` of `sq024_gps_path.ent`, quaternion
-- (-0.5, 0.5, -0.5, 0.5) with position (-0.75, -2.5, +0.10). Multiplying that
-- out, the hologram lies FLAT, 1.5 m across by 5 m along ENTITY +Y, centred on
-- the entity origin and ten centimetres above it -- so its long axis is the
-- `lengthAxis = "y"` convention this file already uses, and no centring is
-- needed.
--
-- So `container.shipping` with `lengthAxis = "y"` put the container's 2.67 m
-- side along the line and its 4.82 m side across it. Fixed by measurement:
-- `lengthAxis = "x"`. And the hesco, which this round builds the wall out of,
-- has its origin at a corner, which is why `raiseBarricade` grew a `centre`
-- offset: a prop placed by its origin would stand 0.75 m off the slot.
--
-- THIRD, `rendered=48 failed=0` STILL PROVES NOTHING and this file has stopped
-- pretending otherwise -- the fifth-round note above already established why.
-- The evidence rule for this round is: every layer names what proves it draws,
-- and a layer with no proof is labelled UNVERIFIED in its config block, counted
-- separately on the status line so a screenshot can be read against it, and
-- chosen so that its failure costs nothing but itself.
--
-- WHAT IS DRAWN NOW -- three TIERS by distance rank, and the budget goes to the
-- nearest one because the player only ever looks at one arc of the boundary:
--
--   TIER 1, THE MARKERS. Unchanged in principle: one post at the middle of each
--     of the nearest `maxSegments` segments, the skeleton that keeps a distant
--     boundary continuous. A marker carries the CONTAINER (now the right way
--     round), the FIRE, the red LIGHT, and optionally a BLAZE and a MAST.
--   TIER 2, THE RAMPART. The nearest `wallPosts` (40) slots at `spacingMetres`
--     (2 m) -- roughly eighty metres of the boundary nearest the player, whatever
--     its distance -- each carrying a HESCO bastion. A 1.6 m sand cube two metres
--     tall every two metres is 80 % duty UNSCALED and a continuous wall at
--     `along = 1.15`; it is the game's own military cordon, and it is hollow
--     (`"collision": false`). Every other wall slot carries a STRIP -- the
--     orange chevron hologram, flat on the line -- and every third one a
--     BEACON, a small red light on top of the wall. This tier is what the owner
--     walks up to and what he sees from fifty metres.
--   TIER 3, THE FILL. Beyond the rampart, every `fillStride`-th slot (4 m)
--     carries the concrete ROADBLOCK -- the one prop with a photograph -- until
--     `maxPosts`, so the wall tapers into a dotted kerb line instead of ending.
--
-- THE ARITHMETIC, on Watson's 25 m lattice (13 slots of 1.92 m per segment):
--
--   distance   rampart (hesco, 2.0 m tall unscaled / 2.8 m at up=1.4)
--      5 m     each cube 18 deg wide, 22 deg tall (31 deg scaled); gaps 0.35 m
--              = 4 deg unscaled, ~0.2 m = 2 deg scaled: a wall, not a picket
--     50 m     cubes 1.8 deg wide, 2.3 deg tall (3.2 scaled), gap 0.4 deg:
--              a continuous band the height of a bus, 80 m long = 77 deg of
--              the view when seen square-on
--    150 m     the rampart is behind the player or 0.76 deg tall; the marker
--              row carries it: a container every 9.5 deg, each 1.8 x 0.74 deg
--              unscaled (4.6 x 1.5 deg at along=2.5, up=2.0), a fire and, at
--              night, a 70 m red pool per marker overlapping its neighbours
--
--   strip (hologram, 1.5 x 5 m, emissive orange, flat): every 2 slots = 3.85 m
--     pitch, so consecutive 5 m panels OVERLAP by 1.15 m -- a continuous
--     glowing line on the tarmac, 1.5 m wide: 17 deg wide at 5 m, 1.7 deg at
--     50 m, 0.57 deg at 150 m (a bright line stays visible below 1 deg where a
--     grey one does not, which is the whole reason for an emissive ground layer)
--
-- WHAT IS PROVEN AND WHAT IS NOT, per layer -- see each config block:
--   roadblock   drawn and photographed at 1 m (research capture band table)
--   hesco       same host generator, same chain, mesh measured whole; NOT
--               photographed
--   container   same; NOT photographed; axis now measured
--   light       coloured pools photographed at night on two clients (research
--               33.4, 33.8); daylight unmeasured
--   fire.small  photographed from the SERVER path (31.1); client path unmeasured
--   strip       host exists (`race.route_arrow`), transform measured; UNVERIFIED
--   beacon      the same light host as `light`; UNVERIFIED at this radius
--   blaze       `fire.large`, same authored family as fire.small; UNVERIFIED
--   mast        `street.electrical_pole`, 6.1 m, measured; UNVERIFIED and OFF
--   scale       `visualScale` on a mesh host has never been photographed; every
--               scale in the config is chosen so unit scale still reads
--
-- AND TWO MECHANICAL CHANGES THE BUDGET NOTE AT THE TOP REQUIRES: post keys are
-- now INTEGERS (`slotKey`), so a plan of eighty posts allocates eighty tables
-- and zero strings; and the candidate sort has its own pass (`scanSort`) so it
-- never shares a resume with the plan build.
-- ===========================================================================

-- ===========================================================================
-- THE SEVENTH ROUND, 2026-09-04: THE BOUNDARY IS SEEN, AND IT IS FURNITURE.
--
-- The owner confirmed the wall in game -- "ok we can see the elements spawning
-- for the cordon closing right now", telemetry `posts=95 ... props=165
-- rendered=165 failed=0 vfx=38`, zero refusals -- and in the same breath said
-- what was wrong with it: "its not dynamic enough and it would be better with
-- like fire effect over it or smth when u see it from the inside". Six rounds
-- were spent on whether the boundary DRAWS and how BIG it is. Both are settled
-- and nothing below touches either. This round is about whether it MOVES.
--
-- A wall of sandbags with a static red lamp every six metres is scenery: the
-- eye reads it as "somebody parked barriers here", not as "this is closing on
-- you". Three additions, each on a primitive with evidence behind it, each one
-- boolean in `Config.cordon.edge` to remove, and none of them a new post:
--
--   * THE FLAME. `fire.small` on the crest of the hesco, every third wall
--     slot, alternating with the beacons. The fire animates itself -- no tick,
--     no update call -- and it is the alias with the most evidence in the tree:
--     a captured frame from the server path (research §31.1) and nineteen
--     accepted handles in the owner's own confirming session. It answers the
--     owner's sentence literally. See `flame` in the config.
--   * THE CHASE. The beacons alternate lit/dark on a slow beat, out of phase
--     with their neighbours, so a red light is always travelling along the
--     wall. Light hosts are photographed on two clients (§33.4, §33.8) and
--     `enabled` is written to the live component without a respawn (§33.6;
--     `Props.cpp` keeps it out of the structural set on purpose). The cost is
--     one `props.update` per beacon per beat, drained a few per pass by
--     `lampStep` on a pass of its own -- the fourth bounded queue in this file,
--     built the same way as the other three.
--   * THE SURGE. A closure is now a moment: every lamp on the line flares
--     white-hot for a few seconds and settles, and each marker of the line
--     being swallowed goes up in the barrel explosion as it is retired --
--     `explosion.frag`, the effect the shipped grenade path plays through the
--     same native (`SpawnExplosion`, client/src/api/Combat.cpp). Only markers,
--     only within seventy metres, only four seconds each.
--
-- AND A CEILING, because the second addition is the first thing in this file
-- that can ask for a sixty-fifth effect. `effectCount` tracks every VFX handle
-- held; the decorative layers (flame, blaze, blast) are refused above
-- `maxEffects` and say so on the status line; the burn -- the proven skeleton
-- -- is never gated. The arithmetic is at `maxEffects` in the config.
--
-- WHAT THIS DOES NOT DO. It does not touch a mesh, a size, a spacing or a
-- radius. It does not put anything on the line that could block a player: a
-- fire has no collider, and a lamp that blinks is the same hollow host as a
-- lamp that does not. And it does not resurrect the screen-space wall.
--
-- EVIDENCE STATUS, per addition: flame -- alias proven, THIS PLACEMENT (on the
-- crest, 2.4 m) not photographed; chase -- primitive and the in-place toggle
-- proven, the PATTERN not photographed; surge flare -- colour writes proven,
-- not photographed at this intensity; blast -- effect proven through the
-- combat path, not photographed from `Open77.vfx.play`. Each is counted on the
-- status line (`flames=`, `chase=`, `surge=`, `blasts=`) so a capture can be
-- read against it.
-- ===========================================================================

-- ===========================================================================
-- THE EIGHTH ROUND, 2026-09-04: TWO LINES, MADE OF FIRE AND LIGHT.
--
-- The owner played the seventh round and gave the verdict this file was
-- waiting for, because it is the first one about DESIGN rather than about
-- pixels. Verbatim: "le principe de voir la zone et ce que tu spawn c'est de
-- savoir que la zone s'approche au fur et a mesure et qu'il faut avancer vers
-- la prochaine zone a la apex, la on a pas du tout cette impression" -- and,
-- of the material, "a la place de props de mur en beton, pourquoi on utilise
-- pas autre chose qui peut faire un effet plutot du jeu".
--
-- Both are right, and neither is a sizing question. Seven rounds made ONE
-- boundary visible; a single boundary is a fence you happen to be near. What
-- makes a battle-royale zone a zone is that you can see the NEXT one before
-- it arrives, and a wall of sandbags -- however continuous -- says "somebody
-- parked barriers here", not "the city is closing on you". So:
--
--   * THE SECOND LINE. `cordon:bounds` has always carried `closing`, the cells
--     the announced phase is going to take; the tac-map flashes them amber and
--     this file ignored them. The scan now indexes them too and produces a
--     second class of segment: a side of an OPEN, SURVIVING cell that faces a
--     DOOMED one -- the inner edge of the doomed band, the boundary of the zone
--     that survives. Those segments get AMBER lamps (`next` in the config),
--     one at the middle slot and a few infill, for the whole hold. From inside
--     the band the player sees red fire behind him and the amber line ahead;
--     as the window runs, the red line eats the band toward the amber one, and
--     when a doomed cell closes the amber post on its far side is the SAME
--     slot key as the new red post (the key is the surviving cell's side), so
--     the diff rebuilds it in place as fire and lamp. That, plus the surge
--     flare, is what "the wall arrives" looks like. The HUD's new ZONE CLOSING
--     IN / NEXT ZONE strip (open77_cordon_hud) is the same fact on screen.
--   * THE MATERIAL. Hesco, roadblock and container are `enabled = false` in
--     the shipped config -- one boolean each to bring back, nothing removed
--     from this file. The line is now `fire.small` on the even slots of the
--     nearest eighty metres and a red LAMP at knee height on the odd ones, so
--     the tarmac between two fires glows; the fill beyond is lamps at a wider
--     pitch; the markers keep their proven red pool, their fire and their
--     unverified plume. The strip lies ACROSS the line so its arrows, if they
--     draw, point the way in. Every one of these is a primitive with in-game
--     proof (fire.small: captured frame, nineteen accepted handles on the
--     owner's client; lights: two clients) or one whose failure costs only
--     itself (strip, blaze).
--   * THE CLOCK YOU FEEL. The chase beat shortens from `chase.stepMs` to
--     `chase.hurryStepMs` over the last `chase.hurrySeconds` before the next
--     closure -- read off the fragment's `closeInMs` and extrapolated locally
--     -- and stays there for the whole window. A player who never reads the
--     HUD still sees the line flicker faster as the phase ends.
--
-- WHAT THIS DOES NOT CHANGE: the budget discipline (every new thing is a
-- bounded queue or a config cap, and the arithmetic is at `maxTotalPosts` and
-- `maxEffects` in the config), the hollow rule (nothing on by default has a
-- collider at all), and the projected wall (still `style = "hud"` only).
--
-- BUDGET, stated: props planned 104 (16 marker pools + 20 line lamps + 20
-- strips + 24 fill lamps + 24 next lamps) against 256; effects planned 52
-- (16 burns + 20 line fires + 16 blazes) against a 58 gate and a 64 cap, with
-- the blaze reserving 8 so a closure always has room for its blasts. The
-- number that is new and UNMEASURED is real-time lights: 84 planned against
-- the 33 the owner's client ran on 2026-09-04. `lamps=` and `nexts=` are on
-- the status line for exactly that reason.
-- ===========================================================================

local RESOURCE = GetCurrentResourceName()

-- What the server last told us. `grid` and `openList` come from `cordon:bounds`,
-- which is republished on every block closure; `ground` from `cordon:survey`,
-- which is sent once per player because none of it changes while a map is live.
local grid = nil            -- { ox, oy, oz, size, cols, rows }
local openList = nil        -- the raw array of "col,row" keys, AS SENT
local openCells = -1        -- how many are in `openList`, for the cheap change test
local revision = 0          -- bumped on every bounds, so a rebuild is forced
local ground = { default = nil, cells = nil }

-- THE DOOMED SET, as sent: the cells the announced phase is going to take
-- (`closing` on `cordon:bounds`, the same list the tac-map flashes amber). It
-- is what the second line is drawn from -- see the eighth-round note. Kept
-- alongside `openList` and indexed in the same chunked pass; a bounds message
-- that carries no `closing` at all (an older server) leaves it empty and the
-- scan simply produces no next-line segments.
local closingList = nil
local closingCount = 0

-- The open set as INTEGERS, `[col * INDEX_STRIDE + row] = true`, and the
-- revision it was built from. This is the only form the scan ever reads: see
-- rule 1 above. It is built in chunks by `indexStep`, never all at once.
-- `closingIndex` is the doomed set in the same form, built by the same pass.
local INDEX_STRIDE = 4096
local openIndex = nil
local closingIndex = nil
local openIndexRevision = -1
local openIndexProgress = 0
local openIndexBuilding = nil
local closingIndexBuilding = nil

-- WHEN THE NEXT CELL CLOSES, in monotonic seconds, from the fragment's
-- `closeInMs` -- or nil when the cordon has no timetable left. It drives the
-- chase's hurry (see `chaseStep`): during a hold it counts down to the window,
-- and during the window it is always a second or two away, which is exactly
-- the state the fastest beat is for.
local closeAtMono = nil

-- Whether the mode wants the world layer at all. The SERVER's answer wins when
-- it has sent one, because `cordonEdge` is a live tunable and an operator
-- switching it off mid-match must reach clients that loaded a config saying
-- otherwise. Absent, the shipped config decides.
local serverStyle = nil

-- Whether the cordon is live and this player is in the match. Fed by
-- `cordon:state:local`, which client/main.lua re-broadcasts.
local participating = false

-- The posts we are currently holding, `[key] = { x, y, z, nx, ny, marker, wall,
-- slot, rev, <one handle per layer> }`. `key` is the INTEGER `slotKey` below,
-- derived entirely from the cordon geometry -- so the same post asked for twice
-- in a row is RECOGNISED and left alone rather than destroyed and recreated.
-- That matters: recreating a particle effect every second restarts its graph,
-- and the edge would strobe.
--
-- It used to be the string `"<col>,<row>:<side>:<index>"`. The plan is now up
-- to eighty posts, and eighty `string.format` calls inside the one resume that
-- also holds the plan tables is the shape of thing rule 1 at the top of this
-- file forbids. An integer key costs three multiplies and allocates nothing.
local posts = {}
local postCount = 0

--- The key of one slot of one side of one cell. Slots are capped at 255 per
--- segment by `scanFinish`, so the packing is exact and never collides.
local function slotKey(col, row, rank, slot)
    return ((col * 4096 + row) * 4 + rank) * 256 + slot
end

-- What the last scan decided SHOULD be standing, and the work still owed
-- against it. `plan` is pure data; `pendingRaise` / `pendingRetire` are the
-- queues the bounded apply step drains a post at a time.
local plan = nil
local pendingRaise = nil
local pendingRetire = nil
local planX, planY, planZ = nil, nil, nil
local planRevision = -1

-- THE SCAN IN PROGRESS, and it is in progress across several passes on purpose.
--
-- The first rewrite bounded the scan's cost by SHRINKING THE WINDOW
-- (`maxCellRadius = 2`), which was a mistake of the same family as the bug it
-- was fixing: it traded a cost problem for a reach problem and said nothing.
-- The window is now the full `drawRadiusMetres` again and is walked a bounded
-- number of CELLS PER PASS instead -- the same discipline `indexStep` and
-- `applyStep` already keep. A bigger window therefore costs more PASSES, never
-- more time inside one, which is the only quantity the execution-budget hook
-- measures.
local scanState = nil

local raisedEver = false

-- ---------------------------------------------------------------------------
-- WHAT MOVES -- the state behind the seventh round.
--
-- `effectCount` is every looping VFX handle this file holds, kept in step by
-- `raise` and `retire`; `blasts` are the one-shots, each with the monotonic
-- second it expires at, pruned lazily. `effectsLive()` is their sum and is
-- what the decorative layers are gated on. It is a COUNT KEPT BY THIS FILE,
-- not a query: `Open77.vfx.list()` allocates a table per effect and belongs on
-- the status pass, not in the raise path.
--
-- The lamp animator is the fourth bounded queue in this file. `lampQueue` is
-- the list of post keys owed an update; `lampStep` drains it a few per pass.
-- `chasePhase` flips on every beat; `surgeUntil` is the monotonic second the
-- current closure flare ends at, or nil. `surgeArmed` is set by the net-event
-- handler that learns of a closure -- which has no clock -- and consumed on
-- the poll thread, which does.
-- ---------------------------------------------------------------------------
local effectCount = 0
local blasts = {}
local blastCount = 0

local lampQueue = nil
local lampWakeAt = nil          -- monotonic seconds; the poll wakes for it
local lampSkip = false          -- round-robin with the boundary work
local chasePhase = 0
local chaseNextAt = 0.0
local surgeUntil = nil
local surgeArmed = false
local surgeLive = false

-- ---------------------------------------------------------------------------
-- THE PROJECTED WALL -- what is published to open77_cordon_hud.
--
-- `wallCandidates` is a REFERENCE to the sorted candidate list the last scan
-- produced, never a copy. The scan's own array becomes garbage the moment the
-- next scan opens, and copying it would be an allocation inside the one resume
-- this file cannot afford one in. `wallStep` reads it on a LATER pass, which is
-- safe for exactly the reason the scan is chunked: only `scanBegin` replaces
-- it, and `scanBegin` runs at the end of a pass, after `wallStep` has had its.
--
-- `wallPayload` is cached and RE-SENT unchanged on a heartbeat rather than
-- rebuilt. The consumer has to be able to tell "the boundary has not moved"
-- from "the gamemode stopped talking" -- a HUD that trusted a single publish
-- would keep painting the boundary of a resource that had been stopped for ten
-- minutes, which is the frozen-overlay failure this whole rewrite exists to
-- avoid -- and a periodic re-send is the cheapest possible liveness proof: no
-- Lua allocation at all, just the encoder walking a table that already exists.
-- ---------------------------------------------------------------------------
local wallCandidates = nil
local wallCandidateCount = 0
local wallScanZ = nil
local wallDirty = false
local wallPayload = nil
local wallPanels = 0
local wallActive = false
local wallRepublishAt = 0.0

-- Re-send this often even when nothing changed. The HUD's own staleness window
-- is several times longer, so an ordinary dropped pass cannot blank the
-- boundary; only a resource that has genuinely stopped can.
local WALL_REPUBLISH_SECONDS = 2.0

-- Diagnostics. `reportAt` is a monotonic deadline in SECONDS
-- (`Open77.time.monotonic` returns a double of seconds, not milliseconds).
local reportAt = 0.0
local lastSegments = 0
local lastNextSegments = 0
local lastWindow = "0x0"
local lastRadius = 0.0
local lastBeatMs = 0

-- Every refusal is named ONCE. A boundary that cannot draw is a real failure
-- and has to be visible in the log, but a 1 Hz rebuild against a missing alias
-- would write it sixty times a minute for the length of a match.
local warned = {}

-- Returned by `wallCfg` when the config carries no wall block. A shared empty
-- table rather than a fresh one per call: `wallCfg` runs on every pass.
local EMPTY = {}

local function say(level, message)
    local log = Open77 ~= nil and Open77.log or nil
    if log ~= nil and type(log[level]) == "function" then
        log[level]("[cordon] edge: " .. message)
    else
        print("[cordon] edge: " .. message)
    end
end

local function warnOnce(key, message)
    if warned[key] then return end
    warned[key] = true
    say("warn", message)
end

local function cfg()
    local cordon = (Config and Config.cordon) or {}
    return cordon.edge or {}
end

local function number(value, fallback)
    local n = tonumber(value)
    if n == nil or n ~= n then return fallback end
    return n
end

--- "off" | "hud" | "world". Only "world" draws anything in the world.
local function style()
    if serverStyle ~= nil then return serverStyle end
    local settings = cfg()
    if type(settings.style) == "string" then return settings.style end
    local cordon = (Config and Config.cordon) or {}
    if type(cordon.edgeStyle) == "string" then return cordon.edgeStyle end
    return "hud"
end

local function vfxAvailable()
    return type(Open77.vfx) == "table" and type(Open77.vfx.play) == "function"
end

local function propsAvailable()
    return type(Open77.props) == "table" and type(Open77.props.create) == "function"
end

--- Whether either half of a post can be built at all. Tested before a rebuild
--- rather than inside it: without this, a client whose runtime predates these
--- bindings -- or a deployment that stripped `world.props` / `world.effects`
--- from the manifest -- would attempt sixteen refused calls a second for the
--- length of a match, quietly, because `warnOnce` would have said its piece
--- after the first one.
local function canDraw()
    -- Whole-cell markers disagree with continuous partial-cell damage. If the
    -- engine FX renderer cannot run, retain HUD guidance, not stale markers.
    if CordonSweepEdge and CordonSweepEdge.authoritative then return false end
    local settings = cfg()
    local column = settings.column or {}
    local light = settings.light or {}
    local barrier = settings.barrier or {}
    local rampart = settings.rampart or {}
    local bastion = settings.bastion or {}
    local strip = settings.strip or {}
    local beacon = settings.beacon or {}
    local burn = settings.burn or {}
    local blaze = settings.blaze or {}
    local flame = settings.flame or {}
    local nextLine = settings.next or {}
    -- The prop layers first: the light host and the meshes both have in-game
    -- proof behind them (`wiki/props.md`, 2026-08-28, two clients), so their
    -- absence really means "this client cannot draw a boundary".
    if propsAvailable() then
        if barrier.enabled ~= false or rampart.enabled ~= false or
            bastion.enabled ~= false or strip.enabled ~= false or
            beacon.enabled ~= false or light.enabled ~= false or
            nextLine.enabled ~= false then
            return true
        end
    end
    -- Then the fires. `fire.small` is the only VFX alias in this tree with a
    -- captured frame behind it (research section 31.1, E0.5); the blaze is the
    -- same family, unverified; the flame is the same alias as the burn, on the
    -- wall.
    if vfxAvailable() and (burn.enabled ~= false or blaze.enabled ~= false or
        flame.enabled ~= false) then
        return true
    end
    -- `== true`, NOT `~= false`. The column is opt-in in code AND off in the
    -- shipped config since 2026-09-03 -- see the note at the `column` block --
    -- so this branch is dead until somebody proves the alias renders.
    if column.enabled == true and vfxAvailable() then return true end
    return false
end

--- The projected wall's own settings. `Config.cordon.edge` ships no `wall`
--- block today, so every value below is the default in `wallStep`; the table is
--- read rather than hard-coded so that adding one is a config edit and not a
--- code edit.
local function wallCfg()
    local settings = cfg()
    local wall = settings.wall
    if type(wall) ~= "table" then return EMPTY end
    return wall
end

--- Whether the projected wall is drawn. THREE STATES, and the third one is the
--- setting.
---
--- `enabled = true` and `enabled = false` are explicit and win. ABSENT -- which
--- is what `Config.cordon.edge.wall` ships, deliberately, with the key written
--- out and commented -- means AUTOMATIC: the wall is the boundary under
--- `cordonEdge = "hud"`, where there is no world layer at all, and it is off
--- under "world", where the barriers, the lights and the columns are.
---
--- The old rule was "on unless somebody turns it off", and it is what put the
--- owner's screenshot on screen: under "world", which is what the mode ships,
--- BOTH boundaries drew, and the one with no occlusion and no ground contact is
--- the one he saw. Each style now means exactly what its config comment claims
--- and nothing draws twice.
local function wallEnabled()
    local wall = wallCfg()
    if wall.enabled ~= nil then return wall.enabled == true end
    return style() == "hud"
end

-- ---------------------------------------------------------------------------
-- GEOMETRY
--
-- The four sides of a block, as the offset to the neighbour that decides
-- whether the side is a boundary, plus the outward normal. `dx`/`dy` and the
-- normal are the same pair -- the neighbour is always in the outward direction
-- -- but they are written twice because one is a GRID step and the other is a
-- METRE step, and conflating them is how an outset ends up 100 m long.
--
-- `rank` is the tie-break, and it is a NUMBER rather than a string comparison
-- for the reason rule 1 gives: see `scanStep`.
--
-- `yaw` is the heading, IN DEGREES, that lays a prop's local +Y along this
-- side's line. It is `deg(atan2(ny, nx))` and is written out rather than
-- computed because it depends only on the normal, which is a constant per side,
-- and the scan may not spend an `atan2` per post. `Open77.props` takes a yaw in
-- degrees and exposes no pitch or roll (`wiki/props.md`), which is all a
-- barricade standing on flat ground needs.
--
-- The +Y convention is an ASSUMPTION about the engine's yaw basis, and it is the
-- reason `barrier.lengthAxis` exists: a 90 degree error is the only one that
-- matters for a symmetric block, and that setting corrects it. A 180 degree
-- error turns a symmetric block end for end and is invisible.
-- ---------------------------------------------------------------------------
local SIDES = {
    { key = "w", dcol = -1, drow =  0, nx = -1.0, ny =  0.0, rank = 0, yaw = 180.0 },
    { key = "e", dcol =  1, drow =  0, nx =  1.0, ny =  0.0, rank = 1, yaw =   0.0 },
    { key = "s", dcol =  0, drow = -1, nx =  0.0, ny = -1.0, rank = 2, yaw = -90.0 },
    { key = "n", dcol =  0, drow =  1, nx =  0.0, ny =  1.0, rank = 3, yaw =  90.0 },
}

--- The two endpoints of one side of block (col,row), in world metres.
local function sideEndpoints(col, row, side)
    local x0 = grid.ox + (col - 1) * grid.size
    local y0 = grid.oy + (row - 1) * grid.size
    local x1 = x0 + grid.size
    local y1 = y0 + grid.size
    if side.key == "w" then return x0, y0, x0, y1 end
    if side.key == "e" then return x1, y0, x1, y1 end
    if side.key == "s" then return x0, y0, x1, y0 end
    return x0, y1, x1, y1
end

--- Squared distance from (px,py) to the segment (ax,ay)-(bx,by). Squared, so
--- the ranking below costs no square roots: it is monotonic in the real
--- distance and that is all a sort needs.
local function segmentDistanceSquared(px, py, ax, ay, bx, by)
    local vx, vy = bx - ax, by - ay
    local wx, wy = px - ax, py - ay
    local lengthSquared = vx * vx + vy * vy
    local t = 0.0
    if lengthSquared > 1e-6 then
        t = (wx * vx + wy * vy) / lengthSquared
        if t < 0.0 then t = 0.0 elseif t > 1.0 then t = 1.0 end
    end
    local dx = px - (ax + t * vx)
    local dy = py - (ay + t * vy)
    return dx * dx + dy * dy
end

--- The ground height for a post standing on the boundary of block (col,row).
---
--- The OPEN cell's height is used rather than the closed neighbour's, and that
--- is deliberate: the open side is where the survey walked, so it is the side
--- whose height is attested. Falls back through the map's default ground, the
--- grid origin's z, and finally the player's own feet -- which is only ever
--- reached before the survey arrives, and is right to within a storey because
--- nothing is drawn further than `drawRadiusMetres` away.
---
--- This is the ONE place the scan still formats a cell key, and it is called
--- once per SEGMENT rather than once per cell -- at most `maxSegments` times,
--- against the 320 calls the old window walk made.
local function groundFor(col, row, fallbackZ)
    if ground.cells ~= nil then
        local override = ground.cells[Grid.key(col, row)]
        local z = number(override, nil)
        if z ~= nil then return z end
    end
    local z = number(ground.default, nil)
    if z ~= nil then return z end
    z = number(grid and grid.oz, nil)
    if z ~= nil then return z end
    return fallbackZ or 0.0
end

-- ---------------------------------------------------------------------------
-- THE INDEX
--
-- `cordon:bounds` carries the open set as an array of "col,row" STRINGS,
-- because that is the form that survives JSON, a net event, a chat line and a
-- log file unchanged (shared/grid.lua says so at `Grid.key`). The scan needs it
-- as integers, and converting on every scan is exactly the cost that killed the
-- first version -- so it is converted ONCE PER REVISION, and even that is
-- chunked: a 24x24 map at lattice factor 2 is 2304 cells, and 2304 `Grid.parse`
-- calls in one 80 us resume would trip the same hook the scan used to.
-- ---------------------------------------------------------------------------
local function indexStep(chunk)
    if openList == nil then return false end
    if openIndexBuilding == nil then
        openIndexBuilding = {}
        closingIndexBuilding = {}
        openIndexProgress = 0
    end
    -- ONE PROGRESS COUNTER OVER BOTH LISTS, open first and then doomed, so
    -- the chunking discipline is unchanged: a pass converts at most `chunk`
    -- keys whichever list they come from.
    local total = #openList + closingCount
    local last = math.min(total, openIndexProgress + chunk)
    for i = openIndexProgress + 1, last do
        local key, target
        if i <= #openList then
            key, target = openList[i], openIndexBuilding
        else
            key, target = closingList[i - #openList], closingIndexBuilding
        end
        if type(key) == "string" then
            local col, row = Grid.parse(key)
            if col ~= nil and row ~= nil then
                target[col * INDEX_STRIDE + row] = true
            end
        end
    end
    openIndexProgress = last
    if last < total then return true end     -- more chunks owed
    openIndex = openIndexBuilding
    closingIndex = closingIndexBuilding
    openIndexBuilding = nil
    closingIndexBuilding = nil
    openIndexRevision = revision
    -- A fresh index invalidates the plan: the boundary it described belongs to
    -- a cordon that has since closed a block. It also invalidates a scan that is
    -- half way through the window -- it was reading the PREVIOUS `openIndex`,
    -- and finishing it would describe a boundary that is part old cordon and
    -- part new, which is the same "impossible to read from a screenshot" defect
    -- `adoptOpen` throws a half-built index away to avoid.
    planRevision = -1
    scanState = nil
    return false
end

-- ---------------------------------------------------------------------------
-- WHAT THE EDGE SHOULD BE
-- ---------------------------------------------------------------------------

--- Open a scan of the window around (px,py). Sets `scanState`; the walk itself
--- is `scanStep`, and the answer is built by `scanFinish`.
---
--- WHY THE RADIUS IS NO LONGER CLAMPED TO TWO CELLS, which is the whole bug
--- this revision exists for.
---
--- The previous version computed
---
---     radius = min(drawRadiusMetres, maxCellRadius * grid.size)   -- 2 cells
---
--- and `grid.size` is the LATTICE pitch, not the block size: `cordon.lua`
--- publishes `blockMetres = lattice.blockMetres`, which `Grid.subdivide` sets to
--- `blockSize / factor`. On Watson that is 100 / 4 = 25 m, so the configured
--- 150 m boundary was silently drawn at **50 m** -- less than one surveyed
--- block, and shorter than the distance at which the mode's own HUD reports
--- "NEAREST OPEN BLOCK 113 m". A player standing outside the cordon, which is
--- exactly when the boundary is the one thing worth drawing, was always further
--- from every open cell than the window could reach, so `scan` returned an empty
--- plan and the layer TORE ITSELF DOWN. It reported `first post up` and was then
--- correct, empty and invisible for the rest of the match.
---
--- `maxCellRadius` was written as a COST bound and became a REACH bound. Cost is
--- now bounded where it belongs -- in how many cells one PASS may walk
--- (`scanCellsPerPass`) -- and reach is bounded only by metres. The window is
--- still capped in cells (`maxScanCells`) so that a hypothetical very fine
--- lattice cannot ask for an unbounded number of passes, but on every map
--- shipped today the metre radius is what decides.
local function scanBegin(px, py, pz)
    local settings = cfg()
    local metres = number(settings.drawRadiusMetres, 150.0)
    -- A window of radius r cells is (2r+1)^2 cells, so a cell ceiling of N
    -- allows r = floor((sqrt(N)-1)/2). 729 gives r = 13, i.e. 325 m at Watson's
    -- 25 m pitch -- comfortably more than the 150 m the config asks for, which
    -- is the point: the metre radius decides and the cell ceiling only catches
    -- a pathological pitch.
    local ceiling = math.max(9, math.floor(number(settings.maxScanCells, 729)))
    local cellRadius = math.max(1, math.floor((math.sqrt(ceiling) - 1) * 0.5))
    local radius = math.min(metres, cellRadius * grid.size)

    -- Collect the boundary segments inside the draw radius. A segment exists
    -- where an OPEN cell meets something that is not open -- a closed cell, an
    -- EXCLUDED one (water, a highway, a blind roof: never open, so the bleed is
    -- real there and the line belongs there) or the rim of the grid. Each
    -- physical line is therefore produced exactly once, by its open side, and
    -- there is nothing to de-duplicate.
    --
    -- A cell that intersects the draw disc must intersect the disc's bounding
    -- box, so the window is a superset of the answer and nothing is missed.
    scanState = {
        px = px, py = py, pz = pz,
        radius = radius,
        radiusSquared = radius * radius,
        loCol = math.max(1, math.floor((px - radius - grid.ox) / grid.size) + 1),
        hiCol = math.min(grid.cols, math.floor((px + radius - grid.ox) / grid.size) + 1),
        loRow = math.max(1, math.floor((py - radius - grid.oy) / grid.size) + 1),
        hiRow = math.min(grid.rows, math.floor((py + radius - grid.oy) / grid.size) + 1),
        candidates = {},
        count = 0,
        -- A hard ceiling on the candidate list, so that a lattice riddled with
        -- excluded cells -- which produces interior boundary everywhere, not
        -- just a perimeter -- cannot hand `table.sort` a list whose length is
        -- proportional to the window. The list is filled west to east, so an
        -- overflowing scan is spatially biased rather than wrong; it is a
        -- degenerate case that no shipped map reaches. 256 since the eighth
        -- round: the next line is a second ring of segments inside the first,
        -- so a window that used to hold one boundary now holds two.
        capacity = math.max(16, math.floor(number(settings.maxCandidates, 256))),
    }
    scanState.col = scanState.loCol
    scanState.width = scanState.hiRow - scanState.loRow + 1
    lastRadius = radius
    lastWindow = ("%dx%d"):format(
        math.max(0, scanState.hiCol - scanState.loCol + 1),
        math.max(0, scanState.width))
end

--- Walk at most `budget` CELLS of the window, a whole column at a time. Returns
--- true while the window still owes cells.
---
--- A column is the atom because it is bounded: `hiRow - loRow + 1` can never
--- exceed `sqrt(maxScanCells)`, so even a pass that overshoots `budget` on its
--- first column does a fixed, small amount of work. Everything in here is
--- integer arithmetic and integer table lookups -- no `string.format`, no
--- allocation except one small table per boundary segment actually found --
--- which is what makes a 13x13 window cheaper today than the 8x8 one that blew
--- the budget on 2026-09-02.
local function scanStep(budget)
    local s = scanState
    if s == nil then return false end
    if s.width < 1 then s.col = s.hiCol + 1 return false end
    local walked = 0
    while s.col <= s.hiCol and walked < budget do
        local col = s.col
        local base = col * INDEX_STRIDE
        for row = s.loRow, s.hiRow do
            local here = base + row
            if openIndex[here] == true then
                -- Whether THIS cell is doomed decides which line its sides can
                -- belong to: a doomed cell's sides are only ever the current
                -- line (its outward faces), never the next one.
                local doomedHere = closingIndex ~= nil and closingIndex[here] == true
                for index = 1, 4 do
                    local side = SIDES[index]
                    -- No bounds test on the neighbour: a cell off the grid is
                    -- simply absent from the index, which is the same answer as
                    -- "closed", and is the answer the rim of the district
                    -- should give.
                    local there = (col + side.dcol) * INDEX_STRIDE + (row + side.drow)
                    -- TWO LINES FROM ONE WALK. `ahead` is nil for a side that
                    -- is no boundary at all, false for the CURRENT line (an
                    -- open cell against a closed one, an excluded one or the
                    -- rim) and true for the NEXT line (a surviving cell against
                    -- a doomed one). The two never overlap: a neighbour is
                    -- either not open or open, and a doomed cell never
                    -- produces a next-line side of its own.
                    local ahead = nil
                    if openIndex[there] ~= true then
                        ahead = false
                    elseif not doomedHere and closingIndex ~= nil and closingIndex[there] == true then
                        ahead = true
                    end
                    if ahead ~= nil then
                        local ax, ay, bx, by = sideEndpoints(col, row, side)
                        local distance = segmentDistanceSquared(s.px, s.py, ax, ay, bx, by)
                        if distance <= s.radiusSquared and s.count < s.capacity then
                            local count = s.count + 1
                            s.count = count
                            s.candidates[count] = {
                                col = col, row = row, side = side,
                                ax = ax, ay = ay, bx = bx, by = by,
                                next = ahead,
                                -- NEAREST FIRST, and the epsilon is not
                                -- decoration. Two segments exactly equidistant
                                -- is the common case, not the rare one -- stand
                                -- at the centre of a block and all four of its
                                -- sides are the same distance away -- and
                                -- `table.sort` is not stable, so without a total
                                -- order the surviving set would be whichever
                                -- ones the sort happened to keep, and the edge
                                -- would flicker between two equally correct
                                -- answers while the player stood still. Folding
                                -- the tie-break INTO the number keeps the
                                -- comparator a single numeric compare; the
                                -- epsilon tops out around 1e-3 m^2, far below
                                -- any distance two distinct segments can differ by.
                                d = distance +
                                    (col * 4096 + row * 4 + side.rank) * 1e-9,
                            }
                        end
                    end
                end
            end
        end
        s.col = col + 1
        walked = walked + s.width
    end
    return s.col <= s.hiCol
end

--- Sort the candidates nearest-first and hand the sorted list to the projected
--- wall. ITS OWN PASS. The sort is up to 192 comparisons times log(192) with a
--- Lua comparator, and the plan build that follows is now up to eighty table
--- constructors; the two together are the largest single allocation this file
--- makes, and the execution-budget hook at the top of this file measures wall
--- clock per resume. Splitting them costs one 100 ms poll and buys a pass that
--- cannot be the one that trips it.
local function scanSort()
    local s = scanState
    if s == nil or s.sorted then return end
    lastSegments = s.count
    -- How many of them are the next line, for the status line. A walk of at
    -- most `capacity` booleans, on the pass that already owns the sort.
    local ahead = 0
    for index = 1, s.count do
        if s.candidates[index].next then ahead = ahead + 1 end
    end
    lastNextSegments = ahead
    if s.count == 0 then
        -- AN EMPTY SCAN IS AN ANSWER, NOT A FAILURE, and the wall has to hear
        -- it: it means the boundary is further away than the draw radius, which
        -- is the ordinary state of a player in the middle of the open blocks.
        -- Saying nothing would leave the last wall painted for the rest of the
        -- match.
        wallCandidates, wallCandidateCount, wallDirty = nil, 0, true
    else
        table.sort(s.candidates, function(a, b) return a.d < b.d end)
        -- THE WALL TAKES THE SAME SORTED LIST AND NOTHING ELSE FROM THE SCAN.
        -- Recorded before the post plan is built, and recorded whether or not
        -- one is: under `cordonEdge = "hud"` there are no posts and the scan
        -- exists purely to feed the wall.
        wallCandidates = s.candidates
        wallCandidateCount = s.count
        wallScanZ = s.pz
        wallDirty = true
    end
    s.sorted = true
end

--- One planned post. `slot` is the 1-based slot index along the segment;
--- `marker` and `wall` are the tier flags `raise` reads to decide which layers
--- the post carries.
local function spotFor(segment, slot, outset, marker, wall, ahead)
    local t = (slot - 0.5) / segment.slots
    return {
        x = segment.ax + (segment.bx - segment.ax) * t + segment.side.nx * outset,
        y = segment.ay + (segment.by - segment.ay) * t + segment.side.ny * outset,
        z = segment.z,
        nx = segment.side.nx,
        ny = segment.side.ny,
        yaw = segment.side.yaw,
        slot = slot,
        marker = marker,
        wall = wall,
        -- THE NEXT LINE: a post on the boundary of the zone that survives the
        -- announced phase. Carries an amber lamp and nothing else.
        next = ahead == true,
    }
end

--- Close the scan and turn its SORTED candidate list into the plan: every post
--- that should exist right now, as `[key] = spot`. Runs after `scanSort`, on a
--- pass of its own.
local function scanFinish(wantPosts, s)
    -- Count work across pass/segment boundaries too: several short segments
    -- must not bypass the yield just because none has eight slots of its own.
    local work = 0
    local function checkpoint()
        work = work + 1
        if work >= 8 then
            work = 0
            coroutine.yield()
        end
    end
    if s == nil or s.count == 0 or not wantPosts then return {} end

    local settings = cfg()
    local maxSegments = math.max(0, math.floor(number(settings.maxSegments, 16)))
    local maxPosts = math.max(0, math.floor(number(settings.maxPosts, 80)))
    local wallPosts = math.max(0, math.floor(number(settings.wallPosts, 40)))
    local stride = math.max(1, math.floor(number(settings.fillStride, 2)))
    local spacing = math.max(0.5, number(settings.spacingMetres, 2.0))
    local outset = number(settings.outsetMetres, 1.5)
    local groundOffset = number(settings.groundOffsetMetres, 0.0)
    local ahead = settings.next or EMPTY
    local nextSegments = ahead.enabled == false and 0
        or math.max(0, math.floor(number(ahead.segments, 16)))
    local nextPosts = math.max(0, math.floor(number(ahead.maxPosts, 24)))
    local nextEvery = math.max(1, math.floor(number(ahead.everySlots, 6)))

    local wanted, wantedCount = {}, 0
    -- Tested up front rather than at the top of each pass. The passes below
    -- check the budget AFTER placing, which is what lets pass 1 guarantee a
    -- marker for the nearest segment however tight the cap is -- but it also
    -- means a cap of zero would place one post. `maxPosts = 0` is a real
    -- setting: it is how an operator keeps the scan (and therefore the projected
    -- wall) while spawning nothing -- including the next line.
    if maxPosts < 1 then return {} end

    -- SPLIT THE SORTED LIST INTO THE TWO LINES, nearest first, each capped.
    -- Two small arrays (at most `maxSegments` + `next.segments` references,
    -- no copies) on the pass that already allocates the plan.
    local current, currentCount = {}, 0
    local coming, comingCount = {}, 0
    for index = 1, s.count do
        checkpoint()
        local segment = s.candidates[index]
        if segment.next then
            if comingCount < nextSegments then
                comingCount = comingCount + 1
                coming[comingCount] = segment
            end
        elseif currentCount < maxSegments then
            currentCount = currentCount + 1
            current[currentCount] = segment
        end
        if currentCount >= maxSegments and comingCount >= nextSegments then break end
    end

    -- Each segment's slot lattice is computed here, ONCE, and stashed on the
    -- candidate so the later passes do not recompute it. The candidate array is
    -- thrown away when the next scan opens, so this is not state that can go
    -- stale.
    --
    -- SLOTS ARE A PROPERTY OF THE SEGMENT, NOT OF THE PLAYER. `spacing` is
    -- a constant, so the number of slots and the position of each one depend
    -- only on the geometry -- which is what lets the later passes add slots
    -- around a standing post instead of moving it. Slot centres are at the
    -- interior midpoints, never at the ends, so two segments meeting at a
    -- block corner do not stack two posts on one spot. Capped at 255 so
    -- `slotKey` packs exactly; a 100 m Pacifica block at 2 m is fifty.
    local function prepare(segment)
        local length = math.sqrt(
            (segment.bx - segment.ax) ^ 2 + (segment.by - segment.ay) ^ 2)
        local slots = math.min(255, math.max(1, math.floor((length / spacing) + 0.5)))
        segment.slots = slots
        segment.z = groundFor(segment.col, segment.row, s.pz) + groundOffset
        -- The middle slot, or the lower of the two middles on an even count.
        segment.marker = math.floor((slots + 1) / 2)
    end

    -- PASS 1 -- THE MARKERS, one per segment, BEFORE anything else.
    --
    -- The skeleton is what makes a DISTANT boundary read as a line: at a hundred
    -- metres, perspective foreshortening closes a lattice-pitch gap on its own,
    -- so one post per segment over sixteen segments is four hundred metres of
    -- legible boundary for sixteen entities. It goes first so that however the
    -- budget below is spent, no segment in range is ever empty -- which from
    -- any distance is a fragment floating in space, the world-space form of the
    -- owner's "cut from one angle to another".
    local segments = currentCount
    for index = 1, segments do
        checkpoint()
        local segment = current[index]
        prepare(segment)
        wantedCount = wantedCount + 1
        wanted[slotKey(segment.col, segment.row, segment.side.rank, segment.marker)] =
            spotFor(segment, segment.marker, outset, true, false)
        if wantedCount >= maxPosts then return wanted end
    end

    -- PASS 2 -- THE RAMPART: the nearest `wallPosts` slots, every one of them,
    -- nearest segment first, WHATEVER THEIR DISTANCE.
    --
    -- This replaces `denseRadiusMetres`, and the sixth-round note at the top of
    -- this file records why: the owner's whole match ran with the nearest post
    -- at 54 m against a dense radius of 45, so the curtain never once existed
    -- and he saw the marker tier alone. A player can only look at one arc of
    -- the boundary at a time, and the arc in front of him is the nearest one;
    -- spending the budget there by RANK instead of by radius means the wall is
    -- always the thing he is looking at, whether he stands at five metres or at
    -- a hundred.
    --
    -- A marker slot already planned inside this tier is PROMOTED to a wall
    -- slot rather than duplicated: same key, `wall = true`, and the diff in
    -- `stepOnce` rebuilds a standing post whose tier changed.
    local rampart = 0
    for index = 1, segments do
        if rampart >= wallPosts or wantedCount >= maxPosts then break end
        local segment = current[index]
        for slot = 1, segment.slots do
            checkpoint()
            local key = slotKey(segment.col, segment.row, segment.side.rank, slot)
            local spot = wanted[key]
            if spot ~= nil then
                spot.wall = true
            else
                wantedCount = wantedCount + 1
                wanted[key] = spotFor(segment, slot, outset, false, true)
            end
            rampart = rampart + 1
            if rampart >= wallPosts or wantedCount >= maxPosts then break end
        end
    end

    -- PASS 3 -- THE FILL: beyond the rampart, every `stride`-th slot, nearest
    -- first, until `maxPosts`. The wall tapers into a dotted kerb line instead
    -- of stopping dead, and the roadblock that carries it is the one prop in
    -- this file with a photograph. The cadence is on the slot INDEX, so it is
    -- geometric: walking toward a filled segment promotes its slots into the
    -- rampart without moving any of them.
    for index = 1, segments do
        if wantedCount >= maxPosts then break end
        local segment = current[index]
        for slot = stride, segment.slots, stride do
            checkpoint()
            local key = slotKey(segment.col, segment.row, segment.side.rank, slot)
            if wanted[key] == nil then
                wantedCount = wantedCount + 1
                wanted[key] = spotFor(segment, slot, outset, false, false)
                if wantedCount >= maxPosts then break end
            end
        end
    end

    -- PASS 4 -- THE NEXT LINE: the boundary of the zone that survives the
    -- announced phase, in amber lamps, counted against `next.maxPosts` rather
    -- than `maxPosts`. A marker at the middle of every next-line segment in
    -- range first, so the whole line reads at a distance, then infill every
    -- `next.everySlots` on the nearest segments until the cap. Same slot
    -- lattice, same keys: when the doomed cell across a next-line side closes,
    -- that side becomes a CURRENT side under the SAME key, and the diff in
    -- `stepOnce` rebuilds the post in place -- which is the arrival.
    local placed = 0
    for index = 1, comingCount do
        checkpoint()
        if placed >= nextPosts then break end
        local segment = coming[index]
        prepare(segment)
        local key = slotKey(segment.col, segment.row, segment.side.rank, segment.marker)
        if wanted[key] == nil then
            placed = placed + 1
            wanted[key] = spotFor(segment, segment.marker, outset, false, false, true)
        end
    end
    for index = 1, comingCount do
        if placed >= nextPosts then break end
        local segment = coming[index]
        for slot = nextEvery, segment.slots, nextEvery do
            checkpoint()
            local key = slotKey(segment.col, segment.row, segment.side.rank, slot)
            if wanted[key] == nil then
                placed = placed + 1
                wanted[key] = spotFor(segment, slot, outset, false, false, true)
                if placed >= nextPosts then break end
            end
        end
    end
    return wanted
end

-- ---------------------------------------------------------------------------
-- PUBLISHING THE WALL
--
-- Its own pass, for the same reason `report` gets one: it formats one cell key
-- per panel (`groundFor` -> `Grid.key`) and builds an array of eighty numbers,
-- and the rule this file was rewritten around is ONE JOB PER PASS.
--
-- THE PAYLOAD IS A FLAT ARRAY OF NUMBERS, FIVE PER PANEL, and that is a node
-- budget rather than a style. `ReadValue` in scripting/src/ResourceHost.cpp
-- counts EVERY node against `kMaximumEventValues` (1024): a table costs one, and
-- each entry costs one for its key plus the cost of its value. Sixteen panels as
-- sixteen tables of five named fields is 16 * (1 + 1 + 10) = 192 nodes; as one
-- flat array it is 1 + 2 * 80 = 161, and the shape stays one table however many
-- panels there are. Overshooting is not truncation -- the whole event is refused
-- and the HUD hears nothing, which is indistinguishable from a stopped mode.
--
--   stride 5, per panel: ax, ay, bx, by, z
--
-- No outward normal, deliberately. The wall is symmetric on screen and which
-- side is closed is already said by the vignette and the compass; a field
-- nothing reads is a field that goes stale.
-- ---------------------------------------------------------------------------
local function wallStep(now)
    if wallDirty then
        wallDirty = false
        local settings = cfg()
        local wall = wallCfg()
        -- Twenty-four is a hard ceiling on top of the config value. Each panel
        -- costs the HUD four native projections per frame, so this number is the
        -- HUD's frame budget expressed here, where the list is cut.
        local maxPanels = math.max(0, math.min(24,
            math.floor(number(wall.maxPanels, 16))))
        local groundOffset = number(settings.groundOffsetMetres, 0.0)
        -- HOW FAR THE PROJECTED WALL REACHES, and it is deliberately much
        -- shorter than the scan radius.
        --
        -- The owner's second complaint -- "a straight line in front of us with a
        -- gap under it" -- is not a z error. A ground line a hundred metres away
        -- projects NEAR THE HORIZON, which on screen is eye height, and the
        -- overlay draws nothing between the player and it, so there is no
        -- perspective cue that it is a line ON THE GROUND. At seventy metres the
        -- base of a panel lands well below the horizon and reads as ground
        -- contact. Cutting the range also cuts the first complaint: the further
        -- a panel is, the more likely a building stands in front of it, and an
        -- overlay cannot know.
        --
        -- The world layer has neither problem, which is why this is a mitigation
        -- for the `cordonEdge = "hud"` fallback and not a fix.
        local range = math.max(1.0, number(wall.rangeMetres, 70.0))
        local rangeSquared = range * range
        local points = {}
        local panels = 0
        if wallCandidates ~= nil then
            for index = 1, wallCandidateCount do
                if panels >= maxPanels then break end
                local segment = wallCandidates[index]
                -- Nearest first, so the first candidate past the range means
                -- every one after it is too. `d` is squared, plus the sort's
                -- tie-break epsilon of at most ~1e-3 m^2.
                if segment == nil or segment.d > rangeSquared then break end
                -- The projected wall is the CURRENT boundary only. A next-line
                -- segment is a warning, not a bleed line, and the overlay has
                -- one colour.
                if not segment.next then
                    local z = groundFor(segment.col, segment.row, wallScanZ) + groundOffset
                    local base = panels * 5
                    points[base + 1] = segment.ax
                    points[base + 2] = segment.ay
                    points[base + 3] = segment.bx
                    points[base + 4] = segment.by
                    points[base + 5] = z
                    panels = panels + 1
                end
            end
        end
        wallPanels = panels
        wallPayload = {
            rev = revision,
            stride = 5,
            panels = panels,
            points = points,
            -- Eighteen metres. Tall enough that a panel forty metres away fills
            -- roughly a quarter of the screen and reads as a barrier rather than
            -- a kerb; short enough that it does not become a lid over the
            -- street. It is a config value so that a map with a freeway deck
            -- can raise it without touching this file.
            height = math.max(1.0, number(wall.heightMetres, 18.0)),
            -- The HUD fades by distance against this, so it must be the range
            -- panels were ACTUALLY cut at -- the smaller of the scan radius and
            -- `rangeMetres`. Publishing the scan radius while cutting at seventy
            -- metres would put every panel inside the fade's near quarter and
            -- draw them all at full strength, which is the opposite of what the
            -- fade is for.
            radius = math.max(1.0, math.min(lastRadius, range)),
            -- #ff5964 is --op77-signal, the design system's coral, and the same
            -- value open77_groundcircle uses for its `danger` style.
            color = type(wall.color) == "string" and wall.color or "#ff5964",
        }
    end

    if wallPayload == nil then return false end
    wallRepublishAt = now + WALL_REPUBLISH_SECONDS
    -- A payload of zero panels is the RETRACTION, and it is sent once: with
    -- nothing to draw there is nothing to prove alive either, so the heartbeat
    -- stops until the next scan finds boundary again.
    wallActive = wallPayload.panels > 0
    TriggerEvent("cordon:edge:wall", wallPayload)
    return true
end

--- Tell the HUD to stop drawing, once. Called when the mode, the operator or a
--- lost participation takes the boundary away. The HUD's staleness window would
--- get there on its own several seconds later, and a boundary that outlives the
--- match it belongs to is the same class of lie as a frozen overlay.
local function retractWall()
    wallCandidates, wallCandidateCount, wallDirty = nil, 0, false
    -- FORCE A FRESH SCAN WHEN THE WALL COMES BACK. `stepOnce` only opens a scan
    -- when the player has moved `refreshMetres` or the cordon revision changed,
    -- so a player who rejoins a match standing still would otherwise have no
    -- boundary until they walked twenty metres. `queueTeardown` already does
    -- exactly this for the post layer and for exactly this reason; before the
    -- wall existed, that call covered both.
    planRevision = -1
    if not wallActive then return false end
    wallActive = false
    wallPanels = 0
    wallPayload = nil
    TriggerEvent("cordon:edge:wall", { rev = revision, stride = 5, panels = 0, points = {} })
    return true
end

-- ---------------------------------------------------------------------------
-- PUTTING IT IN THE WORLD
--
-- Every function below touches the ENGINE, so every one of them is called at
-- most `postsPerTick` times per pass. See rule 3.
-- ---------------------------------------------------------------------------

-- Every handle a post can hold, by the registry it belongs to. `retire` walks
-- these rather than naming each field, so a layer added to `raise` cannot be
-- forgotten here and leak an entity for the rest of the match.
local PROP_LAYERS = { "rampart", "barrier", "bastion", "strip", "beacon", "mast", "light" }
local VFX_LAYERS = { "burn", "blaze", "flame", "vfx" }

--- Drop the one-shots that have burnt out. Called from the two places that
--- read the count, never on a timer: a list of at most a handful of entries,
--- walked backwards so removal is in place.
local function pruneBlasts(now)
    for index = blastCount, 1, -1 do
        if blasts[index].until_ <= now then
            blasts[index] = blasts[blastCount]
            blasts[blastCount] = nil
            blastCount = blastCount - 1
        end
    end
end

--- Every VFX handle this file is holding, loops and one-shots together. This
--- is the number the decorative layers are gated on -- see `maxEffects` in the
--- config for the arithmetic.
local function effectsLive(now)
    if blastCount > 0 and now ~= nil then pruneBlasts(now) end
    return effectCount + blastCount
end

local function effectCeiling()
    return math.max(1, math.floor(number(cfg().maxEffects, 58)))
end

local function monotonic()
    if Open77 ~= nil and type(Open77.time) == "table" and
        type(Open77.time.monotonic) == "function" then
        local ok, value = pcall(Open77.time.monotonic)
        if ok then return number(value, 0.0) end
    end
    return 0.0
end

--- The closure blast: one barrel explosion where a marker of the swallowed
--- line stood, as it is retired. See `surge.blast` in the config for the
--- evidence. It is gated on the effect ceiling like every decorative layer,
--- and on distance to the last scan origin -- which is the player's position
--- to within `refreshMetres` -- because a fireball seventy metres away is a
--- flicker and a handle.
local function blastAt(post)
    local surge = cfg().surge or {}
    local blast = surge.blast or {}
    if surge.enabled == false or blast.enabled == false then return end
    if not vfxAvailable() then return end
    if planX == nil then return end
    local radius = math.max(1.0, number(blast.radiusMetres, 70.0))
    local dx, dy = post.x - planX, post.y - planY
    if dx * dx + dy * dy > radius * radius then return end
    local now = monotonic()
    if effectsLive(now) >= effectCeiling() then return end
    -- A one-shot MUST expire on its own: `0` would hold the handle until the
    -- resource stops, and the config says why that matters.
    local seconds = math.max(0.5, math.min(30.0, number(blast.durationSeconds, 4.0)))
    local effect = type(blast.effect) == "string" and blast.effect or "explosion.frag"
    local handle, reason = Open77.vfx.play(effect, {
        position = { x = post.x, y = post.y, z = post.z },
        duration = seconds,
    })
    if handle == nil then
        warnOnce("blast:" .. tostring(reason),
            ("the closure blast %q was refused (%s). The line still surges and " ..
             "retires; only the fireball is missing."):format(effect, tostring(reason)))
        return
    end
    blastCount = blastCount + 1
    -- A little past the effect's own expiry, so the count never drops below
    -- what the engine still holds.
    blasts[blastCount] = { handle = handle, until_ = now + seconds + 0.5 }
end

local function retire(key)
    local post = posts[key]
    if post == nil then return end
    posts[key] = nil
    postCount = math.max(0, postCount - 1)
    if vfxAvailable() and type(Open77.vfx.stop) == "function" then
        for index = 1, #VFX_LAYERS do
            local handle = post[VFX_LAYERS[index]]
            if handle ~= nil then
                pcall(Open77.vfx.stop, handle)
                effectCount = math.max(0, effectCount - 1)
            end
        end
    end
    if propsAvailable() and type(Open77.props.remove) == "function" then
        for index = 1, #PROP_LAYERS do
            local id = post[PROP_LAYERS[index]]
            if id ~= nil then pcall(Open77.props.remove, id) end
        end
    end
    -- THE BLAST, and the test is the whole point: a marker is retired for one
    -- of two reasons, and only one of them is a closure. `post.rev` is the
    -- cordon revision it was planned for; a post retired while it is still
    -- current is a post the PLAYER walked away from, and walking away from a
    -- wall must not make it explode. A post from an older revision is one the
    -- cordon swallowed. A next-line post never blasts: it is retired to be
    -- rebuilt as the line, and the line arriving is the flare, not a fireball
    -- on the ground that survives.
    if post.marker and not post.next and post.rev ~= revision then blastAt(post) end
end

--- Put ONE mesh prop on the line, laid along it.
---
--- Factored out because the boundary now stands on FOUR of them at four
--- different scales -- the hesco rampart, the roadblock fill, the container
--- bastion and the flat hologram strip -- and the only thing that differs
--- between them is the config block. Duplicating forty lines to change one
--- alias is how they would drift apart, and the axis convention below is
--- exactly the kind of detail that must be got right once rather than four
--- times.
---
--- `block` is a table from `Config.cordon.edge`: `model`, `appearance`,
--- `scale`, `lengthAxis`, `centre`, `outsetMetres`, `groundOffsetMetres`,
--- `yawOffsetDegrees`. `defaults` supplies the alias and the three scale factors
--- when it does not.
---
--- THE YAW BASIS, stated once because everything below leans on it.
--- `TransformOf` in client/src/api/Props.cpp builds the quaternion
--- (0, 0, sin(yaw/2), cos(yaw/2)): a counter-clockwise rotation about world Z
--- by `yaw` degrees, identity at zero. So a prop's local +X points along
--- (cos yaw, sin yaw) and its local +Y along (-sin yaw, cos yaw). `SIDES.yaw`
--- is chosen so that local +Y lies on the boundary and local +X points OUT, to
--- the closed side. This is read from the code, not photographed; the
--- `lengthAxis` and `yawOffsetDegrees` settings exist so that a screenshot can
--- correct it without a code change.
local function raiseBarricade(block, spot, defaults)
    local model = type(block.model) == "string" and block.model or defaults.model
    local size = type(block.scale) == "table" and block.scale or EMPTY
    local along = math.max(0.01, math.min(100.0, number(size.along, defaults.along)))
    local across = math.max(0.01, math.min(100.0, number(size.across, defaults.across)))
    local up = math.max(0.01, math.min(100.0, number(size.up, defaults.up)))
    -- WHICH LOCAL AXIS RUNS ALONG THE LINE. `side.yaw` puts local +Y on the
    -- boundary; a mesh whose length is local +X needs a further 90 degrees and
    -- the two horizontal scales swapped. One setting does both, because doing
    -- one and not the other is the mistake this would otherwise invite. Since
    -- the sixth round this is MEASURED per alias from the mesh bounding box
    -- (see the config block for each layer) rather than guessed.
    local alongX = tostring(block.lengthAxis or defaults.lengthAxis or "y"):lower() == "x"
    local outset = number(block.outsetMetres, defaults.outset or 0.0)
    local yaw = number(spot.yaw, 0.0) + (alongX and 90.0 or 0.0) +
        number(block.yawOffsetDegrees, 0.0)
    -- Per-axis scale in the MESH's own frame, which is what `visualScale` takes.
    local sx = alongX and along or across
    local sy = alongX and across or along

    -- WHERE THE MESH'S FOOTPRINT CENTRE SITS RELATIVE TO ITS ORIGIN, in mesh
    -- metres, read from the bounding box. Most props are centred in plan
    -- (`concrete_roadblock_w100_h110`, `industrial_container_a`), but
    -- `hesco_barrier_a_high_single_a` has its origin on a vertical EDGE
    -- (X -1.54..0.04, Y -0.04..1.54) and `road_barrier_02_a` on one END
    -- (X 0..5.1). Placing those by origin puts the object 0.75 m or 2.5 m off
    -- the slot, and a wall built from them would zig-zag. The offset scales
    -- with the mesh, because `visualScale` scales about the origin, and is
    -- rotated by the prop's final yaw, so the CENTRE lands on the slot whatever
    -- the axis convention turns out to be.
    local centre = type(block.centre) == "table" and block.centre or (defaults.centre or EMPTY)
    local cx = number(centre.x, 0.0) * sx
    local cy = number(centre.y, 0.0) * sy
    local ox, oy = 0.0, 0.0
    if cx ~= 0.0 or cy ~= 0.0 then
        local radians = math.rad(yaw)
        local c, s = math.cos(radians), math.sin(radians)
        ox = cx * c - cy * s
        oy = cx * s + cy * c
    end

    local definition = {
        model = model,
        kind = "prop",
        position = {
            x = spot.x + spot.nx * outset - ox,
            y = spot.y + spot.ny * outset - oy,
            z = spot.z + number(block.groundOffsetMetres, 0.0),
        },
        yaw = yaw,
        -- A number would scale uniformly; the table is the per-axis form, and
        -- per-axis is the entire point -- one prop stretched along the line is
        -- one entity where ten would otherwise be needed. `wiki/props.md` states
        -- that a non-unit scale is honoured by the MESH back-end only, which is
        -- what every alias used here is.
        --
        -- IT IS ALSO THE ONE THING HERE THAT IS NOT PROVEN. `Props.cpp` writes
        -- `mesh->visualScale` and re-toggles the component, which is the same
        -- mechanism that made light colour writes take (research 33.4) and the
        -- mechanism that did NOT make a mesh path write take (E0.4); nobody has
        -- photographed a stretched prop. Every scale in the config is therefore
        -- chosen so that UNIT scale still reads: a hesco every two metres is
        -- 80 % wall unscaled, and a container is 4.8 m of steel unscaled.
        scale = { x = sx, y = sy, z = up },
    }
    -- An explicit appearance is passed only when a block names one, because
    -- `Props.cpp` writes `meshAppearance` on every mesh host -- "default" when
    -- the caller says nothing -- and the route-arrow hologram's authored
    -- appearance is `orange_arrows`, not `default`. Naming it makes that write
    -- a no-op whether or not it takes effect.
    local appearance = type(block.appearance) == "string" and block.appearance
        or defaults.appearance
    if appearance ~= nil and appearance ~= "" then definition.appearance = appearance end
    local id, reason = Open77.props.create(definition)
    return id, reason, model
end

--- Put ONE red point light beside the line. Shared by the marker light (the
--- big pool on the closed side) and the wall beacons (small, on top of the
--- rampart): same host, same fields, two config blocks.
---
--- `collision = false` and `physics = "none"` are both passed, and both for the
--- same reason. The light host is a cloned loot crate, so without them the
--- edge would be a line of floating valuable-crate meshes that a player could
--- bump into -- which would be a wall, and this mode does not have walls.
--- `Props.cpp` treats either as the signal to switch the donor's physical mesh
--- off, which hides the crate and leaves the light (`canDropCollision`).
--- The COMPLETE light table for one lamp, in one of its states.
---
--- Complete, never partial, and that is a fact about the binding rather than
--- a style: `Api::Props::Update` does `next.light = aPatch.value.light`
--- (client/src/api/Props.cpp), so a patch carrying `{ light = { enabled =
--- false } }` would also write the reader's DEFAULT colour, intensity and
--- radius over the lamp's own -- and a default radius fails validation, so the
--- update would simply be refused. Every state of a lamp is therefore
--- rebuilt from its config block, and `LightMatches` on the native side turns
--- a table identical to the current one into a no-op.
---
--- `lit` is the chase; `surge` is the closure flare. A lamp that is both
--- surging and dark is lit: the flare is the louder message and it lasts
--- five seconds.
local function lampLight(block, defaults, lit, surge, override)
    local colour = type(block.color) == "table" and block.color or EMPTY
    -- `override` is the fill lamp's wider pool (`beacon.fillIntensity` /
    -- `beacon.fillRadius`): the same config block, two reaches, because a lamp
    -- every 8 m has further to carry than a lamp every 4.
    local intensity = number(override and override.intensity,
        number(block.intensity, defaults.intensity))
    local radius = number(override and override.radius,
        number(block.radius, defaults.radius))
    local r, g, b = number(colour.x, 1.0), number(colour.y, 0.06), number(colour.z, 0.05)
    if surge then
        local flare = cfg().surge or {}
        local hot = type(flare.color) == "table" and flare.color or EMPTY
        r, g, b = number(hot.x, 1.0), number(hot.y, 0.62), number(hot.z, 0.30)
        -- Clamped to the client's own ceiling so a generous scale on a bright
        -- lamp cannot turn a flare into an `invalid_light` refusal.
        intensity = math.min(10000.0, intensity * math.max(0.0, number(flare.intensityScale, 2.0)))
        lit = true
    end
    return {
        spot = false,
        color = { x = r, y = g, z = b },
        intensity = intensity,
        radius = radius,
        enabled = lit ~= false,
    }
end

--- Put ONE red point light beside the line. Shared by the marker light (the
--- big pool on the closed side) and the wall beacons (small, on top of the
--- rampart): same host, same fields, two config blocks.
---
--- `collision = false` and `physics = "none"` are both passed, and both for the
--- same reason. The light host is a cloned loot crate, so without them the
--- edge would be a line of floating valuable-crate meshes that a player could
--- bump into -- which would be a wall, and this mode does not have walls.
--- `Props.cpp` treats either as the signal to switch the donor's physical mesh
--- off, which hides the crate and leaves the light (`canDropCollision`).
---
--- `lit` and `surge` are the lamp's INITIAL state, so a beacon raised in the
--- middle of a beat or a flare joins the pattern rather than standing out of
--- step until the next one.
local function raiseLamp(block, spot, defaults, lit, surge, override)
    local outset = number(block.outsetMetres, defaults.outset)
    local id, reason = Open77.props.create({
        -- The model string is a LABEL here, not a lookup: the client routes
        -- every `kind = "light"` prop to the one host entity that carries a
        -- light component (`kLightHostEntity` in client/src/api/Props.cpp),
        -- and never reads this. It is still required to be non-empty.
        model = "light",
        kind = "light",
        position = {
            x = spot.x + spot.nx * outset,
            y = spot.y + spot.ny * outset,
            z = spot.z + number(block.heightMetres, defaults.height),
        },
        collision = false,
        physics = "none",
        light = lampLight(block, defaults, lit, surge, override),
    })
    return id, reason
end

-- The lamp blocks' defaults, stated once because `raise` and `lampStep` both
-- have to rebuild the same light table and must not drift. The beacon is a
-- knee-high lamp on the line since the eighth round (it used to sit on the
-- crest of the hesco at 3.2 m); the next-line lamp is amber at chest height.
local BEACON_DEFAULTS = { outset = 0.0, height = 0.6, intensity = 180.0, radius = 6.0 }
local LIGHT_DEFAULTS = { outset = 30.0, height = 4.0, intensity = 850.0, radius = 70.0 }
local NEXT_DEFAULTS = { outset = 0.0, height = 1.2, intensity = 320.0, radius = 14.0 }

--- The config block, defaults and reach override for one lamp, by the kind
--- recorded on its post. `raise` and `lampDrain` both go through this so a
--- lamp is rewritten with the same table it was raised with.
local function lampSourceFor(post, settings)
    if post.lampKind == "next" then
        return settings.next or EMPTY, NEXT_DEFAULTS, nil
    end
    local beacon = settings.beacon or EMPTY
    if post.lampKind == "fill" then
        return beacon, BEACON_DEFAULTS, {
            intensity = number(beacon.fillIntensity, nil),
            radius = number(beacon.fillRadius, nil),
        }
    end
    return beacon, BEACON_DEFAULTS, nil
end

--- Whether a beacon on `slot` is lit in chase phase `phase`. Beacons stand on
--- every `everySlots`-th slot, so consecutive beacons have consecutive
--- quotients, and alternating on the quotient's parity lights every other
--- beacon -- then the next phase lights the others. The cadence is the slot
--- index, which is geometric, so the pattern is the same wherever the player
--- stands and a beacon raised late joins it in the right state.
local function beaconLit(slot, phase)
    local every = math.max(1, math.floor(number((cfg().beacon or EMPTY).everySlots, 3)))
    return (math.floor(slot / every) + phase) % 2 == 0
end

--- Play ONE looping world effect beside the line. Shared by the fire, the
--- blaze and the column.
local function raiseFlame(block, spot, defaults)
    local effect = type(block.effect) == "string" and block.effect or defaults.effect
    local outset = number(block.outsetMetres, defaults.outset)
    local handle, reason = Open77.vfx.play(effect, {
        position = {
            x = spot.x + spot.nx * outset,
            y = spot.y + spot.ny * outset,
            z = spot.z + number(block.heightMetres, 0.0),
        },
        -- No orientation: every effect here is authored vertical. An oriented
        -- beam -- `laser.mine`, or the raw 9 m mine laser named in the config --
        -- is the case that would need one, and it needs a MEASUREMENT of which
        -- axis it is authored along before a quaternion here would be anything
        -- but a guess.
        duration = number(block.durationSeconds, 0.0),
    })
    return handle, reason, effect
end

--- Whether a wall slot carries a layer placed every `everySlots` slots. The
--- cadence is on the slot INDEX, which is geometric, so the strip and beacon
--- positions never move as the player walks -- the same rule the slot lattice
--- itself keeps.
local function onCadence(block, slot, fallback)
    local every = math.max(1, math.floor(number(block.everySlots, fallback)))
    -- `phaseSlots` shifts a layer's cadence along the wall so two layers at
    -- the same pitch interleave instead of stacking on one slot: the flame
    -- at phase 1 sits between the beacons at phase 0.
    local phase = math.floor(number(block.phaseSlots, 0))
    return (slot + phase) % every == 0
end

local function raise(key, spot)
    local settings = cfg()
    local post = {
        x = spot.x, y = spot.y, z = spot.z,
        nx = spot.nx, ny = spot.ny,
        marker = spot.marker == true,
        -- WHICH TIER. A wall post carries the rampart, the strip and the
        -- beacon; a marker carries the container, the fires and the light; a
        -- post can be both. Recorded on the post so the diff can tell when the
        -- tier under a standing post has changed.
        wall = spot.wall == true,
        slot = math.floor(number(spot.slot, 0)),
        -- WHICH CORDON THIS POST BELONGS TO. Read by the diff's hysteresis, and
        -- it is the whole fix for the ghost posts the 19:32 log measured: a post
        -- kept because it is still NEARBY is only a post worth keeping while the
        -- boundary it was placed on still exists.
        rev = revision,
        -- THE NEXT LINE: the boundary of the zone that survives the announced
        -- phase. An amber lamp and nothing else -- see the eighth-round note.
        next = spot.next == true,
    }
    local props = propsAvailable()
    local vfx = vfxAvailable()

    -- 0. A NEXT-LINE POST: one amber lamp, always lit, joining a flare in
    -- progress like every other lamp. Nothing else on it, by design -- this
    -- line is a warning and moves one ring inward every phase, so it has to
    -- be the cheapest post there is. Held or dropped the same way as the
    -- rest; the "first post" line below is for the boundary proper.
    if post.next then
        local ahead = settings.next or EMPTY
        if ahead.enabled ~= false and props then
            post.lampKind = "next"
            local id, reason = raiseLamp(ahead, spot, NEXT_DEFAULTS, true, surgeLive)
            if id == nil then
                warnOnce("next:" .. tostring(reason),
                    ("the next-line lamp was refused (%s). The zone ahead is not drawn " ..
                     "in the world; the HUD's ZONE CLOSING strip still points at it.")
                        :format(tostring(reason)))
            else
                post.beacon = id
                post.beaconLit = true
                post.beaconSurge = surgeLive
            end
        end
        if post.beacon == nil then return end
        posts[key] = post
        postCount = postCount + 1
        return
    end

    -- Whether this is a FILL post: on the current line, beyond the near
    -- tier, neither a marker nor a wall slot. Since the eighth round it
    -- carries a lamp (`beacon.fill`) where it used to carry the roadblock.
    local fill = not post.wall and not post.marker

    -- 1. THE RAMPART, on WALL slots: the layer this round exists for.
    --
    -- `barrier.hesco` is `hesco_barrier_a_high_single_a.mesh`, MEASURED at
    -- 1.58 x 1.59 x 2.01 m with its origin on a vertical edge (the `centre`
    -- default below is the measured footprint centre). One every two-metre slot
    -- is an 80 % wall UNSCALED -- so this layer does not depend on
    -- `visualScale`, which nobody has photographed -- and it is the game's own
    -- military cordon vocabulary. It is hollow: `docs/generated/prop-hosts.json`
    -- records `"collision": false`, the same guarantee the roadblock rests on.
    -- Same host generator, same alias chain as the photographed roadblock; the
    -- hesco itself has NOT been photographed, which its config block says.
    --
    -- No `collision = false` and no `physics = "none"` on any mesh prop here,
    -- and their absence is deliberate rather than an omission. Both set
    -- `hideCollision` in `client/src/api/Props.cpp`, and on a mesh host neither
    -- can be honoured -- the single `entPhysicalMeshComponent` is the solid
    -- component AND the visible one, so the API logs a warning naming the prop
    -- and keeps it solid. Asking would buy nothing and would write that warning
    -- once per post. Non-blocking comes from the ALIAS instead. Substituting an
    -- alias that reads `"collision": true` would give this mode a wall.
    if post.wall then
        local rampart = settings.rampart or {}
        if rampart.enabled ~= false and props then
            local id, reason, model = raiseBarricade(rampart, spot, {
                model = "barrier.hesco",
                along = 1.15, across = 1.0, up = 1.4, lengthAxis = "x",
                centre = { x = -0.75, y = 0.75 },
            })
            if id == nil then
                warnOnce("rampart:" .. tostring(reason),
                    ("the edge rampart %q was refused (%s). Wall slots fall back to the " ..
                     "roadblock -- check the alias against Open77.props.catalog(), and " ..
                     "the prop quota if the reason is quota_exceeded."):format(
                        model, tostring(reason)))
            else
                post.rampart = id
            end
        end
    end

    -- 2. THE BARRICADE, on every post that did not get a rampart: fill slots,
    -- markers outside the wall tier, and wall slots whose hesco was refused.
    -- The one prop in this file with a photograph behind it (the 1 m capture
    -- band, docs/research/battle-royale-and-scale.md), which is why it is the
    -- fallback for everything.
    local barrier = settings.barrier or {}
    if post.rampart == nil and barrier.enabled ~= false and props then
        local id, reason, model = raiseBarricade(barrier, spot, {
            model = "barrier.roadblock.concrete",
            along = 2.5, across = 1.0, up = 2.0, lengthAxis = "y",
        })
        if id == nil then
            warnOnce("barrier:" .. tostring(reason),
                ("the edge barrier %q was refused (%s). The boundary falls back to its " ..
                 "bastions and its fires -- check the alias against " ..
                 "Open77.props.catalog()."):format(model, tostring(reason)))
        else
            post.barrier = id
        end
    end

    -- 3. THE STRIP, on WALL slots on a cadence: the orange chevron hologram,
    -- flat on the line itself. UNVERIFIED -- see its config block -- and cheap
    -- to be wrong about: a hologram that does not draw costs one hollow entity
    -- and nothing else, and one that does is the only layer here that is
    -- emissive AND on the ground, which is the "painted line you walk up to"
    -- that reads at noon and at midnight alike.
    local strip = settings.strip or {}
    if post.wall and strip.enabled ~= false and props and onCadence(strip, post.slot, 2) then
        local id, reason, model = raiseBarricade(strip, spot, {
            model = "race.route_arrow", appearance = "orange_arrows",
            along = 1.0, across = 1.0, up = 1.0, lengthAxis = "y",
            outset = -1.5,
        })
        if id == nil then
            warnOnce("strip:" .. tostring(reason),
                ("the edge strip %q was refused (%s). The rampart stands without its " ..
                 "ground line -- check the alias against Open77.props.catalog()."):format(
                    model, tostring(reason)))
        else
            post.strip = id
        end
    end

    -- 4. THE LAMP: a red light at knee height on the line. On WALL slots on a
    -- cadence (the odd ones, between the fires -- see `beacon.phaseSlots`),
    -- and on every FILL post when `beacon.fill` is on, with the wider pool
    -- the fill pitch needs. Same host as the marker light, which is
    -- photographed; these radii and intensities are not.
    local beacon = settings.beacon or {}
    local wantsLamp = false
    if beacon.enabled ~= false and props then
        if post.wall and onCadence(beacon, post.slot, 2) then
            wantsLamp = true
            post.lampKind = "line"
        elseif fill and beacon.fill ~= false then
            wantsLamp = true
            post.lampKind = "fill"
        end
    end
    if wantsLamp then
        -- Raised in the state the pattern is in RIGHT NOW: the chase phase
        -- decides lit or dark, and a closure flare in progress overrides
        -- both. Recorded on the post so `lampStep` knows what it last wrote.
        local lit = (settings.chase or EMPTY).enabled == false or beaconLit(post.slot, chasePhase)
        local block, defaults, override = lampSourceFor(post, settings)
        local id, reason = raiseLamp(block, spot, defaults, lit, surgeLive, override)
        if id == nil then
            warnOnce("beacon:" .. tostring(reason),
                ("the edge lamp was refused (%s). The line is fires alone; the marker " ..
                 "lights still wash the closed side."):format(tostring(reason)))
        else
            post.beacon = id
            post.beaconLit = lit or surgeLive
            post.beaconSurge = surgeLive
        end
    end

    -- 4b. THE FLAME, on WALL slots on the cadence between the lamps: since
    -- the eighth round this IS the line. `fire.small` -- the alias with a
    -- captured frame (§31.1) and nineteen accepted handles in the session that
    -- confirmed the boundary -- on the ground, on every even near-line slot.
    -- The one layer here that moves without a single update call. GATED on
    -- the effect ceiling, after the burn: it gives way before the markers'
    -- proven fire does. Counted as `flames=` on the status line.
    local flame = settings.flame or {}
    if post.wall and flame.enabled ~= false and vfx and onCadence(flame, post.slot, 2) then
        if effectsLive(monotonic()) >= effectCeiling() then
            warnOnce("flame:ceiling",
                ("the rampart flames stopped at the effect ceiling (%d of %d handles held). " ..
                 "The wall stands without the rest of its fires; lower blaze or raise " ..
                 "Config.cordon.edge.maxEffects if this is unexpected.")
                    :format(effectsLive(monotonic()), effectCeiling()))
        else
            local handle, reason, effect = raiseFlame(flame, spot, {
                effect = "fire.small", outset = 0.0,
            })
            if handle == nil then
                warnOnce("flame:" .. tostring(reason),
                    ("the rampart flame %q was refused (%s). The wall stands without its " ..
                     "fires; the marker burns are unaffected."):format(effect, tostring(reason)))
            else
                post.flame = handle
                effectCount = effectCount + 1
            end
        end
    end

    -- 5. THE BASTION, on MARKER posts: the mass that reads from a distance.
    --
    -- `container.shipping` is `industrial_container_a.mesh`, MEASURED at
    -- 4.82 x 2.67 x 1.94 m with its length on local X and its origin at the
    -- base, centred in plan -- so `lengthAxis = "x"`, which the fifth round
    -- guessed wrong and laid the containers across the line. Hollow in
    -- `docs/generated/prop-hosts.json` (`"collision": false`): the containers in
    -- Night City are solid only because a level author put a collision node
    -- beside them, and nothing puts one here.
    --
    -- MARKERS ONLY, so the far line is a container every lattice cell with the
    -- wall or the kerb line running between them. A continuous wall of
    -- containers would be opaque, and the people outside the cordon are
    -- precisely the ones running in through it -- they have to be visible while
    -- they do.
    local bastion = settings.bastion or {}
    if bastion.enabled ~= false and props and
        (post.marker or bastion.markersOnly == false) then
        local id, reason, model = raiseBarricade(bastion, spot, {
            model = "container.shipping",
            along = 2.5, across = 1.0, up = 2.0, lengthAxis = "x",
            outset = 2.5,
        })
        if id == nil then
            warnOnce("bastion:" .. tostring(reason),
                ("the edge bastion %q was refused (%s). The markers keep their fires and " ..
                 "lights but lose their mass -- check the alias against " ..
                 "Open77.props.catalog()."):format(model, tostring(reason)))
        else
            post.bastion = id
        end
    end

    -- 6. THE MAST, on MARKER posts, OPT-IN (`enabled == true`, not `~= false`):
    -- `street.electrical_pole`, measured 6.1 m tall, the tallest hollow object
    -- in the catalogue that is not absurd on a street. Off by default because
    -- a row of utility poles does not say "cordon"; documented so that a round
    -- that needs height at 150 m has a measured option to reach for.
    local mast = settings.mast or {}
    if mast.enabled == true and props and (post.marker or mast.markersOnly == false) then
        local id, reason, model = raiseBarricade(mast, spot, {
            model = "street.electrical_pole",
            along = 1.0, across = 1.0, up = 1.0, lengthAxis = "y",
            outset = 3.0,
        })
        if id == nil then
            warnOnce("mast:" .. tostring(reason),
                ("the edge mast %q was refused (%s)."):format(model, tostring(reason)))
        else
            post.mast = id
        end
    end

    -- 7. THE BURN, on MARKER posts: `fire.small`, THE ONLY EFFECT IN THIS FILE
    -- WITH A SCREENSHOT BEHIND IT (research section 31.1, from the SERVER path;
    -- E0.5 for the 385 m stream round trip). Placed just INSIDE the wall line
    -- now (`outsetMetres = -1.0`), between the strip and the rampart, so a
    -- player at five metres sees it in front of the hesco rather than hidden
    -- behind a container.
    local burn = settings.burn or {}
    if burn.enabled ~= false and vfx and (post.marker or burn.markersOnly == false) then
        local handle, reason, effect = raiseFlame(burn, spot, {
            effect = "fire.small", outset = -1.0,
        })
        if handle == nil then
            warnOnce("burn:" .. tostring(reason),
                ("the edge fire %q was refused (%s). This is the only effect alias in the " ..
                 "tree with an in-game screenshot behind it, so a refusal here is a " ..
                 "runtime problem rather than a bad alias -- check " ..
                 "Open77.vfx.catalog()."):format(effect, tostring(reason)))
        else
            post.burn = handle
            effectCount = effectCount + 1
        end
    end

    -- 8. THE BLAZE, on MARKER posts: `fire.large`, UNVERIFIED, behind the
    -- container so its plume shows above it from inside. Same authored family
    -- (`base\fx\environment\pyro\`) as the photographed `fire.small`, and the
    -- same family the game places as static particle nodes in its own sectors
    -- (`e_fire_medium_tall`, `e_fire_small` in `exterior_-24_-38_0_0`,
    -- docs/research/multiplayer-mode.md), which is the inference that it is
    -- self-contained. Counted separately on the status line; one boolean in its
    -- config block removes it.
    local blaze = settings.blaze or {}
    if blaze.enabled ~= false and vfx and (post.marker or blaze.markersOnly == false) then
        -- GATED on the effect ceiling since the seventh round, and since the
        -- eighth it also keeps `blaze.reserve` handles FREE below it: it is
        -- the unverified layer, so it is the one that gives way when the
        -- budget is short, and a closure must always have room for its
        -- blasts. Silent when refused for that reason -- the flame's warning
        -- already names the ceiling.
        local reserve = math.max(0, math.floor(number(blaze.reserve, 8)))
        if effectsLive(monotonic()) + reserve < effectCeiling() then
            local handle, reason, effect = raiseFlame(blaze, spot, {
                effect = "fire.large", outset = 4.5,
            })
            if handle == nil then
                warnOnce("blaze:" .. tostring(reason),
                    ("the edge blaze %q was refused (%s). Unverified layer; the small fire " ..
                     "still burns."):format(effect, tostring(reason)))
            else
                post.blaze = handle
                effectCount = effectCount + 1
            end
        end
    end

    -- 9. THE COLUMN, on MARKER posts, OPT-IN. Fifty metres of black smoke every
    -- two metres would be an opaque lid over the street, and a player cannot
    -- fight what they cannot see; at the marker pitch it is what it was
    -- designed to be, the thing you read from across the district. Off in the
    -- shipped config: never seen by anybody. `column.markersOnly = false` puts
    -- one on every post.
    local column = settings.column or {}
    if column.enabled == true and vfx and (post.marker or column.markersOnly == false) then
        local handle, reason, effect = raiseFlame(column, spot, {
            effect = "smoke.column.black", outset = 0.0,
        })
        if handle == nil then
            warnOnce("vfx:" .. tostring(reason),
                ("the column effect %q was refused (%s). The edge falls back to its lights; " ..
                 "check the alias against Open77.vfx.catalog()."):format(effect, tostring(reason)))
        else
            post.vfx = handle
            effectCount = effectCount + 1
        end
    end

    -- 10. THE LIGHT, on MARKER posts: the big red pool on the closed side, the
    -- layer that answers "which way is in". Coloured light pools are
    -- photographed on two clients at night (research 33.4, 33.8); this radius
    -- and intensity are not, and daylight is unmeasured. MARKERS ONLY because
    -- a real-time light is the expensive half of a post for the renderer;
    -- `light.markersOnly = false` puts one on every post.
    local light = settings.light or {}
    if light.enabled ~= false and props and (post.marker or light.markersOnly == false) then
        -- Always lit -- the pool is the readout that says which way is in, and
        -- the chase never touches it -- but it joins a closure flare in
        -- progress like everything else on the line.
        local id, reason = raiseLamp(light, spot, LIGHT_DEFAULTS, true, surgeLive)
        if id == nil then
            warnOnce("light:" .. tostring(reason),
                ("the edge light was refused (%s). The boundary still stands, but the " ..
                 "side that glows -- which is what says which way is IN -- is gone."):format(
                    tostring(reason)))
        else
            post.light = id
            post.lightSurge = surgeLive
        end
    end

    -- A post that produced NONE of its layers is not held: keeping an empty
    -- record would make the diff believe the spot was drawn and never retry it.
    local produced = false
    for index = 1, #PROP_LAYERS do
        if post[PROP_LAYERS[index]] ~= nil then produced = true break end
    end
    if not produced then
        for index = 1, #VFX_LAYERS do
            if post[VFX_LAYERS[index]] ~= nil then produced = true break end
        end
    end
    if not produced then return end
    posts[key] = post
    postCount = postCount + 1

    -- SAY IT ONCE, AND SAY EXACTLY WHAT IT PROVES.
    --
    -- The previous wording was "the world boundary is drawing", and it was
    -- wrong in the way that cost this feature two rounds with the owner. Both
    -- handles are ACCEPTANCES, not pixels: `Open77.props.create` returns as soon
    -- as `Api::Props::Create` has allocated an id and queued a
    -- `DynamicEntityService::Spawn`, and the entity can still fail component
    -- resolution ticks later; `Open77.vfx.play` returns as soon as
    -- `gameFxSystem.SpawnEffect` hands back an instance, which says the resource
    -- reference was accepted, not that the effect has anything to render outside
    -- the context it was authored in. The periodic line from `report` is the one
    -- that carries evidence -- `rendered`/`failed` come from the engine.
    if not raisedEver then
        raisedEver = true
        say("info", ("first post accepted at (%.1f,%.1f,%.1f) yaw=%.0f slot=%d " ..
            "(wall=%s marker=%s rampart=%s barrier=%s strip=%s beacon=%s bastion=%s " ..
            "burn=%s blaze=%s light=%s) -- handles only; the periodic posts=... line " ..
            "reports what the ENGINE says it rendered.")
            :format(post.x, post.y, post.z, number(spot.yaw, 0.0), post.slot,
                tostring(post.wall), tostring(post.marker),
                tostring(post.rampart ~= nil), tostring(post.barrier ~= nil),
                tostring(post.strip ~= nil), tostring(post.beacon ~= nil),
                tostring(post.bastion ~= nil), tostring(post.burn ~= nil),
                tostring(post.blaze ~= nil), tostring(post.light ~= nil)))
    end
end

-- ---------------------------------------------------------------------------
-- THE PASS
--
-- One job per call, and each job is bounded. `stepOnce` returns true while work
-- is still owed, which is what selects the short poll interval: the edge
-- assembles over a second or two after a closure and then costs one position
-- read a second until the next one.
-- ---------------------------------------------------------------------------

local function queueTeardown()
    scanState = nil
    if pendingRetire ~= nil then return end
    pendingRetire = {}
    for key in pairs(posts) do pendingRetire[#pendingRetire + 1] = key end
    pendingRaise = nil
    plan = nil
    planRevision = -1
    planX, planY = nil, nil
end

-- ---------------------------------------------------------------------------
-- SAYING WHAT IS ACTUALLY ON SCREEN
--
-- The previous revision logged `first post up (vfx=true light=true)` and then
-- nothing, and that line is a LIE OF OMISSION in the one way that mattered: a
-- non-nil handle from `Open77.props.create` means an id was allocated, not that
-- anything was drawn. `Api::Props::Create` (client/src/api/Props.cpp) returns
-- immediately and hands the work to `DynamicEntityService`, which may still fail
-- component resolution several ticks later and set `failed = true`; the Lua side
-- never hears about it. `open77_groundcircle/client/main.lua` opens with exactly
-- this complaint about the native marker -- "the native registry still reports
-- the marker as rendered, so a caller cannot tell a drawn ring from an invisible
-- one" -- and it is the same trap here.
--
-- So this reports what the ENGINE says, not what this file believes: how many
-- props it holds, how many of those it says are rendered, how many failed, and
-- how many effects are live. Plus the geometry, because "is it drawing?" and "is
-- it drawing WHERE I AM?" are different questions and the first one alone cost
-- two rounds. One line, at most every `statusIntervalMs`, and only while the
-- world layer is switched on -- a mode running with `cordonEdge = "hud"` writes
-- nothing at all.
--
-- It is its OWN pass. `props.list()` builds one table per prop with eleven
-- fields; at thirty-two posts that is a few hundred allocations, which is the
-- shape of thing that trips the execution-budget hook when it shares a resume
-- with anything else.
local function report(px, py, pz)
    local props, rendered, failed = 0, 0, 0
    if propsAvailable() and type(Open77.props.list) == "function" then
        local ok, list = pcall(Open77.props.list)
        if ok and type(list) == "table" then
            for index = 1, #list do
                local entry = list[index]
                if type(entry) == "table" then
                    props = props + 1
                    if entry.rendered then rendered = rendered + 1 end
                    if entry.failed then failed = failed + 1 end
                end
            end
        end
    end
    local effects = 0
    if vfxAvailable() and type(Open77.vfx.list) == "function" then
        local ok, list = pcall(Open77.vfx.list)
        if ok and type(list) == "table" then effects = #list end
    end

    -- The nearest post, and how far away it is. On 2026-09-03 this said 42 m
    -- while the player stared at empty street, which settled it: the geometry
    -- was right and the PRIMITIVE was what did not draw. That is why the wall
    -- exists, and why `wall=` is now on this line -- it is the first half of the
    -- new bisect. If this line says `wall=14 panels live=true` and the HUD's own
    -- `open77_cordon_hud wall:` line says `drawn=0`, the fault is in the
    -- projection or the camera; if the HUD says `drawn>0 shown=yes` and the
    -- street is still empty, the fault is in the page. Neither reading was
    -- obtainable before.
    --
    -- The origin is the LAST SCAN's, not a fresh `character.state`: the two are
    -- within `refreshMetres` of each other by construction, and reading the
    -- character on every pass would put an engine call in the busy path this
    -- file spent a whole revision getting out of it.
    local nearest, nearestDistance = nil, nil
    local markers, ramparts, barriers, bastions = 0, 0, 0, 0
    local strips, beacons, burns, blazes, masts, lights, stale = 0, 0, 0, 0, 0, 0, 0
    local nexts = 0
    if px ~= nil then
        for _, post in pairs(posts) do
            if post.marker then markers = markers + 1 end
            if post.next then nexts = nexts + 1 end
            if post.rampart ~= nil then ramparts = ramparts + 1 end
            if post.barrier ~= nil then barriers = barriers + 1 end
            if post.bastion ~= nil then bastions = bastions + 1 end
            if post.strip ~= nil then strips = strips + 1 end
            if post.beacon ~= nil then beacons = beacons + 1 end
            if post.burn ~= nil then burns = burns + 1 end
            if post.blaze ~= nil then blazes = blazes + 1 end
            if post.mast ~= nil then masts = masts + 1 end
            if post.light ~= nil then lights = lights + 1 end
            -- A post still standing from an EARLIER cordon. Should be zero on
            -- every line after a closure has settled; a non-zero number that
            -- persists means the revision-aware hysteresis below is not doing
            -- its job, which is what pinned the 2026-09-03 layer at forty.
            if post.rev ~= revision then stale = stale + 1 end
            local dx, dy = post.x - px, post.y - py
            local distance = dx * dx + dy * dy
            if nearestDistance == nil or distance < nearestDistance then
                nearest, nearestDistance = post, distance
            end
        end
    end

    -- `props` counts EVERY prop kind this resource owns -- one hesco or one
    -- roadblock per post, then per marker a container, a light and maybe a
    -- mast, then per wall slot a strip every second and a beacon every third --
    -- so it is not the post count and is not meant to be. THE LAYER COUNTS ARE
    -- THE POINT OF THIS LINE: each layer has its own evidence status (see the
    -- sixth-round note at the top), so a screenshot that shows the hesco wall
    -- and no orange strip, against `ramparts=40 strips=20`, says exactly which
    -- primitive did not draw. `rendered` and `failed` are the engine's words and
    -- prove allocation, not pixels.
    -- `flames=` is the wall fire (seventh round); `effects=held/ceiling` is
    -- this file's own count against the gate the decorative layers obey, and
    -- `vfx=` is the engine's count of the same handles -- the two should agree
    -- to within the blasts still burning. `chase=` and `surge=` say which state
    -- the lamps were last asked for, so a capture of a dark beacon can be read
    -- against the pattern rather than against a fault.
    local flames = 0
    if px ~= nil then
        for _, post in pairs(posts) do
            if post.flame ~= nil then flames = flames + 1 end
        end
    end
    -- `nexts=` is the second line (amber lamps on the boundary of the zone
    -- that survives); `lamps=` is every lamp held -- line, fill and next --
    -- which is the real-time light count the eighth round has not measured;
    -- `beat=` is the chase interval last used, so a capture of a fast flicker
    -- can be read against the hurry rather than against a fault.
    say("info", ("posts=%d (markers=%d nexts=%d ramparts=%d barriers=%d bastions=%d " ..
        "strips=%d lamps=%d burns=%d blazes=%d flames=%d masts=%d lights=%d stale=%d " ..
        "props=%d rendered=%d failed=%d vfx=%d effects=%d/%d blasts=%d) " ..
        "chase=%s beat=%dms surge=%s " ..
        "wall=%d panels live=%s style=%s " ..
        "radius=%.0fm window=%s segments=%d/%d open=%d doomed=%d rev=%d scanAt=%s%s")
        :format(postCount, markers, nexts, ramparts, barriers, bastions,
            strips, beacons, burns, blazes, flames, masts, lights, stale,
            props, rendered, failed, effects, effectsLive(monotonic()), effectCeiling(),
            blastCount,
            (cfg().chase or EMPTY).enabled == false and "off" or ("phase" .. tostring(chasePhase)),
            lastBeatMs,
            surgeLive and "live" or "idle",
            wallPanels, tostring(wallActive), tostring(style()),
            lastRadius, lastWindow, lastSegments - lastNextSegments, lastNextSegments,
            openCells, closingCount, revision,
            px ~= nil and ("(%.1f,%.1f,%.1f)"):format(px, py, pz or 0.0) or "unknown",
            nearest ~= nil
                and (" nearest post=(%.1f,%.1f,%.1f) d=%.0fm wall=%s"):format(
                    nearest.x, nearest.y, nearest.z, math.sqrt(nearestDistance),
                    tostring(nearest.wall == true))
                or " nearest post=NONE -- nothing is standing"))
end

-- ---------------------------------------------------------------------------
-- THE LAMP ANIMATOR -- the chase and the surge, on a pass of their own.
--
-- Three jobs, one per pass, and every one of them bounded:
--
--   1. OPEN A BEAT. When the chase's beat is due, or a closure flare has just
--      begun or just ended, walk `posts` ONCE and queue the key of every post
--      whose lamp state no longer matches what the pattern wants. That walk is
--      up to a hundred integer lookups and at most forty inserts, which is the
--      same order as the plan build and gets the same treatment: a pass of its
--      own, and nothing else in it.
--   2. DRAIN. Pop up to `chase.updatesPerTick` keys and rewrite each lamp's
--      COMPLETE light table (see `lampLight`). A post that was retired since
--      it was queued is simply skipped -- `posts[key]` is nil.
--   3. NOTHING. The queue is empty and the beat is not due. `lampWakeAt`
--      tells the poll when to come back, so the idle interval does not stretch
--      the beat to a second and a half.
--
-- The next beat is NOT opened until the last one has drained. A long wall
-- therefore slows the beat instead of stacking two beats' worth of updates
-- into the queue, which is the only way this pass could ever grow past its
-- budget.
--
-- The surge is a state, not an event: `surgeLive` is true from the first pass
-- after a closure until `surgeUntil`, and a beat opened in either transition
-- rewrites every lamp. While it is live the chase is suspended -- every lamp
-- is asked to be lit and white-hot -- and it resumes from the same phase when
-- the flare ends.
-- ---------------------------------------------------------------------------

--- What a given post's lamps should look like right now, as two booleans per
--- lamp: (lit, surge). The beacon follows the chase; the marker light is
--- always lit.
local function wantedBeacon(post)
    if surgeLive then return true, true end
    -- The next line does not chase: it is a warning, and a warning holds
    -- steady so the eye can measure its distance. The chase is how the
    -- CURRENT line says "this is moving".
    if post.lampKind == "next" then return true, false end
    if (cfg().chase or EMPTY).enabled == false then return true, false end
    return beaconLit(post.slot, chasePhase), false
end

--- The chase interval in seconds RIGHT NOW: `chase.stepMs`, shortened toward
--- `chase.hurryStepMs` over the last `chase.hurrySeconds` before the next
--- closure, and held there through the closing window (where `closeAtMono`
--- is always a second or two away). This is the clock the player feels: the
--- line flickers faster as the phase ends, with no number to read.
local function chaseStep(chase, now)
    local step = math.max(0.2, number(chase.stepMs, 800) / 1000.0)
    local hurry = math.max(0.0, number(chase.hurrySeconds, 20.0))
    if hurry > 0.0 and closeAtMono ~= nil and now > 0.0 then
        local remaining = closeAtMono - now
        if remaining < hurry then
            local floorStep = math.max(0.1, number(chase.hurryStepMs, 300) / 1000.0)
            if floorStep < step then
                local t = math.max(0.0, remaining) / hurry
                step = floorStep + (step - floorStep) * t
            end
        end
    end
    lastBeatMs = math.floor(step * 1000.0 + 0.5)
    return step
end

--- Queue every post whose lamps are out of step with the pattern. One walk.
local function lampOpenBeat()
    lampQueue = {}
    local count = 0
    for key, post in pairs(posts) do
        local owed = false
        if post.beacon ~= nil then
            local lit, surge = wantedBeacon(post)
            if post.beaconLit ~= lit or post.beaconSurge ~= surge then owed = true end
        end
        if post.light ~= nil and post.lightSurge ~= surgeLive then owed = true end
        if owed then
            count = count + 1
            lampQueue[count] = key
        end
    end
    if count == 0 then lampQueue = nil end
end

--- Rewrite at most `budget` lamps from the queue. Returns true while the queue
--- still owes work.
local function lampDrain(budget)
    if lampQueue == nil then return false end
    local settings = cfg()
    local light = settings.light or EMPTY
    local done = 0
    while #lampQueue > 0 and done < budget do
        local key = table.remove(lampQueue)
        local post = posts[key]
        if post ~= nil then
            if post.beacon ~= nil then
                local lit, surge = wantedBeacon(post)
                if post.beaconLit ~= lit or post.beaconSurge ~= surge then
                    -- The same block, defaults and reach the lamp was raised
                    -- with -- a line lamp, a fill lamp and a next-line lamp
                    -- are three different tables, and rewriting one with
                    -- another's would move its pool.
                    local block, defaults, override = lampSourceFor(post, settings)
                    local ok = pcall(Open77.props.update, post.beacon,
                        { light = lampLight(block, defaults, lit, surge, override) })
                    -- Recorded whether or not the write was accepted: a lamp
                    -- the engine refused to rewrite must not be re-queued on
                    -- every beat for the rest of the match.
                    if ok then post.beaconLit, post.beaconSurge = lit, surge end
                    done = done + 1
                end
            end
            if post.light ~= nil and post.lightSurge ~= surgeLive then
                pcall(Open77.props.update, post.light,
                    { light = lampLight(light, LIGHT_DEFAULTS, true, surgeLive) })
                post.lightSurge = surgeLive
                done = done + 1
            end
        end
    end
    if #lampQueue == 0 then lampQueue = nil end
    return lampQueue ~= nil
end

--- The pass. Returns true while it owes work, which selects the short poll.
local function lampStep(now)
    local settings = cfg()
    local chase = settings.chase or EMPTY
    local surge = settings.surge or EMPTY
    if not propsAvailable() or type(Open77.props.update) ~= "function" then
        lampWakeAt = nil
        return false
    end
    if postCount == 0 then
        -- Nothing standing: forget any beat in flight, keep the clock for the
        -- next one, and do not wake the poll for lamps that do not exist.
        lampQueue = nil
        lampWakeAt = nil
        return false
    end

    -- THE SURGE'S CLOCK. Armed by `adoptOpen` (a net-event handler with no
    -- clock of its own) and started here on the next pass.
    if surgeArmed then
        surgeArmed = false
        if surge.enabled ~= false and now > 0.0 then
            surgeUntil = now + math.max(0.5, math.min(30.0, number(surge.seconds, 5.0)))
        end
    end
    local surging = surgeUntil ~= nil and now < surgeUntil
    if surgeUntil ~= nil and not surging then surgeUntil = nil end

    -- A beat is owed when the flare state changed, or when the chase is due.
    -- Either way, only once the previous beat has drained.
    if lampQueue == nil then
        local due = false
        if surging ~= surgeLive then
            surgeLive = surging
            due = true
            -- The flare's end restores every beacon to the CURRENT phase, so
            -- the chase starts its clock from here rather than firing a
            -- second full rewrite on the very next pass because the beat it
            -- missed during the flare is still "due".
            if not surging then
                chaseNextAt = now + chaseStep(chase, now)
            end
        elseif chase.enabled ~= false and not surgeLive and now >= chaseNextAt then
            chasePhase = (chasePhase + 1) % 2
            chaseNextAt = now + chaseStep(chase, now)
            due = true
        end
        if due then
            lampOpenBeat()
            -- The walk was the job. Draining starts next pass.
            lampWakeAt = nil
            return lampQueue ~= nil
        end
    end

    if lampQueue ~= nil then
        local budget = math.max(1, math.floor(number(chase.updatesPerTick, 4)))
        local more = lampDrain(budget)
        lampWakeAt = nil
        return more
    end

    -- Idle. Tell the poll when the next beat or the end of the flare is, so
    -- the idle interval does not stretch either.
    if surgeLive and surgeUntil ~= nil then
        lampWakeAt = surgeUntil
    elseif chase.enabled ~= false then
        lampWakeAt = chaseNextAt
    else
        lampWakeAt = nil
    end
    return false
end

--- Drain at most `budget` post operations from the retire queue, then the raise
--- queue. Retires first, deliberately: the quota a raise needs may be held by a
--- post the same diff is about to drop.
local function applyStep(budget)
    local done = 0
    while pendingRetire ~= nil and #pendingRetire > 0 and done < budget do
        retire(table.remove(pendingRetire))
        done = done + 1
    end
    if pendingRetire ~= nil and #pendingRetire == 0 then pendingRetire = nil end
    if pendingRetire ~= nil then return true end

    while pendingRaise ~= nil and #pendingRaise > 0 and done < budget do
        local key = table.remove(pendingRaise)
        local spot = plan ~= nil and plan[key] or nil
        if spot ~= nil and posts[key] == nil then raise(key, spot) end
        done = done + 1
    end
    if pendingRaise ~= nil and #pendingRaise == 0 then pendingRaise = nil end
    return pendingRaise ~= nil
end

local function stepOnce()
    local settings = cfg()

    -- THREE GATES NOW, NOT ONE, AND THEY ARE NOT THE SAME GATE.
    --
    -- `live` is "there is an armed cordon and this player is in it". `wantWall`
    -- is the PROJECTED boundary on the HUD; `wantWorld` is the entity layer.
    --
    -- Before the wall existed these were a single test on `style() == "world"`
    -- and the whole pass returned early otherwise -- which made
    -- `cordonEdge = "hud"`, the one setting with no entity cost, also the one
    -- setting with no boundary at all. Its own config comment calls it "the
    -- recorded fallback, and still a playable mode"; it was not, because nothing
    -- drew the fallback. It now means exactly what it says: the boundary on
    -- screen, nothing in the world.
    local live = participating and grid ~= nil and openList ~= nil and style() ~= "off"
    local wantWall = live and wallEnabled()
    local wantWorld = live and style() == "world"
    if wantWorld and not canDraw() then
        wantWorld = false
        warnOnce("bindings",
            "the world edge is switched on but this client offers neither " ..
            "Open77.vfx.play nor Open77.props.create -- check that the manifest " ..
            "still declares world.effects and world.props. THIS LEAVES THE MODE " ..
            "WITH NO BOUNDARY under style=world: set Config.cordon.edge.wall.enabled " ..
            "= true, or the cordonEdge tunable to \"hud\", to fall back to the " ..
            "projected wall until the bindings are back.")
    end

    -- THREE PER PASS. A post is between one and six engine calls and all of
    -- them are cheap on the Lua side -- the expensive half of a prop is the
    -- DynamicEntityService spawn, which happens on later game-thread ticks and
    -- is not charged to this resume at all. At one per pass and
    -- `workPollMs = 100`, a sixteen-post edge needed 1.6 s of walking to
    -- assemble; the owner's own client log for 2026-09-03 shows posts whose
    -- tenth percentile lifetime was 3.4 seconds, so a large part of the layer
    -- was being retired before it had finished appearing. An eighty-post plan
    -- at three per pass stands in under three seconds.
    local budget = math.max(1, math.floor(number(settings.postsPerTick, 3)))

    -- Read once per pass rather than once per branch: the wall's republish
    -- heartbeat needs it on the idle path too, and `Open77.time.monotonic` is a
    -- clock read, not an engine query.
    local now = 0.0
    if Open77 ~= nil and type(Open77.time) == "table" and
        type(Open77.time.monotonic) == "function" then
        local okNow, value = pcall(Open77.time.monotonic)
        if okNow then now = number(value, 0.0) end
    end

    if not wantWall and not wantWorld then
        local retracted = retractWall()
        if postCount > 0 or pendingRetire ~= nil then
            queueTeardown()
            return applyStep(budget)
        end
        return retracted
    end

    -- The wall is off while the world layer stays on -- which since 2026-09-03
    -- is the SHIPPED state, not an operator's edge case. Retract once, rather
    -- than letting the HUD's staleness window notice several seconds later.
    --
    -- `and wallActive` IS LOAD-BEARING, and the comment it replaces said the
    -- opposite: "retract once -- `retractWall` early-returns after that". It
    -- does not. `retractWall` sets `planRevision = -1` BEFORE its `wallActive`
    -- guard, deliberately, so that a wall coming back gets a fresh scan instead
    -- of waiting for the player to walk `refreshMetres`. Calling it on every
    -- pass therefore invalidates the plan on every pass, and the scan would
    -- reopen, re-walk the window and re-sort up to 192 candidates once a second
    -- for the whole match -- for a layer that is switched off. Nothing would
    -- LOOK wrong, because the diff keeps the posts standing; it would just burn
    -- the budget this file has already died inside twice.
    --
    -- The condition costs nothing and is exact: `wallActive` is true only while
    -- the HUD is holding a painted boundary, which is the only state a
    -- retraction is for.
    if not wantWall and wallActive then retractWall() end

    -- THE WORLD HALF SWITCHED OFF WHILE THE WALL STAYS ON. Drop the entities
    -- without touching the scan: the scan is now the WALL's input as well, and
    -- `queueTeardown` clears `scanState`, `plan` and `planX` -- so calling it
    -- here would blank the boundary as a side effect of turning off a
    -- decoration. Retires only; nothing else in this file is disturbed.
    if not wantWorld and (postCount > 0 or pendingRetire ~= nil or pendingRaise ~= nil) then
        if pendingRetire == nil then
            pendingRaise = nil
            local list = {}
            for key in pairs(posts) do list[#list + 1] = key end
            pendingRetire = list
        end
        return applyStep(budget)
    end

    -- 1. The index, in chunks, before anything reads it.
    if openIndexRevision ~= revision then
        return indexStep(math.max(16, math.floor(number(settings.indexChunk, 128))))
    end
    if openIndex == nil then return false end

    -- 2. THE WALL, on a pass of its own, and BEFORE the engine work.
    --
    --    It used to be true that finishing the picture the last scan asked for
    --    was worth more than re-deciding it. That rule was written when the
    --    picture WAS the posts. The wall is now the layer the player can
    --    actually see, it costs one queued event, and it is owed at most once
    --    per scan plus a heartbeat -- so a pass spent telling the HUD where the
    --    boundary is beats a pass spent raising a light nobody has yet proven
    --    renders.
    if wantWall and (wallDirty or (wallActive and now > 0.0 and now >= wallRepublishAt)) then
        return wallStep(now)
    end

    -- 3. Owed engine work goes before a fresh scan: finishing the picture the
    --    last scan asked for is worth more than re-deciding it.
    if pendingRetire ~= nil or pendingRaise ~= nil then
        return applyStep(budget)
    end

    -- 3b. The status line, on a pass of its own, at most every
    --     `statusIntervalMs`. It sits HERE rather than on the idle pass so that
    --     it still reports for a player who is walking -- which is most of a
    --     match, and exactly the state in which the boundary went missing.
    --     `props.list` allocates a table per prop; nothing else may share this
    --     resume with it.
    if now > 0.0 and now >= reportAt then
        reportAt = now +
            math.max(2.0, number(settings.statusIntervalMs, 15000) / 1000.0)
        pcall(report, planX, planY, planZ)
        return true
    end

    -- 4. A scan already open owns the pass. It walks a bounded number of cells,
    --    then sorts, incrementally plans, and diffs on separate passes. What
    --    is already standing is untouched throughout, so a window that takes
    --    four passes to walk does not blink the edge.
    if scanState ~= nil then
        if scanStep(math.max(4, math.floor(number(settings.scanCellsPerPass, 48)))) then
            return true
        end
        -- The sort, and the wall's input -- the sorted candidate list -- is
        -- recorded inside it whether or not anybody wants posts.
        if not scanState.sorted then
            scanSort()
            return true
        end
        -- `wantWorld` decides whether the POST plan is built.
        -- Planning used to allocate the entire dense boundary and diff it in
        -- one resume. Keep density independent of the script's per-frame
        -- deadline, and discard an unfinished planner when the scan is reset.
        local scan = scanState
        if not scan.planReady then
            if scan.planner == nil then
                -- The sandbox intentionally omits coroutine.create/resume.
                -- Host-owned threads provide the same bounded yielding while
                -- preserving resource accounting and cancellation on reload.
                scan.planner = true
                CreateThread(function()
                    local ok, result = pcall(scanFinish, wantWorld, scan)
                    if scanState ~= scan then return end
                    if not ok then
                        scanState = nil
                        planRevision = -1
                        say("warn", "edge planner: " .. tostring(result))
                    else
                        scan.plan, scan.planReady, scan.planner = result, true, nil
                    end
                end)
            end
            return true
        end
        plan = scan.plan
        scanState = nil
        if not wantWorld then
            -- No entity plan to diff. `wallDirty` is now true, so the next pass
            -- publishes; returning it keeps the poll on its short interval until
            -- it has.
            return wallDirty
        end

        -- The diff is the point: a rebuild that recreated every post would
        -- restart every particle graph and the edge would visibly strobe.
        --
        -- AND IT KEEPS WHAT IS STILL NEARBY. A post that has merely fallen out
        -- of the nearest-`maxSegments` set is not a post that is in the wrong
        -- place; retiring it destroys a light and a particle graph that were
        -- already paid for and will very likely be asked for again a few metres
        -- later. The owner's log for 2026-09-03 measured the cost of not doing
        -- this: 206 light hosts created in one session for a layer capped at
        -- sixteen, median lifetime 11.7 s, never more than NINE standing at
        -- once. Restoring the full draw radius makes that worse, not better --
        -- more segments compete for the same sixteen slots -- so the hysteresis
        -- is part of the same fix rather than a separate polish.
        local holdFactor = number(settings.holdRadiusFactor, 1.15)
        local holdSquared = (lastRadius * holdFactor) ^ 2
        local maxPosts = math.max(1, math.floor(number(settings.maxPosts, 80)))
        -- A HARD CEILING ON WHAT IS HELD, counted against the plan rather than
        -- against `postCount`, because `postCount` has not yet been reduced by
        -- the retires this same diff is about to queue. The config comment at
        -- `maxTotalPosts` does the prop and effect arithmetic against
        -- `kPerOwnerLimit` (256 props in client/src/api/Props.cpp, 64 effects in
        -- Effects.cpp); the hysteresis cannot walk the layer into a quota
        -- refusal while that arithmetic holds.
        local maxHeld = math.max(maxPosts,
            math.floor(number(settings.maxTotalPosts, maxPosts + 20)))
        local total = 0
        for _ in pairs(plan) do total = total + 1 end
        pendingRetire, pendingRaise = nil, nil
        for key, post in pairs(posts) do
            local spot = plan[key]
            if spot ~= nil then
                if (spot.wall == true) ~= (post.wall == true) or
                    (spot.next == true) ~= (post.next == true) then
                    -- STILL ON THE BOUNDARY BUT IN A DIFFERENT TIER: the player
                    -- walked toward it and the near tier reached this slot, or
                    -- walked away and it fell back to the fill -- or, since the
                    -- eighth round, THE LINE ARRIVED: the doomed cell across a
                    -- next-line side closed, and the amber lamp's key is now a
                    -- current-line post. The post has to be rebuilt -- fire
                    -- and a red lamp where amber stood -- and `applyStep`
                    -- drains every retire before it raises anything, so
                    -- queuing both under one key is safe.
                    --
                    -- STAMPED CURRENT FIRST. `retire` blasts a marker whose
                    -- revision is stale, because that is what "the cordon
                    -- swallowed it" looks like; a post rebuilt for a tier
                    -- change is still on the live boundary, and a closure
                    -- landing on the same scan must not make it explode.
                    post.rev = revision
                    pendingRetire = pendingRetire or {}
                    pendingRetire[#pendingRetire + 1] = key
                    pendingRaise = pendingRaise or {}
                    pendingRaise[#pendingRaise + 1] = key
                else
                    -- STILL ON THE BOUNDARY. Stamp it with the current cordon so
                    -- the hysteresis below keeps recognising it as current;
                    -- without this refresh a post would be dropped one closure
                    -- after the last time it was newly planned, which is churn
                    -- of the opposite sign.
                    post.rev = revision
                end
            else
                local dx, dy = post.x - planX, post.y - planY
                -- THE HYSTERESIS IS NOW BOUNDED BY THE CORDON AS WELL AS BY
                -- DISTANCE, and that second clause is a bug fix rather than a
                -- refinement.
                --
                -- The rule was "keep anything within `holdRadiusFactor` of the
                -- draw radius", i.e. within 172 m of the scan origin -- which is
                -- more or less everything the scan can see. It was written to
                -- stop a post being destroyed and respawned as the PLAYER walks,
                -- and that is a real problem it really solves. But it made no
                -- distinction between "the player moved" and "the cordon closed",
                -- so a post placed on a boundary that has since been swallowed
                -- was kept for as long as the player stayed near it.
                --
                -- Measured, in the owner's own log of 2026-09-03: `posts=40`,
                -- pinned at exactly `maxTotalPosts`, with
                -- `nearest post=(-1271.5,2039.4,11.9)` IDENTICAL across eight
                -- consecutive status lines and thirty-three cordon revisions
                -- (rev=14 through rev=47) while the open set fell from 53 cells
                -- to 22. A dozen of the forty entities were the previous
                -- cordon's boundary, holding budget against the current one --
                -- and worse, drawing a line where there is no longer any bleed,
                -- which is the one lie a boundary must never tell.
                --
                -- `holdAcrossRevisions = true` restores the old behaviour for a
                -- bisect.
                local current = post.rev == revision or
                    (settings.holdAcrossRevisions == true)
                if total < maxHeld and current and
                    (dx * dx + dy * dy) <= holdSquared then
                    total = total + 1
                    -- Put it back in the plan. `applyStep` only raises a key
                    -- whose `posts` entry is nil, so this cannot double-spawn;
                    -- it only stops the next diff from asking to retire it.
                    plan[key] = post
                else
                    pendingRetire = pendingRetire or {}
                    pendingRetire[#pendingRetire + 1] = key
                end
            end
        end
        for key in pairs(plan) do
            if posts[key] == nil then
                pendingRaise = pendingRaise or {}
                pendingRaise[#pendingRaise + 1] = key
            end
        end
        -- `wantWall and wallDirty`, not bare `wallDirty`. `scanFinish` records
        -- the wall's input on every scan whether or not anybody wants it, and
        -- only `wallStep` -- which is gated on `wantWall` -- ever clears the
        -- flag. Returning it unqualified would tell the poll there is work owed
        -- when the layer is switched off, and buy a needless fast pass after
        -- every scan for the rest of the match.
        return pendingRetire ~= nil or pendingRaise ~= nil or (wantWall and wallDirty)
    end

    -- 4b. THE LAMPS -- the chase and the surge -- on ALTERNATE idle passes.
    --    Everything above this line is the boundary itself and it always goes
    --    first: a scan, an apply or the status line owns its pass outright and
    --    the lamps wait. Down here the round-robin with step 5 is what keeps a
    --    long wall's beat from starving the "has the player moved" test for
    --    the length of a match -- one pass for the lamps, one for the scan
    --    check, and a lamp pass that finds nothing owed falls straight
    --    through to the scan check at the cost of a few integer compares.
    if not lampSkip then
        lampSkip = true
        if lampStep(now) then return true end
    else
        lampSkip = false
    end

    -- 5. A scan, but only when the cordon changed or the player has actually
    --    moved. Everything above this line is two integer comparisons.
    local ok, me = pcall(Open77.character.state)
    local here = ok and type(me) == "table" and me.position or nil
    if here == nil then
        -- Cannot tell where the player is. HOLD what is drawn rather than
        -- retiring it: an unreadable position is a gap in the client's own
        -- state, not a statement that the boundary moved, and tearing the edge
        -- down on it would make the one primitive a lost player needs blink out
        -- exactly when they most need it. The same rule the containment tick
        -- keeps on the server.
        planX, planY = nil, nil
        return false
    end

    local moved = planX == nil or
        ((here.x - planX) ^ 2 + (here.y - planY) ^ 2) >=
        (number(settings.refreshMetres, 20.0) ^ 2)
    if not moved and planRevision == revision then return false end

    planX, planY, planZ = here.x, here.y, here.z
    planRevision = revision
    scanBegin(here.x, here.y, here.z)
    return true
end

-- ---------------------------------------------------------------------------
-- WHAT THE SERVER TELLS US
-- ---------------------------------------------------------------------------

--- Adopt an open-cell list. The array is kept AS SENT rather than copied into a
--- set: the copy was 64 iterations inside a net-event handler that shares the
--- same 80 us budget as everything else, and the only consumer wants integers
--- anyway. `indexStep` converts it, in chunks, on the poll thread.
local function adoptOpen(list, doomed)
    -- THE SURGE IS ARMED HERE, and only for a cordon that REPLACES one. The
    -- first list of a match -- and the catch-up seed after a hot reload,
    -- which also arrives on a nil list -- is the cordon arming, not a block
    -- closing, and a line that flared white every time a client reloaded
    -- would teach the player to ignore the flare. This handler has no clock;
    -- `lampStep` starts the timer on the next pass.
    if openList ~= nil then surgeArmed = true end
    openList = list
    openCells = #list
    -- THE DOOMED SET rides the same message. `nil` means the message did not
    -- carry one -- the state-push seed, or an older server -- and the last
    -- one known is KEPT rather than dropped: a stale doomed cell that has
    -- since closed is not open any more and cannot produce a next-line side,
    -- so keeping it is harmless, while dropping it would blank the second
    -- line on every catch-up seed.
    if type(doomed) == "table" then
        closingList = doomed
        closingCount = #doomed
    elseif closingList == nil then
        closingList = EMPTY
        closingCount = 0
    end
    revision = revision + 1
    -- THROW AWAY A HALF-BUILT INDEX. `indexStep` walks `openList` across
    -- several passes and remembers how far it got; a closure landing mid-build
    -- replaces the array under it, and continuing from element N of a DIFFERENT
    -- list would produce an index that is part old cordon and part new -- which
    -- draws a boundary that never existed and is exactly the class of bug that
    -- is impossible to read from a screenshot. Restarting costs one closure's
    -- worth of chunks; being wrong costs a match.
    openIndexBuilding = nil
    openIndexProgress = 0
end

AddEventHandler("cordon:bounds:local", function(payload)
    if type(payload) ~= "table" then return end
    local g = payload.grid
    if type(g) == "table" and g.originX ~= nil and g.originY ~= nil then
        grid = {
            ox = number(g.originX, 0.0),
            oy = number(g.originY, 0.0),
            oz = number(g.originZ, nil),
            size = math.max(1.0, number(g.blockMetres, 100.0)),
            cols = math.max(1, math.floor(number(g.cols, 1))),
            rows = math.max(1, math.floor(number(g.rows, 1))),
        }
    end
    if type(payload.open) == "table" then adoptOpen(payload.open, payload.closing) end
    -- The live tunable, forwarded so an operator switching the edge off from
    -- the Warden panel reaches a client whose config file says otherwise.
    if type(payload.edgeStyle) == "string" then serverStyle = payload.edgeStyle end
end)

AddEventHandler("cordon:survey:local", function(payload)
    if type(payload) ~= "table" then return end
    ground.default = number(payload.groundDefault, ground.default)
    if type(payload.ground) == "table" then ground.cells = payload.ground end
    -- The survey carries the grid too, and is the one message that is complete
    -- on its own -- so a client that has a survey but has not yet seen a bounds
    -- push can still place a post. `cordon:bounds` overwrites this the moment it
    -- arrives; the open-cell list only ever comes from there.
    if grid == nil and payload.originX ~= nil and payload.originY ~= nil then
        grid = {
            ox = number(payload.originX, 0.0),
            oy = number(payload.originY, 0.0),
            oz = number(payload.originZ, nil),
            size = math.max(1.0, number(payload.blockMetres or payload.blockSize, 100.0)),
            cols = math.max(1, math.floor(number(payload.cols or payload.gridCols, 1))),
            rows = math.max(1, math.floor(number(payload.rows or payload.gridRows, 1))),
        }
    end
end)

-- The gate, and the safety net.
--
-- THE GATE. Nothing is drawn for a player watching from staging, or before the
-- cordon has armed: `C.begin` runs at the live transition and until then every
-- block is open, so a "boundary" would be the rim of the district -- true,
-- useless, and drawn straight through the deploy window. (`C.openKeys` returns
-- the WHOLE grid before the cordon arms, deliberately, so that the tac-map
-- paints an untouched district rather than a sealed one. Reading that as a
-- boundary is exactly the mistake this gate prevents.)
--
-- THE SAFETY NET. `cordon:bounds` is published ON CHANGE, which is correct and
-- has one hole: a client that misses a publish -- because this resource
-- hot-reloaded mid-match, which it does constantly during development -- has no
-- cordon at all until the NEXT block closes, and at Cordon 1 that is three
-- minutes of no boundary. The state push carries the same open-cell list every
-- 500 ms, so it is used to SEED and to catch up, never to stream: the test is
-- one integer comparison against the cell count, so the common case -- nothing
-- changed -- costs nothing.
AddEventHandler("cordon:state:local", function(payload)
    if type(payload) ~= "table" then return end
    local cordon = type(payload.cordon) == "table" and payload.cordon or nil
    participating = payload.participant == true and cordon ~= nil and cordon.active == true
    -- The live tunable, read BEFORE the early return below: an operator who
    -- switches the edge off during staging should reach the client then, not on
    -- the first closure three minutes into the match.
    if cordon ~= nil and type(cordon.edgeStyle) == "string" then
        serverStyle = cordon.edgeStyle
    end
    -- ONLY SEED FROM AN ARMED CORDON. `C.openKeys` deliberately returns the
    -- WHOLE grid while the cordon is not yet armed, so that the tac-map paints
    -- an untouched district during the deploy window rather than a sealed one.
    -- Reading that list here would both draw the district rim as a boundary and
    -- -- because the fragment's `openCells` counts the ARMED set and is zero
    -- then -- disagree with itself on every push and reseed twice a second.
    if cordon == nil or cordon.active ~= true then
        closeAtMono = nil
        return
    end

    -- THE CLOCK FOR THE HURRY. `closeInMs` is the fragment's time to the next
    -- cell closure; stamped against the local monotonic clock here (one
    -- native call per 500 ms push) so `chaseStep` can extrapolate between
    -- pushes. Absent means no timetable left -- the terminal phase has run --
    -- and the beat goes back to its idle interval.
    local closeIn = number(cordon.closeInMs, nil)
    if closeIn ~= nil then
        local now = monotonic()
        closeAtMono = now > 0.0 and (now + math.max(0.0, closeIn) / 1000.0) or nil
    else
        closeAtMono = nil
    end

    if grid == nil and cordon.originX ~= nil and cordon.originY ~= nil then
        grid = {
            ox = number(cordon.originX, 0.0),
            oy = number(cordon.originY, 0.0),
            oz = number(cordon.originZ, nil),
            size = math.max(1.0, number(cordon.blockMetres or cordon.blockSize, 100.0)),
            cols = math.max(1, math.floor(number(cordon.cols or cordon.gridCols, 1))),
            rows = math.max(1, math.floor(number(cordon.rows or cordon.gridRows, 1))),
        }
    end

    local count = math.floor(number(cordon.openCells, -1))
    if type(cordon.open) == "table" and
        (openList == nil or (count >= 0 and count ~= openCells)) then
        adoptOpen(cordon.open)
    end
end)

-- ---------------------------------------------------------------------------
-- THE POLL, AND THE WATCHDOG THAT OUTLIVES IT
--
-- `pollMs` is read on every pass rather than captured, so editing it in the
-- config takes effect on the next tick. `workPollMs` is the interval used while
-- there is engine work owed -- one post per pass at 100 ms puts sixteen posts up
-- in under two seconds, which is inside the hold before the block that produced
-- them actually closes.
--
-- THE HEARTBEAT IS NOT PARANOIA. `ResumeTask` retires a coroutine that raises,
-- and the execution-budget hook can fire in the handful of VM instructions
-- between `pcall` returning and `Wait` yielding -- outside anything this file
-- can catch. That is a ~0.5% window per overrun, and the failure it produces is
-- the exact one that cost this feature a whole session: the layer stops, in
-- silence, forever. The watchdog costs one integer compare every five seconds.
-- ---------------------------------------------------------------------------
local heartbeat = 0
local generation = 0
local restarts = 0

local function startPoll()
    generation = generation + 1
    local mine = generation
    CreateThread(function()
        while mine == generation do
            local settings = cfg()
            local ok, busy = pcall(stepOnce)
            if not ok then
                -- `busy` holds the error. Named once per distinct message, so a
                -- pathological map cannot fill the log, and the pass simply
                -- starts again after the wait below -- which is what resets the
                -- host's per-resume deadline.
                warnOnce("step:" .. tostring(busy),
                    "a rebuild pass failed and was skipped: " .. tostring(busy) ..
                    " -- if this is the execution budget, inspect the failing pass; " ..
                    "scanCellsPerPass and postsPerTick bound scan and engine work " ..
                    "in Config.cordon.edge. Planning is already incremental.")
                busy = false
            end
            heartbeat = heartbeat + 1
            local wait = busy
                and math.max(50, math.floor(number(settings.workPollMs, 100)))
                or math.max(100, math.floor(number(settings.pollMs, 1000)))
            -- THE LAMPS' ALARM CLOCK. An idle pass is a second apart, and the
            -- chase beats every 800 ms; without this the beat would land on
            -- whichever idle pass came next and read as a lamp that flickers
            -- at random. `lampStep` says when the next beat (or the end of a
            -- flare) is due; the idle wait is shortened to reach it, and never
            -- below the busy interval.
            if not busy and lampWakeAt ~= nil then
                local now = monotonic()
                if now > 0.0 then
                    wait = math.max(100, math.min(wait,
                        math.floor((lampWakeAt - now) * 1000.0)))
                end
            end
            Wait(wait)
        end
    end)
end

CreateThread(function()
    local seen = -1
    while true do
        Wait(5000)
        if heartbeat == seen then
            restarts = restarts + 1
            -- Only the first few, then silence: a client that cannot run this
            -- loop at all must not turn its own log into the reason.
            if restarts <= 3 then
                say("warn", ("the poll thread stopped (restart %d). The host retires a " ..
                    "coroutine that raises; see the execution-budget note at the top of " ..
                    "this file."):format(restarts))
            end
            startPoll()
        end
        seen = heartbeat
    end
end)

startPoll()

say("info", ("loaded, style=%s wall=%s (server has not spoken yet; %s wins once " ..
    "it does). TWO LINES. The current boundary: on the nearest wallPosts slots, " ..
    "FIRE on the even slots and a knee-high red LAMP on the odd ones that CHASES, " ..
    "quickening as the closure nears, with the orange STRIP across the line; beyond " ..
    "that, a LAMP every fillStride-th slot; and every segment's middle slot is a " ..
    "MARKER with a FIRE, the big red LIGHT on the closed side and (unverified) a " ..
    "BLAZE. The next boundary -- the zone that survives the announced phase -- in " ..
    "AMBER lamps. A closure SURGES every lamp white-hot, blasts the swallowed " ..
    "markers, and rebuilds the amber posts it reaches as the line. Hesco, roadblock " ..
    "and container are off in the config. The projected wall is published to " ..
    "open77_cordon_hud as cordon:edge:wall and is the boundary under style=hud only.")
    :format(tostring(style()), tostring(wallEnabled()), "cordon:bounds.edgeStyle"))

-- A resource stop does NOT need to take its own props and effects with it: the
-- host already does. `ResourceHost::StopResource` calls `releaseProps` and
-- `releaseEffects` with this resource's name (scripting/src/ResourceHost.cpp,
-- the two calls beside the `releaseProps` note), which is `Api::Props::Release`
-- and `Api::Effects::Release` on the client.
--
-- So this handler drops BOOKKEEPING ONLY, and makes no engine calls at all --
-- deliberately. Sixteen posts is up to thirty-two `remove` calls, and an event
-- handler gets the same 80 us as everything else: the tidy-up that used to live
-- here would have been the second place in this file capable of raising the
-- budget error, on the way out, for no benefit.
AddEventHandler("onClientResourceStop", function(name)
    if name ~= RESOURCE then return end
    generation = generation + 1     -- stops the poll thread on its next pass
    posts, postCount = {}, 0
    plan, pendingRaise, pendingRetire = nil, nil, nil
    scanState = nil
    -- The seventh round's bookkeeping. The host releases the handles; these
    -- are the counts and queues that would otherwise describe them.
    effectCount, blasts, blastCount = 0, {}, 0
    lampQueue, lampWakeAt = nil, nil
    surgeUntil, surgeArmed, surgeLive = nil, false, false
    -- The eighth round's bookkeeping: the doomed set and the hurry clock.
    closingList, closingCount, closingIndex, closingIndexBuilding = nil, 0, nil, nil
    closeAtMono = nil
    -- RETRACT THE WALL ON THE WAY OUT. This is the one call in this handler and
    -- it is NOT an engine call -- `TriggerEvent` pushes onto the host's own
    -- event queue -- so the rule above (no engine work on the stop path) holds.
    -- Without it the HUD keeps the last boundary painted for its whole staleness
    -- window, and this resource hot-reloads constantly during development, so
    -- that window would be visible several times an hour. `pcall` because a stop
    -- handler that raises takes the rest of the teardown with it.
    wallActive, wallPayload, wallDirty = false, nil, false
    wallCandidates, wallCandidateCount, wallPanels = nil, 0, 0
    pcall(TriggerEvent, "cordon:edge:wall",
        { rev = 0, stride = 5, panels = 0, points = {} })
end)
