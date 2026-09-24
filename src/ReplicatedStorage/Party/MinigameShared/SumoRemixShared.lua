--!strict
-- SumoRemixShared.lua: Sumo Remix rules shared by the server (authoritative) and the client (prediction + visuals).
-- Units: UU, sim axes (x across, y along, z up). Played on the standard arena floor, no ball, no boost pads.
--
-- A circular safe zone shrinks in phases. Each phase: WARN seconds with the next zone announced (drawn on the floor),
-- then SHRINK seconds while the zone slides/shrinks into it, then the CHECK: every car whose hitbox is fully outside
-- the zone (centre farther than radius + TOLERANCE) is eliminated. Last car standing wins.
local SR = {}

SR.Id = "sumo_remix"
SR.R0 = 2600 -- starting zone radius
SR.RADII = { 1900, 1400, 1000, 700, 450 } -- zone radius after each phase
SR.WARN = 8 -- s the next zone is shown before it starts closing
SR.SHRINK = 4 -- s it takes to close
SR.PHASE = SR.WARN + SR.SHRINK
SR.TOLERANCE = 75 -- uu: about half a car; a car is out only when its centre is this far past the edge
SR.MAX_TIME = SR.PHASE * #SR.RADII + 6 -- 66 s
SR.BOOST_REGEN = 22 -- boost per second (no pads)
SR.CREDIT_WINDOW = 3 -- s: who bumped you last within this window gets the elimination
SR.FLOOR_LIMIT = Vector2.new(3300, 4300) -- zone centres stay on the flat floor

function SR.WorldOptions(): any
	return { boostPads = false, seed = 1 }
end

-- starting ring, facing the centre
function SR.SpawnSlots(n: number): { { pos: Vector3, yaw: number } }
	local out = {}
	for i = 1, n do
		local a = (i - 1) / n * math.pi * 2 + math.pi / 4
		local p = Vector3.new(math.cos(a) * 1500, math.sin(a) * 1500, 17)
		table.insert(out, { pos = p, yaw = math.atan2(-p.Y, -p.X) })
	end
	return out
end

-- zone at time t of phase k (t from the phase start). zones = { {c, r}, ... } with zones[1] the starting zone
function SR.ZoneAt(zones: { any }, k: number, t: number): (Vector2, number)
	local a, b = zones[k], zones[k + 1] or zones[k]
	local s = math.clamp((t - SR.WARN) / SR.SHRINK, 0, 1)
	s = s * s * (3 - 2 * s)
	return a.c:Lerp(b.c, s), a.r + (b.r - a.r) * s
end

function SR.Outside(p: Vector3, c: Vector2, r: number): boolean
	return (Vector2.new(p.X, p.Y) - c).Magnitude > r + SR.TOLERANCE
end

-- boost refills only while the car sits on the floor (wheels down on a flat surface): no refilling in the air or
-- riding a wall, so a boosted ram is a choice you pay for
function SR.OnFloor(car: any): boolean
	return (car.numWheelsInContact or 0) >= 3 and car.body.up.Z > 0.8
end

function SR.PreTick(car: any, dt: number)
	if SR.OnFloor(car) then
		car.boost = math.min(100, (car.boost or 0) + SR.BOOST_REGEN * dt)
	end
end

return SR
