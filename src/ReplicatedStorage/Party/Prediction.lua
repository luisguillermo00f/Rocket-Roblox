--!strict
-- Prediction.lua: the client's picture of the PRESENT in a server-authoritative round (what Rocket League does).
--
-- If our car were predicted while the ball and the other cars were drawn from interpolated snapshots, they would
-- be ~100-150 ms in the past: you'd see your car drive into the ball, and only then the ball would react. So the
-- client runs a local World with:
--   * our car, driven by our inputs (the same quantised inputs the server will run);
--   * the ball, simulated forward from the last server state (same per-world rules: shared.SetupWorld/PostStep);
--   * "ghosts" for the other cars: extrapolated from their last snapshot to the present and pinned there every tick,
--     so we collide with them where we see them.
-- Every MgLocalState carries the server's state of our car AND the ball at tick T, plus the last input it had used.
-- If our prediction for that input matches, nothing happens (the usual case). If not (someone else touched the ball,
-- a bump went differently, the server teleported something), we rewind to T, replay our unacknowledged inputs, and
-- hide the correction with a decaying visual offset. Nothing here decides anything: the server's state always wins.
local RS = game:GetService("ReplicatedStorage")
local Phys = RS:WaitForChild("Physics")
local C = require(Phys.PhysicsConstants)
local World = require(Phys.World)
local CarPhysics = require(Phys.CarPhysics)
local CarConfig = require(Phys.CarConfig)
local BallPhysics = require(Phys.BallPhysics)
local RigidBody = require(Phys.RigidBody)
local Q = require(Phys.Quaternion)
local ArenaCollision = require(Phys.ArenaCollision)
-- the prediction world's arena (set by Prediction.new; ghost extrapolation slides along it). Declared up here, before
-- Prediction.new assigns it: declared below, the assignment went to a global and ghosts always followed the Soccar
-- arena (on a far-away custom map they were pushed back inside the soccer pitch)
local arenaNow: any = ArenaCollision
local Net = require(script.Parent.Net)

local BT = C.BT_TO_UU
local TICK = Net.TICK
local G = -C.GRAVITY_Z
local HISTORY = 240 -- ticks kept for replays (2 s)
local MAX_EXTRAP = 0.35 -- s: never extrapolate a ghost further than this
local CAR_TOL, CAR_VEL_TOL = 2, 15 -- uu, uu/s: closer than this to the server = no replay
local BALL_TOL, BALL_VEL_TOL = 3, 25
local SNAP_CAR, SNAP_BALL, SNAP_GHOST = 450, 400, 500 -- corrections bigger than this snap (respawn, serve, kickoff)
local DECAY_CAR, DECAY_BALL, DECAY_GHOST = 12, 14, 9 -- 1/s
local MIN_REPLAY_GAP = 1 / 15 -- s between replays for small disagreements (big ones replay at once)

local Prediction = {}
Prediction.__index = Prediction

function Prediction.new(shared: any, me: any, participants: { any })
	local self = setmetatable({}, Prediction)
	self.shared = shared
	local pw = World.new(shared.WorldOptions())
	arenaNow = pw.arena or ArenaCollision
	pw.demoMode = shared.DemoMode or "disabled"
	if shared.SetupWorld then shared.SetupWorld(pw) end
	pw.ballEnabled = false
	self.pw = pw
	local cfg = CarConfig[me.hitbox] or CarConfig.Octane
	self.car = pw:AddCar((me.team or 0) % 2, cfg)
	self.scratchCar = CarPhysics.new(cfg, (me.team or 0) % 2, 999)
	self.scratchBall = BallPhysics.new() -- only its position / velocity are compared
	self.ghosts = {} -- netId -> { car, inWorld, err }
	for _, p in participants do
		if p ~= me and p.netId then
			local g = pw:AddCar((p.team or 0) % 2, CarConfig[p.hitbox] or CarConfig.Octane)
			self.ghosts[p.netId] = { car = g, inWorld = true, err = Vector3.zero, p = p }
		end
	end
	self.seq = 0
	self.hist = {}
	self.outbox = {}
	self.hasState = false
	self.lastAckTick = -1
	self.lastReplay = 0
	self.base = nil -- newest snapshot (ghosts extrapolate from it)
	self.byTick = {} -- recent snapshots by server tick (replays use the one matching the LocalState)
	self.carR = nil -- { prev, cur } render states of our car / the ball
	self.ballR = nil
	self.carErr = Vector3.zero
	self.ballErr = Vector3.zero
	self.postLive = false -- the minigame's per-tick rule (shared.PostStep) is running (e.g. a volley rally)
	self.stats = { states = 0, replays = 0, maxCarErr = 0, maxBallErr = 0 }
	return self
