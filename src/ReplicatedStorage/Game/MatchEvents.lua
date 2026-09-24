--!strict
-- MatchEvents.lua: turns raw world events into RL-style match bookkeeping.
--   * scoreboard for EVERY car: points, goals, assists, saves, shots (self.board[car])
--   * HUD feedback for the local player: stat toasts with points, hit-speed popups, pinches, boost pickups
--   * goal info for the banner: scorer / assist cars, ball speed
-- Pure game-side bookkeeping; it never touches the simulation.
-- Units: UU (sim axes: blue attacks +Y, orange attacks -Y).
local C = require(script.Parent.Parent.Physics.PhysicsConstants)
local ArenaCollision = require(script.Parent.Parent.Physics.ArenaCollision)
local CarPhysics = require(script.Parent.Parent.Physics.CarPhysics)

local MatchEvents = {}
MatchEvents.__index = MatchEvents

local BT = 50
local GOAL_Y = 5120
local GOAL_HALF_W = 893 + 60
local GOAL_H = 642
local GRAVITY = 650
local KMH = 0.036 -- uu/s (cm/s) -> km/h
local TOUCH_DEBOUNCE = 12 -- ticks

-- Pinch: the ball is squeezed between the car and a surface (floor / wall / ceiling / another car) and leaves fast.
-- The physics is untouched (1:1 RocketSim); this only detects and rewards it (local player only).
local PINCH_MIN_SPEED = 2600 -- uu/s after the squeeze (~94 km/h)
local PINCH_MIN_GAIN = 800 -- uu/s gained by the squeeze
local PINCH_CONTACT = 91.25 + 12 -- ball-surface distance that counts as touching
local PINCH_BASE = 60

local POINTS = { goal = 100, assist = 50, shot = 20, save = 50, epicSave = 75, clear = 20, aerial = 10, demo = 25, aerialGoal = 25, longGoal = 25 }

-- goal sign a team shoots at
local function attackSign(team: number): number
	return if team == 0 then 1 else -1
end

-- Ballistic check (floor bounces, no walls): does the ball reach the goal mouth at y = sign*GOAL_Y within 3 s?
local function headingInto(p: Vector3, v: Vector3, sign: number): (boolean, number)
	if v.Y * sign < 80 then
		return false, math.huge
	end
	local t = (sign * GOAL_Y - p.Y) / v.Y
	if t < 0 or t > 3 then
		return false, math.huge
	end
	if math.abs(p.X + v.X * t) > GOAL_HALF_W then
		return false, math.huge
	end
	local z, vz, left = p.Z, v.Z, t
	for _ = 1, 4 do
		local a, b, c = -0.5 * GRAVITY, vz, z - 92
		local disc = b * b - 4 * a * c
		local tf = if disc >= 0 then (-b - math.sqrt(disc)) / (2 * a) else math.huge
		if tf >= left or tf <= 1e-3 then
			z = z + vz * left - 0.5 * GRAVITY * left * left
			break
		end
		left -= tf
		vz = -(vz - GRAVITY * tf) * 0.6
		z = 92
	end
	return z < GOAL_H, t
end

function MatchEvents.new(world: any, player: any)
	local self = setmetatable({}, MatchEvents)
	self.world = world
	self.player = player
	self.points = 0
	-- career stats for this match (sent to the profile at the end)
	self.stats = { goals = 0, assists = 0, saves = 0, epicSaves = 0, shots = 0, clears = 0, demos = 0, aerials = 0, bestKmh = 0, pinches = 0, bestPinchKmh = 0 }
	-- scoreboard for every car
	self.board = {}
	for _, car in world.cars do
		self.board[car] = { points = 0, goals = 0, assists = 0, saves = 0, shots = 0 }
	end
	self:Reset()
	return self
end

function MatchEvents:Reset()
	self.lastTouch = {} -- [car] = tick
	self.touches = {} -- ordered list of { car, tick, pos, aerial, ownDist }
	self.pending = {}
end

function MatchEvents:Board(car: any): { [string]: number }
	local b = self.board[car]
	if not b then
		b = { points = 0, goals = 0, assists = 0, saves = 0, shots = 0 }
		self.board[car] = b
	end
	return b
