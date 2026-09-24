--!strict
-- PhysicsTests.lua
-- Automated acceptance tests. Reference values come from RocketSim 2.2.1 / RLBot measurements of Rocket League.
-- Run: require(game.ReplicatedStorage.Physics.PhysicsTests).RunAll()  (works in Edit mode, no Play needed)
local C = require(script.Parent.PhysicsConstants)
local World = require(script.Parent.World)
local CarPhysics = require(script.Parent.CarPhysics)
local BallPhysics = require(script.Parent.BallPhysics)
local CarConfig = require(script.Parent.CarConfig)
local FixedStep = require(script.Parent.FixedStep)
local Q = require(script.Parent.Quaternion)
local BallPrediction = require(script.Parent.BallPrediction)

local BT, UU = C.BT_TO_UU, C.UU_TO_BT
local Tests = {}
local list: { { name: string, fn: () -> (boolean, string) } } = {}

local function test(name: string, fn: () -> (boolean, string))
	table.insert(list, { name = name, fn = fn })
end

local function near(a: number, b: number, tol: number): boolean
	return math.abs(a - b) <= tol
end

-- A car alone in the arena, far from the ball, settled on its wheels.
local function carWorld(pos: Vector3?, yaw: number?, config: any?)
	local w = World.new({ boostPads = false })
	BallPhysics.SetState(w.ball, Vector3.new(3500, 4500, C.BALL_REST_Z), Vector3.zero, Vector3.zero)
	local car = w:AddCar(0, config)
	CarPhysics.ResetState(car, pos or Vector3.new(0, -3000, 17), yaw or math.pi / 2, 100, true)
	w:Step(60)
	return w, car
end

local function ballWorld(pos: Vector3, vel: Vector3, angVel: Vector3?)
	local w = World.new({ boostPads = false })
	BallPhysics.SetState(w.ball, pos, vel, angVel or Vector3.zero)
	return w
end

local function speed(car: any): number
	return car.body.vel.Magnitude * BT
end

-- Drive straight holding a target speed (throttle/boost bang-bang)
local function holdSpeed(w: any, car: any, target: number, steer: number, ticks: number)
	for _ = 1, ticks do
		local v = car.body.vel:Dot(car.body.fwd) * BT
		car.controls.throttle = if v < target then 1 else 0
		car.controls.boost = target > 1410 and v < target
		car.boost = 100
		car.controls.steer = steer
		w:Step()
	end
end

-- ================= BALL =================
test("BallRestHeight", function()
	local w = ballWorld(Vector3.new(0, 0, 300), Vector3.new(0, 0, -1e-3))
	w:Step(120 * 6)
	local z = w.ball.body.pos.Z * BT
	return near(z, C.BALL_REST_Z, 0.5), string.format("rest z %.2f (RL %.2f)", z, C.BALL_REST_Z)
end)

test("BallGravityAndDrag", function()
	-- free flight: vz(t) with Bullet damping (1-0.03)^dt applied every tick before gravity
	local w = ballWorld(Vector3.new(0, 0, 1500), Vector3.new(1000, 0, 0))
	w:Step(120)
	local v = w.ball.body.vel * BT
	local vzRef, vxRef = 0, 1000
	for _ = 1, 120 do
		vzRef = vzRef * (1 - C.BALL_DRAG) ^ C.TICK_TIME + C.GRAVITY_Z * C.TICK_TIME
		vxRef = vxRef * (1 - C.BALL_DRAG) ^ C.TICK_TIME
	end
	return near(v.Z, vzRef, 0.5) and near(v.X, vxRef, 0.5), string.format("vz %.2f (ref %.2f) vx %.2f (ref %.2f)", v.Z, vzRef, v.X, vxRef)
end)

