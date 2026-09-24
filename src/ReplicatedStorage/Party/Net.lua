--!strict
-- Net.lua: shared networking for Party minigames (server authoritative).
--
-- Client -> server: only vehicle controls, quantised and batched (MgInput, unreliable). Every 120 Hz client tick has
--   an input with a sequence number; each packet repeats the last few inputs so a lost packet costs nothing.
-- Server -> clients: 30 Hz snapshots of every car + the ball (MgSnapshot, unreliable, ~250 bytes), plus to each
--   player their own car's full simulation state, the ball's full state at the same tick and the last input it
--   consumed (MgLocalState), so the client can predict its car AND the ball in the present and rewind/replay when the
--   server disagrees. Gameplay events (points, phases, results) are discrete RemoteEvents.
-- Controls are quantised to 1/127 on BOTH sides before use, so the client predicts with exactly what the server runs.
local RS = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Phys = RS:WaitForChild("Physics")
local C = require(Phys.PhysicsConstants)
local CarPhysics = require(Phys.CarPhysics)
local CarConfig = require(Phys.CarConfig)
local RigidBody = require(Phys.RigidBody)

local Net = {}

Net.TICK = C.TICK_TIME
Net.SNAPSHOT_EVERY = 4 -- ticks (30 Hz)
Net.INPUT_REDUNDANCY = 6 -- inputs repeated per packet
Net.INTERP_DELAY = 0.1 -- s behind the newest snapshot for remote cars / ball
local BT = C.BT_TO_UU

-- ---------------------------------------------------------------- remotes
local REMOTES = {
	PartyRequest = "RemoteFunction",
	PartyState = "RemoteEvent",
	MatchRequest = "RemoteFunction", -- online matches: queue / private rooms (MatchMaker)
	MatchState = "RemoteEvent",
	MgEvent = "RemoteEvent",
	MgReady = "RemoteEvent",
	MgInput = "UnreliableRemoteEvent",
	MgSnapshot = "UnreliableRemoteEvent",
	MgLocalState = "UnreliableRemoteEvent",
}

function Net.CreateRemotes(): Folder
	assert(RunService:IsServer(), "server only")
	local f = RS:FindFirstChild("PartyRemotes")
	if not f then
		f = Instance.new("Folder")
		f.Name = "PartyRemotes"
		f.Parent = RS
	end
	for name, class in REMOTES do
		if not f:FindFirstChild(name) then
			local r = Instance.new(class)
			r.Name = name
			r.Parent = f
		end
	end
	return f :: Folder
end

function Net.Remote(name: string): any
	local f = RS:WaitForChild("PartyRemotes", 20)
	return f and f:WaitForChild(name, 20)
end

-- ---------------------------------------------------------------- controls
local function q127(v: number): number
	return math.clamp(math.floor(v * 127 + 0.5), -127, 127)
end

-- exactly what the server will run (clamped + quantised)
function Net.Quantize(c: any): any
	return {
		throttle = q127(c.throttle or 0) / 127, steer = q127(c.steer or 0) / 127, pitch = q127(c.pitch or 0) / 127,
		yaw = q127(c.yaw or 0) / 127, roll = q127(c.roll or 0) / 127,
		jump = c.jump == true, boost = c.boost == true, handbrake = c.handbrake == true,
	}
end

local function writeControls(b: buffer, o: number, c: any)
	buffer.writei8(b, o, q127(c.throttle))
	buffer.writei8(b, o + 1, q127(c.steer))
	buffer.writei8(b, o + 2, q127(c.pitch))
	buffer.writei8(b, o + 3, q127(c.yaw))
	buffer.writei8(b, o + 4, q127(c.roll))
	buffer.writeu8(b, o + 5, (if c.jump then 1 else 0) + (if c.boost then 2 else 0) + (if c.handbrake then 4 else 0))
end

local function readControls(b: buffer, o: number): any
	local f = buffer.readu8(b, o + 5)
	return {
		throttle = buffer.readi8(b, o) / 127, steer = buffer.readi8(b, o + 1) / 127, pitch = buffer.readi8(b, o + 2) / 127,
		yaw = buffer.readi8(b, o + 3) / 127, roll = buffer.readi8(b, o + 4) / 127,
		jump = bit32.band(f, 1) ~= 0, boost = bit32.band(f, 2) ~= 0, handbrake = bit32.band(f, 4) ~= 0,
	}
end