end

local function ballState(world: any): (Vector3, Vector3)
	return world.ball.body.pos * BT, world.ball.body.vel * BT
end

-- out: list of HUD events. Call once per sim tick after world:Step().
function MatchEvents:Tick(out: { any }, unlimitedBoost: boolean)
	local world, player = self.world, self.player
	local tick = world.tickCount
	local bp, bv = ballState(world)

	-- award to any car; scoreboard always, HUD toast + profile stats only for the local player
	local function award(car: any, title: string, pts: number, boardStat: string?, profileStat: string?)
		local b = self:Board(car)
		b.points += pts
		if boardStat then b[boardStat] += 1 end
		if car == player then
			self.points += pts
			if profileStat then self.stats[profileStat] += 1 end
			table.insert(out, { kind = "toast", title = title, points = pts, color = "team", total = self.points })
		end
	end

	for _, e in world.events do
		if e.type == "hit" then
			local car = e.car
			local last = self.lastTouch[car]
			self.lastTouch[car] = tick
			if not last or tick - last > TOUCH_DEBOUNCE then
				local ownSign = -attackSign(car.team)
				local pre = self.preVel or bv
				local wasShotOnOwn, tOwn = headingInto(bp, pre, ownSign)
				-- squeeze geometry: is the car pushing the ball into a surface or into another car?
				local surface = nil
				if car == player then
					local carC = CarPhysics.GetHitboxCenter(car) * BT
					local push = bp - carC
					push = if push.Magnitude > 1e-3 then push.Unit else Vector3.zAxis
					local d, n = ArenaCollision.Query(bp)
					if d <= PINCH_CONTACT and push:Dot(n) < -0.25 then
						local onWall = (car.numWheelsInContact or 0) > 0 and math.abs(n.Z) < 0.5
						surface = if n.Z > 0.7 then "PISO" elseif n.Z < -0.7 then "TECHO" elseif onWall then "KUXIR" else "PARED"
					end
					for other, t2 in self.lastTouch do
						if other ~= car and tick - t2 <= 4 then
							local oc = CarPhysics.GetHitboxCenter(other) * BT
							if (bp - oc):Dot(bp - carC) < 0 then
								surface = if other.team == car.team then "EQUIPO" else "CARROS"
							end
						end
					end
				end
				local touch = {
					car = car, tick = tick, pos = bp,
					aerial = (car.numWheelsInContact or 0) == 0 and bp.Z > 300,
					ownDist = math.abs(ownSign * GOAL_Y - bp.Y),
					threat = wasShotOnOwn, threatT = tOwn,
					pinchSurface = surface, preSpeed = pre.Magnitude,
				}
				table.insert(self.touches, touch)
				if #self.touches > 16 then table.remove(self.touches, 1) end
				table.insert(self.pending, touch)
			end
		elseif e.type == "demo" then
			award(e.bumper, "¡DEMOLICIÓN!", POINTS.demo, nil, "demos")
			if e.victim == player then
				table.insert(out, { kind = "toast", title = "DEMOLIDO", points = 0, color = "bad", total = self.points })
			end
		elseif e.type == "pad" and e.car == player and not unlimitedBoost then
			table.insert(out, { kind = "pad", big = e.pad.isBig, amount = if e.pad.isBig then 100 else 12 })
		elseif e.type == "goal" then
			local team = e.team
			local scorer, scorerTouch = nil, nil
			for i = #self.touches, 1, -1 do
				local t = self.touches[i]
				if t.car.team == team then
					scorer, scorerTouch = t.car, t
					break
				end
			end
			local last = self.touches[#self.touches]
			local ownGoal = last ~= nil and last.car.team ~= team
			local kmh = math.floor(bv.Magnitude * KMH + 0.5)
			local assist = nil
			if scorer and not ownGoal then
				award(scorer, "¡GOL!", POINTS.goal, "goals", "goals")
				if scorerTouch.aerial then award(scorer, "GOL AÉREO", POINTS.aerialGoal) end
				if math.abs(attackSign(team) * GOAL_Y - scorerTouch.pos.Y) > 4500 then award(scorer, "GOL DE LEJOS", POINTS.longGoal) end
				-- assist: a different teammate touched it within 5 s before the scoring touch
				for i = #self.touches, 1, -1 do
					local t = self.touches[i]
					if t.car ~= scorer and t.car.team == team and t.tick < scorerTouch.tick and scorerTouch.tick - t.tick < 120 * 5 then
						assist = t.car
						award(t.car, "ASISTENCIA", POINTS.assist, "assists", "assists")
						break
					end
				end
			end
			local who
			if ownGoal and last.car == player then
				who = "autogol"
				table.insert(out, { kind = "toast", title = "AUTOGOL", points = 0, color = "bad", total = self.points })
			elseif scorer == player and not ownGoal then
				who = "you"
			else
				who = if team == player.team then "team" else "rival"
			end
			table.insert(out, { kind = "goal", team = team, kmh = kmh, who = who, scorer = if ownGoal then nil else scorer, assist = assist, ownGoal = ownGoal, ownGoalBy = if ownGoal then last.car else nil })
			self.pending = {}
		end
	end

	-- judge touches 3 ticks later, once the hit impulse is in the ball
	for i = #self.pending, 1, -1 do
		local t = self.pending[i]
		if tick - t.tick >= 3 then
			table.remove(self.pending, i)
			local car = t.car
			local mine = car == player
			local kmh = bv.Magnitude * KMH
			if mine then
				self.stats.bestKmh = math.max(self.stats.bestKmh, math.floor(kmh + 0.5))
				local hitEv = { kind = "hit", pos = bp, kmh = math.floor(kmh + 0.5), strong = kmh > 75 }
				table.insert(out, hitEv)
				local speed = bv.Magnitude
				if t.pinchSurface and speed >= PINCH_MIN_SPEED and speed - t.preSpeed >= PINCH_MIN_GAIN then
					local st = self.stats
					st.pinches += 1
					local kmhI = math.floor(kmh + 0.5)
					st.bestPinchKmh = math.max(st.bestPinchKmh, kmhI)
					local mult = 1 + 0.5 * (st.pinches - 1)
					local pts = math.floor((PINCH_BASE + math.max(0, kmh - 90) * 1.5) * mult + 0.5)
					local names = { PISO = "PINCH DE PISO", PARED = "PINCH DE PARED", TECHO = "PINCH DE TECHO", KUXIR = "¡KUXIR PINCH!", CARROS = "PINCH ENTRE CARROS", EQUIPO = "TEAM PINCH" }
					local title = names[t.pinchSurface] or "PINCH"
					if st.pinches > 1 then title ..= string.format("  ×%s", if mult % 1 == 0 then tostring(mult) else string.format("%.1f", mult)) end
					award(car, title, pts)
					hitEv.quiet = true -- the PINCH stamp shows the speed
					table.insert(out, { kind = "pinch", kmh = kmhI, surface = t.pinchSurface, count = st.pinches, mult = mult, points = pts })
				end
			end
			local atk = attackSign(car.team)
			local onTarget = headingInto(bp, bv, atk)
			local stillIn = headingInto(bp, bv, -atk)
			if t.threat and not stillIn then
				if t.threatT < 0.6 or t.ownDist < 900 then
					award(car, "¡ATAJADA ÉPICA!", POINTS.epicSave, "saves", "epicSaves")
					if mine then self.stats.saves += 1 end
				else
					award(car, "¡ATAJADA!", POINTS.save, "saves", "saves")
				end
			elseif onTarget then
				award(car, "TIRO A PUERTA", POINTS.shot, "shots", "shots")
			elseif t.ownDist < 1800 and bv.Y * atk > 900 then
				award(car, "DESPEJE", POINTS.clear, nil, "clears")
			end
			if t.aerial then
				award(car, "GOLPE AÉREO", POINTS.aerial, nil, "aerials")
			end
		end
	end
	-- velocity before the next tick's contacts (used as the pre-hit state of a new touch)
	self.preVel = bv
end

MatchEvents.KMH = KMH
return MatchEvents