end

-- ---------------------------------------------------------------- ghosts
-- state of a remote car dt seconds after its snapshot. The arena is part of the guess: a straight line from a car
-- coming down a wall (or a parabola from one about to land) runs through the floor, and that ghost then showed up
-- sunk into the ground until the next snapshot corrected it. So:
--   * on its wheels (floor, ramp, wall, ceiling): slide along the surface, keeping the snapshot's distance to it;
--   * in the air: ballistic, but it lands on the arena instead of passing through it.
local AIR_CLEAR = 17 -- uu: the closest a car's centre gets to the arena (resting on its wheels or its roof)
local STICK_RANGE = 80 -- uu: a grounded car follows the surface only while it's this close to it
local STEP = 1 / 40 -- s: surface-following step

local function extrapolate(cs: any, dt: number): (Vector3, Vector3, any)
	local ArenaCollision = arenaNow
	dt = math.clamp(dt, 0, MAX_EXTRAP)
	local rot = if cs.angVel and cs.angVel.Magnitude > 1e-3 then Q.integrate(cs.rot, cs.angVel, dt) else cs.rot
	local pos, vel
	if cs.onGround then
		-- short steps, re-projected onto the surface each time, so it rounds the curved ramps instead of cutting them
		local _, _, up = Q.toBasis(cs.rot)
		vel = cs.vel - up * cs.vel:Dot(up)
		pos = cs.pos
		if cs.surfDist == nil then
			cs.surfDist = math.max(AIR_CLEAR, (ArenaCollision.Query(cs.pos)))
		end
		local steps = math.max(1, math.ceil(dt / STEP))
		local h = dt / steps
		for _ = 1, steps do
			pos += vel * h
			local d, n = ArenaCollision.Query(pos)
			if math.abs(d - cs.surfDist) < STICK_RANGE or d < AIR_CLEAR then
				pos += n * (cs.surfDist - d)
				vel -= n * vel:Dot(n) -- tangent where it is now
			end
		end
	else
		pos = cs.pos + cs.vel * dt - Vector3.new(0, 0, 0.5 * G * dt * dt)
		vel = cs.vel - Vector3.new(0, 0, G * dt)
		local d, n = ArenaCollision.Query(pos)
		if d < AIR_CLEAR then
			pos += n * (AIR_CLEAR - d)
			local into = vel:Dot(n)
			if into < 0 then vel -= n * into end
		end
	end
	return pos, vel, rot
end
Prediction.Extrapolate = extrapolate -- tests

function Prediction.GhostAt(self: any, netId: number, tickTime: number): (Vector3?, any, any)
	local snap = self.base
	local cs = snap and snap.cars[netId]
	if not cs then return nil, nil, nil end
	local pos, _, rot = extrapolate(cs, (tickTime - snap.tick) * TICK)
	return pos, rot, cs
end