test("BallBounceRestitution", function()
	local w = ballWorld(Vector3.new(0, 0, 1000), Vector3.new(0, 0, -1e-3))
	local ratios = {}
	for _ = 1, 120 * 8 do
		local before = w.ball.body.vel.Z * BT
		w:Step()
		local after = w.ball.body.vel.Z * BT
		if before < -50 and after > 0 then
			table.insert(ratios, after / -before)
		end
	end
	local ok = #ratios >= 3
	for _, r in ratios do
		ok = ok and near(r, C.BALL_RESTITUTION, 0.02)
	end
	return ok, string.format("%d bounces, first e=%.3f", #ratios, ratios[1] or -1)
end)

test("BallSlideToRoll", function()
	-- a sliding ball picks up topspin from friction (mu 0.35) until w*R = v
	local w = ballWorld(Vector3.new(0, 0, C.BALL_REST_Z), Vector3.new(400, 0, 0))
	w:Step(120 * 3)
	local b = w.ball.body
	local v = b.vel.Magnitude * BT
	local rollV = b.angVel.Magnitude * C.BALL_COLLISION_RADIUS_SOCCAR
	return near(v, rollV, 5) and b.angVel.Y > 0, string.format("v %.1f, w*R %.1f", v, rollV)
end)

test("BallWallBounce", function()
	local w = ballWorld(Vector3.new(3000, 0, 1000), Vector3.new(2000, 0, 0))
	for _ = 1, 120 do
		w:Step()
		if w.ball.body.vel.X < 0 then
			break
		end
	end
	local vx = w.ball.body.vel.X * BT
	return near(vx, -2000 * 0.6, 60), string.format("vx after side wall %.0f (expect ~%d)", vx, -1200)
end)

test("BallCornerBounceAveragedNormal", function()
	-- into the 45 deg corner: must come back out along the corner normal
	local w = ballWorld(Vector3.new(3000, 3800, 1000), Vector3.new(1500, 1500, 0))
	w:Step(90)
	local v = w.ball.body.vel * BT
	return v.X < 0 and v.Y < 0 and near(v.X, v.Y, 60), string.format("v after corner (%.0f, %.0f)", v.X, v.Y)
end)

test("BallMaxSpeed", function()
	local w = ballWorld(Vector3.new(0, 0, 1000), Vector3.new(9000, 0, 0))
	w:Step()
	local s = w.ball.body.vel.Magnitude * BT
	return s <= C.BALL_MAX_SPEED + 0.5, string.format("speed %.1f", s)
end)

-- ================= CAR: GROUND =================
test("CarRestHeight", function()
	local _, car = carWorld()
	local z = car.body.pos.Z * BT
	return near(z, C.CAR_SPAWN_REST_Z, 0.5) and car.numWheelsInContact == 4, string.format("rest z %.2f (RL 17.00), wheels %d", z, car.numWheelsInContact)
end)

test("AllHitboxesSettle", function()
	local msgs = {}
	local ok = true
	for _, cfg in CarConfig.All do
		local _, car = carWorld(nil, nil, cfg)
		local z = car.body.pos.Z * BT
		local good = car.numWheelsInContact == 4 and car.body.up.Z > 0.999 and car.body.vel.Magnitude * BT < 1
		ok = ok and good
		table.insert(msgs, string.format("%s z=%.1f", cfg.name, z))
	end
	return ok, table.concat(msgs, ", ")
end)

test("ThrottleTopSpeed", function()
	local w, car = carWorld()
	car.controls.throttle = 1
	w:Step(120 * 4)
	local s = speed(car)
	return near(s, 1410, 3), string.format("%.1f (RL 1410)", s)
end)

test("ThrottleAccelCurve", function()
	-- RL: a = 1600 at rest (4 wheels), falling to 160 at 1400
	local w, car = carWorld()
	car.controls.throttle = 1
	w:Step(2) -- engine force is applied one tick late (RocketSim)
	local v0 = speed(car)
	w:Step(12)
	local a = (speed(car) - v0) / (12 * C.TICK_TIME)
	return near(a, 1600 * (1 - 0.9 * ((v0 + speed(car)) / 2) / 1400), 40), string.format("accel %.0f uu/s^2 near rest", a)
end)

test("BoostTopSpeedAndSupersonic", function()
	local w, car = carWorld(Vector3.new(0, -4500, 17))
	car.controls.throttle = 1
	car.controls.boost = true
	local tSuper = nil
	for i = 1, 120 * 3 do
		car.boost = 100
		w:Step()
		if not tSuper and car.isSupersonic then
			tSuper = speed(car)
		end
	end
	return near(speed(car), 2300, 1) and tSuper ~= nil and tSuper >= 2200, string.format("top %.1f, supersonic at %.0f", speed(car), tSuper or -1)
end)

test("BoostConsumption", function()
	local w, car = carWorld()
	car.boost = 100
	car.controls.boost = true
	w:Step(120)
	return near(car.boost, 100 - C.BOOST_USED_PER_SECOND, 0.5), string.format("boost left %.2f after 1 s (RL 66.67)", car.boost)
end)

test("BrakeDecel", function()
	local w, car = carWorld()
	holdSpeed(w, car, 1400, 0, 300)
	car.controls.throttle = -1
	car.controls.boost = false
	w:Step(2)
	local v0 = car.body.vel:Dot(car.body.fwd) * BT
	w:Step(24)
	local a = (v0 - car.body.vel:Dot(car.body.fwd) * BT) / (24 * C.TICK_TIME)
	return near(a, 3500, 60), string.format("brake decel %.0f (RL 3500)", a)
end)

test("CoastDecel", function()
	local w, car = carWorld()
	holdSpeed(w, car, 1000, 0, 240)
	car.controls.throttle = 0
	w:Step(2)
	local v0 = speed(car)
	w:Step(24)
	local a = (v0 - speed(car)) / (24 * C.TICK_TIME)
	return near(a, 525, 15), string.format("coast decel %.0f (RL 525)", a)
end)

test("SteeringCurvature", function()
	-- RL measured max curvature (1/uu) vs speed
	local ref = { { 500, 0.00398 }, { 1000, 0.00235 }, { 2300, 0.00088 } }
	local ok = true
	local msgs = {}
	for _, r in ref do
		-- start in the blue corner so the full-lock circle (r ~ 1140 uu at 2300) fits inside the field
		local w, car = carWorld(Vector3.new(-3000, -4400, 17), 0)
		local n = 0
		while car.body.vel:Dot(car.body.fwd) * BT < r[1] - 5 and n < 600 do
			holdSpeed(w, car, r[1], 0, 1)
			n += 1
		end
		holdSpeed(w, car, r[1], 1, 120)
		local yaw, spd = 0, 0
		for _ = 1, 60 do
			holdSpeed(w, car, r[1], 1, 1)
			yaw += car.body.angVel.Z
			spd += car.body.vel.Magnitude * BT
		end
		local k = yaw / spd
		ok = ok and near(k, r[2], r[2] * 0.06)
		table.insert(msgs, string.format("%d:%.5f(RL %.5f)", r[1], k, r[2]))
	end
	return ok, table.concat(msgs, " ")
end)

test("PowerslideChangesTraction", function()
	local function slip(handbrake: boolean)
		local w, car = carWorld()
		holdSpeed(w, car, 1300, 0, 360)
		car.controls.handbrake = handbrake
		holdSpeed(w, car, 1300, 1, 60)
		local lat = math.abs(car.body.vel:Dot(car.body.right)) * BT
		return lat
	end
	local normal, slide = slip(false), slip(true)
	return slide > normal * 3 and slide > 100, string.format("sideways speed: grip %.0f, powerslide %.0f", normal, slide)
end)

-- ================= CAR: JUMP / FLIP / AIR =================
test("JumpImpulseAndHold", function()
	local function height(holdTicks: number)
		local w, car = carWorld()
		local z0 = car.body.pos.Z
		local maxZ = z0
		for i = 1, 180 do
			car.controls.jump = i <= holdTicks
			w:Step()
			maxZ = math.max(maxZ, car.body.pos.Z)
		end
		return (maxZ - z0) * BT
	end
	local tap, hold = height(1), height(40)
	return hold > tap * 2.5 and hold > 180 and hold < 260, string.format("tap +%.0f uu, full hold +%.0f uu", tap, hold)
end)

test("DoubleJump", function()
	local w, car = carWorld()
	car.controls.jump = true
	w:Step(30)
	car.controls.jump = false
	w:Step(5)
	local vz0 = car.body.vel.Z * BT
	car.controls.jump = true
	w:Step()
	local dv = car.body.vel.Z * BT - vz0
	-- one tick of gravity is also in dv
	return car.hasDoubleJumped and near(dv, C.JUMP_IMMEDIATE_FORCE + C.GRAVITY_Z * C.TICK_TIME, 3), string.format("double jump dv %.1f (RL 291.67 - g*dt)", dv)
end)

test("DoubleJumpWindow", function()
	local w, car = carWorld()
	car.controls.jump = true
	w:Step(24)
	car.controls.jump = false
	w:Step(math.floor(120 * 1.3)) -- past DOUBLEJUMP_MAX_DELAY
	car.controls.jump = true
	w:Step()
	return not car.hasDoubleJumped and not car.hasFlipped, "no second jump after 1.25 s"
end)

test("FrontFlipImpulseAndRotation", function()
	local w, car = carWorld()
	car.controls.jump = true
	w:Step(1)
	car.controls.jump = false
	w:Step(12)
	local v0 = car.body.vel:Dot(car.body.fwd) * BT
	car.controls.jump = true
	car.controls.pitch = -1
	w:Step(1)
	local dv = car.body.vel:Dot(Vector3.new(car.body.fwd.X, car.body.fwd.Y, 0).Unit) * BT - v0
	car.controls.jump = false
	w:Step(30)
	local pitchRate = car.body.angVel:Dot(car.body.right)
	return car.isFlipping and near(dv, 500, 15) and pitchRate > 5, string.format("forward dv %.0f (RL 500), pitch rate %.2f rad/s", dv, pitchRate)
end)

test("FlipSpeedScaling", function()
	-- backflip at speed gets the 2.5x backward scale plus 16/15
	local w, car = carWorld()
	holdSpeed(w, car, 1000, 0, 240)
	car.controls.throttle = 0
	car.controls.jump = true
	w:Step(1)
	car.controls.jump = false
	w:Step(10)
	local f2 = Vector3.new(car.body.fwd.X, car.body.fwd.Y, 0).Unit
	local v0 = car.body.vel:Dot(f2) * BT
	car.controls.jump = true
	car.controls.pitch = 1
	w:Step(1)
	local dv = car.body.vel:Dot(f2) * BT - v0
	local ratio = math.abs(v0) / 2300
	local expect = -500 * ((2.5 - 1) * ratio + 1) * 16 / 15
	return near(dv, expect, 20), string.format("backflip dv %.0f (RocketSim %.0f)", dv, expect)
end)

test("FlipCancel", function()
	local function pitchAfter(cancel: boolean)
		local w, car = carWorld()
		car.controls.jump = true
		w:Step(1)
		car.controls.jump = false
		w:Step(12)
		car.controls.jump = true
		car.controls.pitch = -1
		w:Step(1)
		car.controls.jump = false
		car.controls.pitch = if cancel then 1 else 0
		w:Step(40)
		return car.body.angVel:Dot(car.body.right)
	end
	local normal, cancelled = pitchAfter(false), pitchAfter(true)
	return normal > 4 and math.abs(cancelled) < 1, string.format("pitch rate: flip %.2f, cancelled %.2f", normal, cancelled)
end)

test("AirControlTorque", function()
	local w, car = carWorld(Vector3.new(0, 0, 1000))
	car.body.pos = Vector3.new(0, 0, 1000) * UU
	car.body.vel = Vector3.zero
	car.body.angVel = Vector3.zero
	car.controls.roll = 1
	w:Step(1)
	local rollAccel = -car.body.angVel:Dot(car.body.fwd) / C.TICK_TIME
	return near(rollAccel, 400 * C.CAR_TORQUE_SCALE, 0.5), string.format("roll accel %.2f rad/s^2 (RL %.2f)", rollAccel, 400 * C.CAR_TORQUE_SCALE)
end)

test("MaxAngularSpeed", function()
	local w, car = carWorld(Vector3.new(0, 0, 1500))
	car.body.pos = Vector3.new(0, 0, 1500) * UU
	car.controls.roll = 1
	car.controls.pitch = 1
	car.controls.yaw = 1
	w:Step(120)
	local wmag = car.body.angVel.Magnitude
	return near(wmag, C.CAR_MAX_ANG_SPEED, 0.01), string.format("|w| %.3f (RL 5.5)", wmag)
end)

test("AutoFlipRecovery", function()
	local w, car = carWorld()
	-- upside down on the floor
	local q = Q.mul(Q.fromYaw(math.pi / 2), Q.fromAxisAngle(Vector3.xAxis, math.pi))
	CarPhysics.SetState(car, Vector3.new(0, -3000, 60), q)
	w:Step(60)
	car.controls.jump = true
	w:Step(1)
	car.controls.jump = false
	w:Step(120)
	return car.body.up.Z > 0.9 and car.numWheelsInContact >= 3, string.format("up.z after auto-flip %.2f", car.body.up.Z)
end)

test("WallDriving", function()
	local w, car = carWorld(Vector3.new(2500, 0, 17), 0)
	car.controls.throttle = 1
	w:Step(120 * 3)
	local p = car.body.pos * BT
	local onWall = car.body.up.X < -0.9 and p.Z > 300 and car.numWheelsInContact >= 3
	return onWall, string.format("pos (%.0f, %.0f, %.0f) up.x %.2f wheels %d", p.X, p.Y, p.Z, car.body.up.X, car.numWheelsInContact)
end)

test("CarHitsGoalSideWall", function()
	-- inside the net, drive into the goal side wall: box-vs-box against the solid block beside the goal
	local w, car = carWorld(Vector3.new(-300, 5500, 17), math.pi)
	local Collision = require(script.Parent.Collision)
	local ArenaCollision = require(script.Parent.ArenaCollision)
	local deepest = 0
	local touched = false
	for _ = 1, 150 do
		holdSpeed(w, car, 900, 0, 1)
		local b = car.body
		local hc = CarPhysics.GetHitboxCenter(car)
		for _, bx in ArenaCollision.Boxes do
			local cc = Collision.OBBOBB(hc, b.fwd, b.right, b.up, car.hitboxHalf, bx.c * UU, Vector3.xAxis, Vector3.yAxis, Vector3.zAxis, bx.h * UU, 0.04)
			if cc then
				touched = true
				for _, c in cc do deepest = math.min(deepest, c.dist * BT) end
			end
		end
	end
	local x = car.body.pos.X * BT
	return touched and deepest > -12 and x > -C.GOAL_HALF_WIDTH, string.format("x %.0f, touched the wall block: %s, deepest penetration %.1f uu", x, tostring(touched), -deepest)
end)

test("UpsideDownRestsStill", function()
	local w, car = carWorld()
	local q = Q.mul(Q.fromYaw(math.pi / 2), Q.fromAxisAngle(Vector3.xAxis, math.pi))
	CarPhysics.SetState(car, Vector3.new(0, -3000, 50), q)
	w:Step(240)
	local v = car.body.vel.Magnitude * BT
	local wmag = car.body.angVel.Magnitude
	return v < 1 and wmag < 0.05 and car.body.up.Z < -0.99, string.format("resting on roof: speed %.3f uu/s, |w| %.4f", v, wmag)
end)

-- ================= CAR-BALL =================
test("CarBallHitPower", function()
	local w = World.new({ boostPads = false })
	BallPhysics.SetState(w.ball, Vector3.new(0, 3500, C.BALL_REST_Z), Vector3.zero, Vector3.zero)
	local car = w:AddCar(0)
	CarPhysics.ResetState(car, Vector3.new(0, -4000, 17), math.pi / 2, 100, true)
	w:Step(30)
	local hit = false
	for _ = 1, 1200 do
		car.boost = 100
		car.controls.throttle = 1
		car.controls.boost = true
		w:Step()
		for _, e in w.events do
			if e.type == "hit" then
				hit = true
			end
		end
		if hit then
			break
		end
	end
	w:Step(6)
	local s = w.ball.body.vel.Magnitude * BT
	return hit and s > 2700 and s < 3300, string.format("supersonic car -> ball %.0f uu/s", s)
end)

test("ExtraImpulseCooldown", function()
	local w = World.new({ boostPads = false })
	local car = w:AddCar(0)
	local fired = 0
	for t = 0, 5 do
		BallPhysics.OnHit(w.ball, car, t)
		if car.ballHitInfo.tickCountWhenExtraImpulseApplied == t then
			fired += 1
		end
	end
	return fired == 3, string.format("%d extra impulses in 6 consecutive touching ticks (RocketSim: every other tick)", fired)
end)

test("ContactPointChangesDirection", function()
	local function shot(offsetX: number)
		local w = World.new({ boostPads = false })
		BallPhysics.SetState(w.ball, Vector3.new(offsetX, 0, C.BALL_REST_Z), Vector3.zero, Vector3.zero)
		local car = w:AddCar(0)
		CarPhysics.ResetState(car, Vector3.new(0, -600, 17), math.pi / 2, 100, true)
		w:Step(10)
		for _ = 1, 240 do
			car.controls.throttle = 1
			w:Step()
			if w.ball.body.vel.Magnitude > 0.5 then
				break
			end
		end
		w:Step(6)
		return w.ball.body.vel * BT
	end
	local center, side = shot(0), shot(40)
	return math.abs(center.X) < 30 and side.X > 150, string.format("center hit vx %.0f, offset hit vx %.0f", center.X, side.X)
end)

-- ================= GAME =================
test("GoalDetection", function()
	local w = ballWorld(Vector3.new(0, 4900, 300), Vector3.new(0, 2000, 0))
	local goal = nil
	for _ = 1, 120 do
		w:Step()
		for _, e in w.events do
			if e.type == "goal" then
				goal = e.team
			end
		end
		if goal then
			break
		end
	end
	return goal == 0, "goal event for blue: " .. tostring(goal)
end)

test("BallHitsCrossbarNotGoal", function()
	local w = ballWorld(Vector3.new(0, 4600, 800), Vector3.new(0, 1500, 0))
	local goal = false
	for _ = 1, 120 do
		w:Step()
		for _, e in w.events do
			if e.type == "goal" then goal = true end
		end
	end
	return not goal and w.ball.body.vel.Y < 0, string.format("bounced off back wall above goal, vy %.0f", w.ball.body.vel.Y * BT)
end)

test("BoostPads", function()
	local w = World.new()
	local car = w:AddCar(0)
	CarPhysics.ResetState(car, Vector3.new(0, -1024, 17), 0, 0, true)
	w:Step(2)
	local small = car.boost
	CarPhysics.ResetState(car, Vector3.new(3584, 0, 17), 0, 0, true)
	w:Step(2)
	return near(small, 12, 0.01) and near(car.boost, 100, 0.01), string.format("small pad %.0f, big pad %.0f", small, car.boost)
end)

test("DemolitionAndBump", function()
	local function crash(supersonic: boolean)
		local w = World.new({ boostPads = false })
		BallPhysics.SetState(w.ball, Vector3.new(3500, 4500, C.BALL_REST_Z), Vector3.zero, Vector3.zero)
		local a = w:AddCar(0)
		local b = w:AddCar(1)
		CarPhysics.ResetState(a, Vector3.new(0, -3000, 17), math.pi / 2, 100, true)
		CarPhysics.ResetState(b, Vector3.new(0, 0, 17), 0, 100, true)
		w:Step(10)
		local target = if supersonic then 2250 else 1000
		for _ = 1, 600 do
			holdSpeed(w, a, target, 0, 1)
			if b.isDemoed or b.body.vel.Magnitude * BT > 300 then
				break
			end
		end
		return b
	end
	local demoed = crash(true)
	local bumped = crash(false)
	return demoed.isDemoed and not bumped.isDemoed and bumped.body.vel.Magnitude * BT > 300,
		string.format("supersonic: demo=%s, 1000 uu/s: demo=%s bump speed %.0f", tostring(demoed.isDemoed), tostring(bumped.isDemoed), bumped.body.vel.Magnitude * BT)
end)

test("Determinism", function()
	local function run()
		local w = World.new({ seed = 7 })
		local a = w:AddCar(0)
		local b = w:AddCar(1)
		w:ResetToKickoff(7)
		for i = 1, 600 do
			a.controls.throttle = 1
			a.controls.boost = i < 200
			a.controls.steer = math.sin(i * 0.05)
			a.controls.jump = i % 97 < 8
			b.controls.throttle = 1
			b.controls.steer = -0.3
			w:Step()
		end
		return w.ball.body.pos, a.body.pos, b.body.angVel
	end
	local p1, a1, w1 = run()
	local p2, a2, w2 = run()
	return p1 == p2 and a1 == a2 and w1 == w2, "two runs with identical inputs are bit-identical"
end)

test("FramerateIndependence", function()
	local function run(frameDt: number)
		local w = ballWorld(Vector3.new(0, 0, 800), Vector3.new(300, 200, 0))
		local fs = FixedStep.new()
		-- render frames of any length feed the same 120 Hz ticks; compare after exactly 360 ticks
		while fs.tickCount < 360 do
			fs:Advance(frameDt, function()
				if w.tickCount < 360 then
					w:Step()
				end
			end)
		end
		return w
	end
	local a, b, c = run(1 / 60), run(1 / 144), run(1 / 240)
	local ok = a.tickCount == b.tickCount and b.tickCount == c.tickCount and a.ball.body.pos == b.ball.body.pos and b.ball.body.pos == c.ball.body.pos
	return ok, string.format("ticks 60fps=%d 144fps=%d 240fps=%d", a.tickCount, b.tickCount, c.tickCount)
end)

test("BallPredictionMatchesSim", function()
	local w = ballWorld(Vector3.new(-1000, -2000, 600), Vector3.new(900, 1600, 800), Vector3.new(1, 2, 0))
	local pred = BallPrediction.new(240)
	pred:Update(w)
	w:Step(200)
	local p = pred:GetStateForTime(200 * C.TICK_TIME)
	local real = w.ball.body.pos * BT
	return p ~= nil and (p.pos - real).Magnitude < 0.01, string.format("error after 200 ticks %.4f uu", if p then (p.pos - real).Magnitude else -1)
end)

-- ================= REGRESSION vs REAL RocketSim 2.2.1 =================
-- Reference positions produced by the RocketSim Python bindings (same arena geometry, same inputs).
local RS_REF = {
	{ name = "ball_bounce_spin", ball = { Vector3.new(0, 0, 1000), Vector3.new(500, 300, 0), Vector3.new(0, 0, 2) },
		check = "ball", samples = { { 120, Vector3.new(492.3994, 295.4396, 675.5661) }, { 300, Vector3.new(1093.9857, 656.3909, 394.3806) }, { 600, Vector3.new(1898.6683, 1139.2006, 123.7639) } } },
	{ name = "ball_corner", ball = { Vector3.new(2500, 3500, 300), Vector3.new(1500, 1500, 500), Vector3.zero },
		check = "ball", samples = { { 120, Vector3.new(3169.6951, 4169.6953, 462.0476) }, { 300, Vector3.new(2053.9927, 3053.9934, 229.4355) }, { 480, Vector3.new(1241.0358, 2241.0364, 101.9164) } } },
	{ name = "drive_straight", car = { Vector3.new(0, -3000, 17), 1.5707963 }, segs = { { 360, { throttle = 1 } } },
		check = "car", samples = { { 120, Vector3.new(-0.0003, -2414.9426, 17.032) }, { 360, Vector3.new(-0.0048, 201.7392, 17.032) } } },
	{ name = "boost_and_turn", car = { Vector3.new(0, -4000, 17), 1.5707963 }, segs = { { 120, { throttle = 1, boost = true } }, { 360, { throttle = 1, steer = 0.6 } } },
		check = "car", samples = { { 180, Vector3.new(-166.8819, -2275.4924, 17.032) }, { 360, Vector3.new(-2072.563, -1948.7101, 17.032) } } },
	{ name = "jumps_aircontrol", car = { Vector3.new(0, -2000, 17), 0.5 }, segs = { { 30, {} }, { 54, { jump = true } }, { 70, {} }, { 74, { jump = true } },
		{ 110, { pitch = 1, boost = true } }, { 150, { yaw = 1, roll = -0.5, boost = true } }, { 200, { roll = 1 } }, { 360, { throttle = 1 } } },
		check = "car", samples = { { 90, Vector3.new(10.1367, -1994.462, 237.6035) }, { 150, Vector3.new(166.6438, -1904.8765, 488.5645) }, { 360, Vector3.new(834.6729, -1411.4249, 486.5392) } } },
	{ name = "powerslide", car = { Vector3.new(-1500, -3500, 17), 1.5707963 }, segs = { { 240, { throttle = 1 } }, { 360, { throttle = 1, steer = 1, handbrake = true } }, { 420, { throttle = 1 } } },
		check = "car", samples = { { 300, Vector3.new(-1637.7073, -1055.5404, 17.0319) }, { 420, Vector3.new(-2035.2502, -560.0663, 17.0315) } } },
}

test("MatchesRealRocketSim", function()
	local worst, worstName = 0, ""
	for _, ref in RS_REF do
		local w = World.new()
		local car
		if ref.car then
			car = w:AddCar(0)
			CarPhysics.ResetState(car, ref.car[1], ref.car[2], 100, true)
			BallPhysics.SetState(w.ball, Vector3.new(3500, 4500, 93.15), Vector3.zero, Vector3.zero)
		else
			BallPhysics.SetState(w.ball, ref.ball[1], ref.ball[2], ref.ball[3])
		end
		local last = ref.samples[#ref.samples][1]
		local si = 1
		for i = 0, last - 1 do
			if car then
				local c = {}
				for _, sg in ref.segs do
					if i < sg[1] then c = sg[2] break end
				end
				car.controls = { throttle = c.throttle or 0, steer = c.steer or 0, pitch = c.pitch or 0, yaw = c.yaw or 0, roll = c.roll or 0,
					jump = c.jump == true, boost = c.boost == true, handbrake = c.handbrake == true }
			end
			w:Step()
			local s = ref.samples[si]
			if s and i + 1 == s[1] then
				local p = if ref.check == "car" then car.body.pos * BT else w.ball.body.pos * BT
				local e = (p - s[2]).Magnitude
				if e > worst then worst, worstName = e, ref.name .. "@" .. s[1] end
				si += 1
			end
		end
	end
	return worst < 2, string.format("largest deviation from RocketSim %.2f uu (%s)", worst, worstName)
end)

function Tests.RunAll(verbose: boolean?): (number, number, string)
	local passed, lines = 0, {}
	for _, t in list do
		local ok, res, msg = pcall(t.fn)
		local good = ok and res == true
		if good then
			passed += 1
		end
		local line = string.format("[%s] %s: %s", if good then "PASS" else "FAIL", t.name, if ok then tostring(msg) else ("ERROR " .. tostring(res)))
		table.insert(lines, line)
		if verbose then
			print(line)
		end
	end
	local summary = string.format("%d / %d tests passed", passed, #list)
	table.insert(lines, summary)
	return passed, #list, table.concat(lines, "\n")
end

return Tests