-- inputs: array of { seq, controls }, oldest first
function Net.EncodeInputs(inputs: { any }): buffer
	local n = #inputs
	local b = buffer.create(1 + n * 10)
	buffer.writeu8(b, 0, n)
	for i, inp in inputs do
		local o = 1 + (i - 1) * 10
		buffer.writeu32(b, o, inp.seq)
		writeControls(b, o + 4, inp.controls)
	end
	return b
end

function Net.DecodeInputs(b: any): { any }?
	if typeof(b) ~= "buffer" then return nil end
	local len = buffer.len(b)
	if len < 1 or len > 1 + 16 * 10 then return nil end
	local n = buffer.readu8(b, 0)
	if n > 16 or len ~= 1 + n * 10 then return nil end
	local out = table.create(n)
	for i = 1, n do
		local o = 1 + (i - 1) * 10
		out[i] = { seq = buffer.readu32(b, o), controls = readControls(b, o + 4) }
	end
	return out
end

-- ---------------------------------------------------------------- snapshots (all cars + ball)
local function writeV3(b: buffer, o: number, v: Vector3)
	buffer.writef32(b, o, v.X); buffer.writef32(b, o + 4, v.Y); buffer.writef32(b, o + 8, v.Z)
end
local function readV3(b: buffer, o: number): Vector3
	return Vector3.new(buffer.readf32(b, o), buffer.readf32(b, o + 4), buffer.readf32(b, o + 8))
end
local function writeQ(b: buffer, o: number, q: any)
	buffer.writei16(b, o, math.floor(q.x * 32767 + 0.5)); buffer.writei16(b, o + 2, math.floor(q.y * 32767 + 0.5))
	buffer.writei16(b, o + 4, math.floor(q.z * 32767 + 0.5)); buffer.writei16(b, o + 6, math.floor(q.w * 32767 + 0.5))
end
local function readQ(b: buffer, o: number): any
	local x, y, z, w = buffer.readi16(b, o) / 32767, buffer.readi16(b, o + 2) / 32767, buffer.readi16(b, o + 4) / 32767, buffer.readi16(b, o + 6) / 32767
	local m = math.sqrt(x * x + y * y + z * z + w * w)
	if m < 1e-6 then return { x = 0, y = 0, z = 0, w = 1 } end
	return { x = x / m, y = y / m, z = z / m, w = w / m }
end

local HEADER = 4 + 8 + 1 + 1 + 1 -- tick, server time, cars, ball visible, boost pads
local BALL = 12 + 8 + 12
local CAR = 1 + 12 + 8 + 12 + 1 + 1 + 4 + 1 + 12

-- cars: list of car objects (with .netId). ballVisible false hides the ball (e.g. between points). pads: the world's
-- boost pads (active or not, one bit each) when the round has them
function Net.EncodeSnapshot(tick: number, serverTime: number, cars: { any }, ball: any, ballVisible: boolean, pads: { any }?): buffer
	local n = #cars
	local np = if pads then #pads else 0
	local b = buffer.create(HEADER + BALL + n * CAR + math.ceil(np / 8))
	buffer.writeu32(b, 0, tick)
	buffer.writef64(b, 4, serverTime)
	buffer.writeu8(b, 12, n)
	buffer.writeu8(b, 13, if ballVisible then 1 else 0)
	buffer.writeu8(b, 14, np)
	if pads then
		local o = HEADER + BALL + n * CAR
		for i, pad in pads do
			if pad.isActive then
				local byte = o + (i - 1) // 8
				buffer.writeu8(b, byte, bit32.bor(buffer.readu8(b, byte), bit32.lshift(1, (i - 1) % 8)))
			end
		end
	end
	local bb = ball.body
	writeV3(b, HEADER, bb.pos * BT)
	writeQ(b, HEADER + 12, bb.rot)
	writeV3(b, HEADER + 20, bb.vel * BT)
	for i, car in cars do
		local o = HEADER + BALL + (i - 1) * CAR
		local body = car.body
		buffer.writeu8(b, o, car.netId)
		writeV3(b, o + 1, body.pos * BT)
		writeQ(b, o + 13, body.rot)
		writeV3(b, o + 21, body.vel * BT)
		buffer.writei8(b, o + 33, q127((car.controls and car.controls.steer) or 0))
		local flags = (if car.isBoosting then 1 else 0) + (if car.isSupersonic then 2 else 0) + (if car.isDemoed then 4 else 0)
			+ (if (car.numWheelsInContact or 0) > 0 then 8 else 0) + (if car.netHidden then 16 else 0)
		buffer.writeu8(b, o + 34, flags)
		for w = 1, 4 do
			local wh = car.wheels[w]
			local f = (wh.suspensionLength - (wh.restLen - wh.travel)) / (2 * wh.travel)
			buffer.writeu8(b, o + 35 + (w - 1), math.clamp(math.floor(f * 255 + 0.5), 0, 255))
		end
		buffer.writeu8(b, o + 39, math.clamp(math.floor((car.boost or 0) + 0.5), 0, 255))
		writeV3(b, o + 40, body.angVel) -- rad/s, for extrapolating the car's rotation on clients
	end
	return b