-- pin every visible ghost where it is at server tick p (before stepping the world from p)
function Prediction.PlaceGhosts(self: any, p: number)
	local snap = self.base
	if not snap then return end
	local pw = self.pw
	for netId, g in self.ghosts do
		local cs = snap.cars[netId]
		local show = cs ~= nil and not cs.hidden and not cs.demoed
		if show ~= g.inWorld then
			g.inWorld = show
			if show then
				table.insert(pw.cars, g.car)
			else
				pw:RemoveCar(g.car)
			end
		end
		if show then
			local pos, vel, rot = extrapolate(cs, (p - snap.tick) * TICK)
			local body = g.car.body
			body.pos = pos / BT
			RigidBody.SetRotation(body, rot)
			body.vel = vel / BT
			body.angVel = cs.angVel or Vector3.zero
			g.car.controls = CarPhysics.EmptyControls()
			g.car.boost = cs.boost
		end
	end
end

function Prediction.OnSnapshot(self: any, snap: any)
	local old = self.base
	self.byTick[snap.tick] = snap
	self.byTick[snap.tick - 120] = nil
	if old and snap.tick <= old.tick then return end
	-- the new base moves where the ghosts are "now": keep them where they were on screen and ease out the difference
	if old and self.hasState then
		local now = self.pw.tickCount
		for netId, g in self.ghosts do
			local a, b = old.cars[netId], snap.cars[netId]
			if a and b then
				local pa = extrapolate(a, (now - old.tick) * TICK)
				local pb = extrapolate(b, (now - snap.tick) * TICK)
				local d = pa - pb
				g.err = if (g.err + d).Magnitude > SNAP_GHOST or b.hidden or a.hidden then Vector3.zero else g.err + d
			end
		end
	end
	self.base = snap
end

-- ---------------------------------------------------------------- simulation
function Prediction.Step(self: any, controls: any)
	local pw = self.pw
	self:PlaceGhosts(pw.tickCount)
	self.shared.PreTick(self.car, TICK)
	self.car.controls = controls
	pw:Step()
	if self.shared.PostStep then
		self.shared.PostStep(pw, self.postLive)
	end
end

local function capture(body: any): any
	return { p = body.pos * BT, q = body.rot }
end

-- one new input: advance the present by a tick
function Prediction.Tick(self: any, controls: any)
	if not self.hasState then return end
	self.seq += 1
	local seq = self.seq
	local car, ball = self.car, self.pw.ball
	self.carR.prev, self.ballR.prev = self.carR.cur, self.ballR.cur
	self:Step(controls)
	self.carR.cur, self.ballR.cur = capture(car.body), capture(ball.body)
	self.hist[seq] = {
		controls = controls, cp = car.body.pos, cv = car.body.vel,
		bp = ball.body.pos, bv = ball.body.vel, be = self.pw.ballEnabled,
	}
	self.hist[seq - HISTORY] = nil
	table.insert(self.outbox, { seq = seq, controls = controls })
	while #self.outbox > Net.INPUT_REDUNDANCY do
		table.remove(self.outbox, 1)
	end
end

