--!strict
-- BeachVolleyShared.lua: court geometry, net, ball override values and per-tick rules shared by the server
-- (authoritative) and the client (prediction + visuals). Units: UU, sim axes (x across, y along, z up).
-- The court sits in the middle of the standard Soccar arena; team A (team 0) defends y < 0, team B (team 1) y > 0.
local RS = game:GetService("ReplicatedStorage")
local Override = require(RS.Party:WaitForChild("MinigamePhysicsOverride"))
local C = require(RS.Physics.PhysicsConstants)

local BV = {}

BV.Id = "beach_volley"
BV.COURT_HX = 1700 -- half width (x)
BV.COURT_HY = 2600 -- depth of each half (y), net at y = 0
BV.NET_TOP = 220 -- top of the net (UU above the floor): ~ a single-jump car height
-- "volley touch" rule (this minigame only, applied by the server after the physics step): a car touch sends the
-- ball up at least TOUCH_LIFT uu/s, so an honest jump into it clears the net instead of drilling it
BV.TOUCH_LIFT = 560
BV.TOUCH_MAX_H = 1900 -- and caps its horizontal speed (uu/s) so a touch can't leave the arena like a rocket
BV.NET_HALF_THICK = 10
BV.CAR_WALL_HALF_THICK = 30

-- Per-world solids (never global). The net stops the ball (and anything under 280 uu); an invisible wall above it
-- stops cars from crossing to the other half (it does not touch the ball).
function BV.Solids(): { any }
	return {
		{ kind = "box", c = Vector3.new(0, 0, BV.NET_TOP / 2), h = Vector3.new(4300, BV.NET_HALF_THICK, BV.NET_TOP / 2), ball = true, car = true },
		{ kind = "box", c = Vector3.new(0, 0, 1150), h = Vector3.new(4300, BV.CAR_WALL_HALF_THICK, 1150), ball = false, car = true },
	}
end

function BV.WorldOptions(): any
	return { boostPads = false, extraSolids = BV.Solids(), seed = 1 }
end

-- BeachVolleyBallPhysics: a lighter, floatier ball, applied only to the minigame's own World instance.
-- Standard ball: 30 kg, gravity 650 uu/s^2, drag 0.03, floor restitution 0.6.
-- Volley ball: ~0.55 g (hang time ~1.35x longer, a jump touch lifts it well over the net), a bit more drag so hard
-- hits don't cross the whole court like a rocket, softer bounces (0.5), and 2/3 of the mass.
BV.BALL_OVERRIDE = {
	gravityScale = 0.55,
	linearDamping = 0.1,
	restitution = 0.5,
	massScale = 2 / 3,
}

BV.BALL_RADIUS = 91.25
BV.REGULATION_TIME = 60
BV.MAX_TIME = 80
BV.WIN_POINTS = 5
BV.BOOST_REGEN = 25 -- boost per second (no pads on the beach)

function BV.SideSign(team: number): number
	return if team == 0 then -1 else 1
end

-- the half a y coordinate belongs to
function BV.SideOf(y: number): number
	return if y < 0 then 0 else 1
end

function BV.InCourt(p: Vector3): boolean
	-- "fully out" means the ball's centre is beyond the line by more than its radius (touching the line is in)
	return math.abs(p.X) <= BV.COURT_HX + BV.BALL_RADIUS and math.abs(p.Y) <= BV.COURT_HY + BV.BALL_RADIUS
end

-- start positions for a team with n players (UU) and their yaw
function BV.HomeSlots(team: number, n: number): { { pos: Vector3, yaw: number } }
	local s = BV.SideSign(team)
	local xs = if n <= 1 then { 0 } elseif n == 2 then { -650, 650 } else { -900, 0, 900 }
	local out = {}
	for i = 1, n do
		table.insert(out, { pos = Vector3.new(xs[i] or 0, s * 1900, 17), yaw = if team == 0 then math.pi / 2 else -math.pi / 2 })
	end
	return out
end

function BV.ServePos(team: number): Vector3
	return Vector3.new(0, BV.SideSign(team) * 1150, 760)
end

-- the volley ball, on this world only (server session world and each client's prediction world)
function BV.SetupWorld(world: any)
	Override.ApplyBall(world, BV.BALL_OVERRIDE)
end

-- the volley touch rule: after a car touch the ball leaves upward at least TOUCH_LIFT and no faster than
-- TOUCH_MAX_H horizontally. Only this world's ball, only on touches; the physics modules are untouched.
function BV.VolleyTouch(world: any)
	local BT = C.BT_TO_UU
	local bb = world.ball.body
	local v = bb.vel * BT
	local h = Vector3.new(v.X, v.Y, 0)
	if h.Magnitude > BV.TOUCH_MAX_H then
		h = h.Unit * BV.TOUCH_MAX_H
	end
	bb.vel = Vector3.new(h.X, h.Y, math.max(v.Z, BV.TOUCH_LIFT)) / BT
end

-- after every world:Step during a rally (server and client prediction alike)
function BV.PostStep(world: any, live: boolean)
	if not live then return end
	for _, e in world.events do
		if e.type == "hit" then
			BV.VolleyTouch(world)
		end
	end
end

-- runs on every car before every world:Step, on the server and in the client's prediction
function BV.PreTick(car: any, dt: number)
	car.boost = math.min(100, (car.boost or 0) + BV.BOOST_REGEN * dt)
end

return BV