end

function Net.DecodeSnapshot(b: any): any?
	if typeof(b) ~= "buffer" or buffer.len(b) < HEADER + BALL then return nil end
	local n = buffer.readu8(b, 12)
	local np = buffer.readu8(b, 14)
	if buffer.len(b) ~= HEADER + BALL + n * CAR + math.ceil(np / 8) then return nil end
	local snap = {
		tick = buffer.readu32(b, 0), serverTime = buffer.readf64(b, 4), ballVisible = buffer.readu8(b, 13) == 1,
		ball = { pos = readV3(b, HEADER), rot = readQ(b, HEADER + 12), vel = readV3(b, HEADER + 20) },
		cars = {},
		pads = table.create(np),
	}
	local po = HEADER + BALL + n * CAR
	for i = 1, np do
		snap.pads[i] = bit32.band(buffer.readu8(b, po + (i - 1) // 8), bit32.lshift(1, (i - 1) % 8)) ~= 0
	end
	for i = 1, n do
		local o = HEADER + BALL + (i - 1) * CAR
		local flags = buffer.readu8(b, o + 34)
		local susp = table.create(4)
		for w = 1, 4 do susp[w] = buffer.readu8(b, o + 35 + (w - 1)) / 255 end
		snap.cars[buffer.readu8(b, o)] = {
			pos = readV3(b, o + 1), rot = readQ(b, o + 13), vel = readV3(b, o + 21), steer = buffer.readi8(b, o + 33) / 127,
			boosting = bit32.band(flags, 1) ~= 0, supersonic = bit32.band(flags, 2) ~= 0, demoed = bit32.band(flags, 4) ~= 0,
			onGround = bit32.band(flags, 8) ~= 0, hidden = bit32.band(flags, 16) ~= 0, susp = susp, boost = buffer.readu8(b, o + 39),
			angVel = readV3(b, o + 40),
		}
	end
	return snap
end

-- ---------------------------------------------------------------- full car state (own car, for prediction)
-- Field list built from a fresh car: every number / boolean / Vector3 in the car and its nested tables, except
-- constants, the rigid body (sent separately, f64) and the live controls. Same list on server and client.
local SKIP = {
	body = true, config = true, controls = true, groundObject = true, groundBody = true, id = true, team = true,
	hitboxHalf = true, hitboxOffset = true, front = true, left = true, conn = true, radius = true, restLen = true,
	travel = true, suspensionForceScale = true, netId = true, netHidden = true,
}
type Field = { path: { any }, kind: string }
local FIELDS: { Field } = {}
do
	local fresh = CarPhysics.new(CarConfig.Octane, 0, 1)
	local function keysSorted(t: any): { any }
		local ks = {}
		for k in t do table.insert(ks, k) end
		table.sort(ks, function(a, b)
			if type(a) == type(b) then return a < b end
			return type(a) == "number"
		end)
		return ks
	end
	local function walk(t: any, prefix: { any })
		for _, k in keysSorted(t) do
			if SKIP[k] then continue end
			local v = t[k]
			local p = table.clone(prefix)
			table.insert(p, k)
			local tv = typeof(v)
			if tv == "number" or tv == "boolean" or tv == "Vector3" then
				table.insert(FIELDS, { path = p, kind = tv })
			elseif tv == "table" then
				walk(v, p)
			end
		end
	end
	walk(fresh, {})
end
local STATE_SIZE = 13 * 8
for _, f in FIELDS do
	STATE_SIZE += if f.kind == "number" then 4 elseif f.kind == "boolean" then 1 else 12
end
Net.CAR_STATE_SIZE = STATE_SIZE

local function getPath(t: any, p: { any }): any
	for i = 1, #p do
		t = t[p[i]]
		if t == nil then return nil end
	end
	return t
end
local function setPath(t: any, p: { any }, v: any)
	for i = 1, #p - 1 do
		t = t[p[i]]
		if t == nil then return end
	end
	t[p[#p]] = v
end

-- ball block: pos, rot, vel, angVel (f64, like the car's body), impulse cache (f32), enabled flag
local BALL_STATE = 13 * 8 + 12 + 1

-- LocalState: ack input seq + server tick + the car's complete state + the ball's state at the same tick
function Net.EncodeLocalState(ackSeq: number, tick: number, car: any, ball: any, ballEnabled: boolean): buffer
	local b = buffer.create(8 + STATE_SIZE + BALL_STATE)
	buffer.writeu32(b, 0, ackSeq)
	buffer.writeu32(b, 4, tick)
	local body = car.body
	local o = 8
	for _, v in { body.pos.X, body.pos.Y, body.pos.Z, body.rot.x, body.rot.y, body.rot.z, body.rot.w, body.vel.X, body.vel.Y, body.vel.Z, body.angVel.X, body.angVel.Y, body.angVel.Z } do
		buffer.writef64(b, o, v)
		o += 8
	end
	for _, f in FIELDS do
		local v = getPath(car, f.path)
		if f.kind == "number" then
			buffer.writef32(b, o, v or 0); o += 4
		elseif f.kind == "boolean" then
			buffer.writeu8(b, o, if v then 1 else 0); o += 1
		else
			writeV3(b, o, v or Vector3.zero); o += 12
		end
	end
	local bb = ball.body
	for _, v in { bb.pos.X, bb.pos.Y, bb.pos.Z, bb.rot.x, bb.rot.y, bb.rot.z, bb.rot.w, bb.vel.X, bb.vel.Y, bb.vel.Z, bb.angVel.X, bb.angVel.Y, bb.angVel.Z } do
		buffer.writef64(b, o, v)
		o += 8
	end
	writeV3(b, o, ball.velocityImpulseCache or Vector3.zero)
	buffer.writeu8(b, o + 12, if ballEnabled then 1 else 0)
	return b
end

-- returns ackSeq, tick, applier(car) that writes the car state, applier(ball) for the ball, and whether the ball
-- is simulating on the server
function Net.DecodeLocalState(b: any): (number?, number?, ((any) -> ())?, ((any) -> ())?, boolean?)
	if typeof(b) ~= "buffer" or buffer.len(b) ~= 8 + STATE_SIZE + BALL_STATE then return nil, nil, nil, nil, nil end
	local ack, tick = buffer.readu32(b, 0), buffer.readu32(b, 4)
	return ack, tick, function(car: any)
		local body = car.body
		local o = 8
		local v = table.create(13)
		for i = 1, 13 do v[i] = buffer.readf64(b, o); o += 8 end
		body.pos = Vector3.new(v[1], v[2], v[3])
		RigidBody.SetRotation(body, { x = v[4], y = v[5], z = v[6], w = v[7] })
		body.vel = Vector3.new(v[8], v[9], v[10])
		body.angVel = Vector3.new(v[11], v[12], v[13])
		for _, f in FIELDS do
			if f.kind == "number" then
				setPath(car, f.path, buffer.readf32(b, o)); o += 4
			elseif f.kind == "boolean" then
				setPath(car, f.path, buffer.readu8(b, o) == 1); o += 1
			else
				setPath(car, f.path, readV3(b, o)); o += 12
			end
		end
	end, function(ball: any)
		local body = ball.body
		local o = 8 + STATE_SIZE
		local v = table.create(13)
		for i = 1, 13 do v[i] = buffer.readf64(b, o); o += 8 end
		body.pos = Vector3.new(v[1], v[2], v[3])
		RigidBody.SetRotation(body, { x = v[4], y = v[5], z = v[6], w = v[7] })
		body.vel = Vector3.new(v[8], v[9], v[10])
		body.angVel = Vector3.new(v[11], v[12], v[13])
		ball.velocityImpulseCache = readV3(b, o)
	end, buffer.readu8(b, 8 + STATE_SIZE + BALL_STATE - 1) == 1
end

-- server clock shared by everyone (timers are computed from it, never from the local clock)
function Net.Now(): number
	return workspace:GetServerTimeNow()
end

return Net