function Prediction.OnLocalState(self: any, ack: number, tick: number, applyCar: any, applyBall: any, ballEnabled: boolean): string?
	if tick <= self.lastAckTick then return nil end
	self.lastAckTick = tick
	self.stats.states += 1
	local pw = self.pw
	local car, ball = self.car, pw.ball
	if not self.hasState then
		applyCar(car)
		applyBall(ball)
		pw.ballEnabled = ballEnabled
		pw.tickCount = tick
		pw.manifolds = {}
		self.seq = math.max(self.seq, ack)
		self.hasState = true
		self.carR = { prev = capture(car.body), cur = capture(car.body) }
		self.ballR = { prev = capture(ball.body), cur = capture(ball.body) }
		return "reset"
	end

	-- what did we predict right after the same input?
	applyCar(self.scratchCar)
	applyBall(self.scratchBall)
	local h = self.hist[ack]
	for s in self.hist do
		if s <= ack - 8 then self.hist[s] = nil end
	end
	local carErr, ballErr = math.huge, 0
	if h then
		carErr = math.max((self.scratchCar.body.pos - h.cp).Magnitude * BT / CAR_TOL, (self.scratchCar.body.vel - h.cv).Magnitude * BT / CAR_VEL_TOL)
		if ballEnabled or h.be then
			ballErr = if ballEnabled ~= h.be then math.huge else math.max((self.scratchBall.body.pos - h.bp).Magnitude * BT / BALL_TOL, (self.scratchBall.body.vel - h.bv).Magnitude * BT / BALL_VEL_TOL)
		end
	end
	local worst = math.max(carErr, ballErr)
	if worst <= 1 then return nil end
	-- small disagreements don't need a replay on every state packet
	local now = os.clock()
	if worst < 4 and now - self.lastReplay < MIN_REPLAY_GAP then return nil end
	self.lastReplay = now

	-- rewind to the server's tick and replay what it hasn't seen yet
	local beforeCar, beforeBall = car.body.pos, ball.body.pos
	applyCar(car)
	applyBall(ball)
	pw.ballEnabled = ballEnabled
	pw.tickCount = tick
	pw.manifolds = {}
	local latest = self.base
	local match = self.byTick[tick]
	if match then self.base = match end
	local lastCar, lastBall = capture(car.body), capture(ball.body)
	for s = ack + 1, self.seq do
		local e = self.hist[s]
		if e then
			lastCar, lastBall = capture(car.body), capture(ball.body)
			self:Step(e.controls)
			e.cp, e.cv, e.bp, e.bv, e.be = car.body.pos, car.body.vel, ball.body.pos, ball.body.vel, pw.ballEnabled
		end
	end
	self.base = latest
	self.stats.replays += 1

	-- keep things where they were on screen and ease the difference out (or snap if it's a teleport)
	local jc = (beforeCar - car.body.pos) * BT
	local jb = (beforeBall - ball.body.pos) * BT
	self.stats.maxCarErr = math.max(self.stats.maxCarErr, jc.Magnitude)
	self.stats.maxBallErr = math.max(self.stats.maxBallErr, jb.Magnitude)
	if (self.carErr + jc).Magnitude > SNAP_CAR then
		self.carErr = Vector3.zero
		lastCar = capture(car.body)
	else
		self.carErr += jc
	end
	if (self.ballErr + jb).Magnitude > SNAP_BALL then
		self.ballErr = Vector3.zero
		lastBall = capture(ball.body)
	else
		self.ballErr += jb
	end
	self.carR = { prev = lastCar, cur = capture(car.body) }
	self.ballR = { prev = lastBall, cur = capture(ball.body) }
	return "replay"
end

function Prediction.Decay(self: any, dt: number)
	self.carErr *= math.exp(-DECAY_CAR * dt)
	self.ballErr *= math.exp(-DECAY_BALL * dt)
	local k = math.exp(-DECAY_GHOST * dt)
	for _, g in self.ghosts do g.err *= k end
end

-- ---------------------------------------------------------------- render states (alpha = FixedStep blend)
function Prediction.CarRender(self: any, alpha: number): (Vector3, any)
	local r = self.carR
	return r.prev.p:Lerp(r.cur.p, alpha) + self.carErr, Q.slerp(r.prev.q, r.cur.q, alpha)
end

function Prediction.BallRender(self: any, alpha: number): (Vector3, any)
	local r = self.ballR
	return r.prev.p:Lerp(r.cur.p, alpha) + self.ballErr, Q.slerp(r.prev.q, r.cur.q, alpha)
end

-- a remote car in the present (same moment as our car on screen)
function Prediction.GhostRender(self: any, netId: number, alpha: number): (Vector3?, any, any)
	local pos, rot, cs = self:GhostAt(netId, self.pw.tickCount - 1 + alpha)
	if not pos then return nil, nil, nil end
	local g = self.ghosts[netId]
	return pos + (if g then g.err else Vector3.zero), rot, cs
end

function Prediction.BallVelocity(self: any): Vector3
	return self.pw.ball.body.vel * BT
end

return Prediction
