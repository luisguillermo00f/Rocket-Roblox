--!strict
-- KingOfTheHillShared.lua: King of the Hill rules shared by the server (authoritative) and the client (prediction +
-- visuals). Units: UU, sim axes (x across, y along, z up). Standard arena floor, no ball, no pads.
--
-- A circular hill sits on the floor and jumps to a new spot every HILL_TIME seconds (the next spot is announced
-- NEXT_WARN seconds before). Only a car that is ALONE on the hill earns control time; two or more = contested,
-- nobody earns. Most control time wins.
local KH = {}

KH.Id = "king_of_the_hill"
KH.HILLS = 5
KH.HILL_TIME = 14
KH.NEXT_WARN = 5
KH.MAX_TIME = KH.HILLS * KH.HILL_TIME -- 70 s
KH.RADIUS = 650
KH.TOLERANCE = 40 -- the car's centre may be this far past the edge and still count
KH.MAX_HEIGHT = 350 -- a car must be on (or just above) the floor to hold the hill
KH.BOOST_REGEN = 22
KH.MIN_HOP = 2400 -- the next hill is at least this far from the current one

-- candidate spots on the flat floor
KH.SPOTS = {
	Vector2.new(0, 0), Vector2.new(-2200, -2600), Vector2.new(2200, -2600), Vector2.new(-2200, 2600),
	Vector2.new(2200, 2600), Vector2.new(0, -3400), Vector2.new(0, 3400), Vector2.new(-2600, 0), Vector2.new(2600, 0),
}

function KH.WorldOptions(): any
	return { boostPads = false, seed = 1 }
end

function KH.SpawnSlots(n: number): { { pos: Vector3, yaw: number } }
	local out = {}
	for i = 1, n do
		local a = (i - 1) / n * math.pi * 2 + math.pi / 4
		local p = Vector3.new(math.cos(a) * 2600, math.sin(a) * 3000, 17)
		table.insert(out, { pos = p, yaw = math.atan2(-p.Y, -p.X) })
	end
	return out
end

function KH.OnHill(p: Vector3, c: Vector2): boolean
	return p.Z <= KH.MAX_HEIGHT and (Vector2.new(p.X, p.Y) - c).Magnitude <= KH.RADIUS + KH.TOLERANCE
end

function KH.PreTick(car: any, dt: number)
	car.boost = math.min(100, (car.boost or 0) + KH.BOOST_REGEN * dt)
end

return KH
