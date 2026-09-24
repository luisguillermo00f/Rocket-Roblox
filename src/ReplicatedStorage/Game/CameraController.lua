--!strict
-- CameraController.lua: Rocket League chase camera.
--
-- Structure follows RL's own camera state (TAGame CameraState_Car_TA / CameraState_BallCam_TA in the RL SDK):
--   * Ground POV: the camera POSITION rides the surface under the wheels - it sits Height out from the wall along the
--     smoothed contact normal (GroundRotationInterpRate on the floor, GroundRotationInterpRateWall on walls) and
--     looks along the car - but on the floor and walls the horizon stays level: only RollScale of the surface roll
--     reaches the view, so on a side wall the car shows up on its side, off to the wall side of the screen, like in
--     RL. When the view points straight up/down a wall (world up undefined) it falls back to the surface up.
--   * Ceiling: the view turns over with the car (stadium upside down, car upright at the bottom of the screen),
--     blending in over the upper wall-to-ceiling curve so there is no snap.
--   * Air POV: the up vector returns to world up (InterpToAirRate / InterpToGroundRate = AirGroundBlend); after
--     dropping off the ceiling it rolls back about the look direction instead of pitching through the floor.
--     Heading = the car's facing while it is roughly upright and not dodging (GetCarFacingRotation), pulled a little
--     toward the travel direction at speed (AirVelocityInfluence). A dodge or an air roll never swings the view.
--     Pitch stays at `Angle` in the air: the look point (focus) follows the car, so jumps and double jumps keep the
--     car at the same place on screen instead of the camera hanging below it.
--   * Stiffness (official: "the degree to which the camera zooms out while driving quickly") is a speed-based
--     distance offset, (1 - Stiffness) * 114.7 uu at max speed, eased like DistanceInterp - not a position lag, so a
--     dodge or jump impulse never yanks the camera back. Pitch flattens with speed (ScalePitch): -3.2 -> -1.9 deg.
--   * Ground heading lags the nose (~11 deg in a hard turn). Swivel turns at a limited rate (46 deg in 0.17 s,
--     170 deg max) and dies back to centre. Ball cam pitch caps at ~47 deg (PitchExtentMax).
--   Reference numbers: RL recordings measured in github.com/charliedayfockens-hue/advanced-car-soccer PR #2.
--   * Ball cam: yaw toward the ball ~0.1 s lag, pitch band 9 deg below / 11 deg above, around the same up vector.
--   * FOV horizontal at 16:9: +5 deg with speed, +5 deg supersonic. Car cam <-> ball cam blend at 9/s.
--   * Swivel (right stick) turns the view and returns to centre when released.
-- Units: UU, sim axes converted to Roblox axes by the caller (Y up).
local UIS = game:GetService("UserInputService")
local C = require(script.Parent.Parent.Physics.PhysicsConstants)
local ArenaCollision = require(script.Parent.Parent.Physics.ArenaCollision)
local S = C.STUDS_PER_UU

local CameraController = {}

local Settings = {
	FOV = 110, -- horizontal degrees at 16:9
	Distance = 270, -- uu
	Height = 100, -- uu
	AngleDeg = -3,
	Stiffness = 0.35,
	SwivelSpeed = 4,
	TransitionSpeed = 1.2,
	Shake = true,
}
CameraController.Settings = Settings

local M = {
	speedDistance = 114.7, -- uu of pull-back at max speed for stiffness 0
	distanceRate = 2.5, -- DistanceInterp
	pitchSpeedScale = 0.41, -- pitch * (1 - 0.41 * speed/max)
	groundHeadingRate = 11, -- nose follow on surfaces (1/s): ~11 deg lag in a hard turn
	swivelDegPerSecPerSpeed = 69, swivelMaxDeg = 170, swivelDieRate = 9,
	ballPitchMaxDeg = 47,
	speedFov = 5, speedFovRate = 10,
	supersonicFov = 5, supersonicFovRate = 3, -- FInterpTo-style (SupersonicFOVInterpSpeed), no hard zoom on a dodge
	groundRotRate = 8, groundRotRateWall = 4.5, -- up-vector follow on the floor / on walls & ceiling
	toAirRate = 2.2, toGroundRate = 6, -- up vector back to world up after leaving a surface / on landing
	ropeRateGround = 20, -- ground bumps
	airPitchRate = 10, -- pitch back to Angle in the air
	rollScale = 0.1, -- share of the surface roll that reaches the view on the floor / walls
	ceilingFrom = -0.35, ceilingTo = -0.85, -- surface-up Y where the view starts / finishes turning over (ceiling)
	airFacingRate = 5, airVelocityInfluence = 0.3,
	ballYawRate = 10, ballBandBelow = 9, ballBandAbove = 11, ballPitchRate = 20,
	transitionRate = 9,
	minHeight = 30, -- uu above the floor
}
local DEG = math.pi / 180
local UP = Vector3.yAxis

local cam = workspace.CurrentCamera
-- the arena the camera keeps out of: the Soccar arena, or a minigame's own map (SetArena)
local arenaQ: any = ArenaCollision
function CameraController.SetArena(a: any?)
	arenaQ = a or ArenaCollision
end
local st: any = { init = false }
local ballCamWanted = true
local shake = 0
local shakeClock = 0
local timeScale = 1

-- slow motion (goal): the shake wobbles and decays at this rate
function CameraController.SetTimeScale(k: number)
	timeScale = math.clamp(k, 0.05, 1)
end

function CameraController.Shake(amount: number)
	shake = math.min(shake + amount, 3.5)
end

local function ease(rate: number, dt: number): number
	return 1 - math.exp(-rate * dt)
end
local function flatten(v: Vector3, n: Vector3): Vector3
	return v - n * v:Dot(n)
end
local function pitched(h: Vector3, up: Vector3, pitch: number): Vector3
	return h * math.cos(pitch) + up * math.sin(pitch)
end
local function elevation(v: Vector3, up: Vector3): number
	return math.atan2(v:Dot(up), math.max(flatten(v, up).Magnitude, 1e-6))
end
-- unit vector perpendicular to n, closest to pref
local function perpendicular(n: Vector3, pref: Vector3?): Vector3
	for _, v in { pref, Vector3.zAxis, Vector3.xAxis } do
		if v then
			local h = flatten(v, n)
			if h:Dot(h) > 1e-4 then
				return h.Unit
			end
		end
	end
	return Vector3.zAxis
end
-- rotate unit h (perpendicular to up) toward unit d by fraction t of the signed angle between them
local function turnToward(h: Vector3, d: Vector3, up: Vector3, t: number): Vector3
	local ang = math.atan2(h:Cross(d):Dot(up), h:Dot(d))
	return (CFrame.fromAxisAngle(up, ang * t) * h).Unit
end
-- rotate unit a toward unit b by fraction t (great-circle), keeping the result unit. rollAxis (optional): when a and
-- b are far apart (ceiling -> air) the great circle can swing the view through the floor; turn about this axis
-- instead (the look direction), so the view ROLLS back upright
local function slerpDir(a: Vector3, b: Vector3, t: number, rollAxis: Vector3?): Vector3
	local d = math.clamp(a:Dot(b), -1, 1)
	local ang = math.acos(d)
	if ang < 1e-5 then
		return b
	end
	local axis = a:Cross(b)
	if rollAxis and d < -0.5 then
		local r = flatten(rollAxis, a)
		if r.Magnitude > 1e-3 then
			r = r.Unit
			return (CFrame.fromAxisAngle(if r:Dot(axis) < 0 then -r else r, ang * t) * a).Unit
		end
	end
	if axis.Magnitude < 1e-6 then
		axis = perpendicular(a, Vector3.xAxis):Cross(a)
		if axis.Magnitude < 1e-6 then axis = perpendicular(a, Vector3.zAxis) end
	end
	return (CFrame.fromAxisAngle(axis.Unit, ang * t) * a).Unit
end

function CameraController.Reset(carCF: CFrame)
	st.init = false
end

local function snap(carPos: Vector3, carFwd: Vector3, ballPos: Vector3?, onGround: boolean, n: Vector3?)
	local angle = Settings.AngleDeg * DEG
	st.pivot = carPos
	st.up = if onGround and n then n else UP
	st.carHeading = perpendicular(st.up, carFwd)
	st.carPitch = angle
	st.carOrigin = nil
	st.carCamPos = nil
	local toBall = if ballPos then ballPos - carPos else carFwd
	st.ballHeading = perpendicular(st.up, if toBall.Magnitude > 1 then toBall else carFwd)
	st.ballPitch = angle
	st.ballCamPos = nil
	st.blend = if ballCamWanted then 1 else 0
	st.speedFov = 0
	st.sonicFov = 0
	st.dist = Settings.Distance
	st.swivelYaw = 0
	st.swivelPitch = 0
	st.wasOnGround = onGround
	st.init = true
end

-- Everything in UU with Roblox axes (Y up).
-- args: carPos, carFwd, carUp, carVel, speedUU, onGround, groundNormal (unit or nil), flipping, supersonic,
--       ballPos (or nil), ballCam
function CameraController.Update(dt: number, a: { [string]: any })
	cam.CameraType = Enum.CameraType.Scriptable
	local angle = Settings.AngleDeg * DEG
	local carPos: Vector3 = a.carPos
	local carFwd: Vector3 = a.carFwd
	local carUp: Vector3 = a.carUp or UP
	local vel: Vector3 = a.carVel
	local onGround: boolean = a.onGround
	ballCamWanted = a.ballCam and a.ballPos ~= nil
	local ballPos: Vector3 = a.ballPos or (carPos + carFwd * 1000)
	if not st.init or (st.pivot - carPos).Magnitude > 1500 then
		snap(carPos, carFwd, a.ballPos, onGround, a.groundNormal)
	end

	-- FOV: horizontal at 16:9; speed part eases, the supersonic step ramps
	st.speedFov += (M.speedFov * math.clamp(a.speedUU / C.CAR_MAX_SPEED, 0, 1) - st.speedFov) * ease(M.speedFovRate, dt)
	st.sonicFov += ((if a.supersonic then M.supersonicFov else 0) - st.sonicFov) * ease(M.supersonicFovRate, dt)
	local hfov = Settings.FOV + st.speedFov + st.sonicFov
	cam.FieldOfView = math.deg(2 * math.atan(math.tan(math.rad(hfov) / 2) / (16 / 9)))

	-- Focus on the car; stiffness pulls the camera back with speed (DistanceInterp)
	st.pivot = carPos
	local speedFrac = math.clamp(a.speedUU / C.CAR_MAX_SPEED, 0, 1)
	local distTarget = Settings.Distance + (1 - math.clamp(Settings.Stiffness, 0, 1)) * M.speedDistance * speedFrac
	st.dist += (distTarget - st.dist) * ease(M.distanceRate, dt)
	local dist = st.dist
	angle *= 1 - M.pitchSpeedScale * speedFrac

	-- Up vector (AirGroundBlend): surface normal on the ground (rolls with walls/ceiling), world up in the air
	local upTarget = if onGround and a.groundNormal then a.groundNormal else UP
	local upRate
	if onGround then
		upRate = if upTarget.Y > 0.7 then M.groundRotRate else M.groundRotRateWall
		if not st.wasOnGround then upRate = math.max(upRate, M.toGroundRate) end
	else
		upRate = M.toAirRate
	end
	st.wasOnGround = onGround
	st.up = slerpDir(st.up, upTarget, ease(upRate, dt), st.carHeading)
	local n = st.up

	-- ---- car cam
	st.carHeading = perpendicular(n, st.carHeading)
	local carOrigin = st.pivot + n * Settings.Height
	if onGround then
		local nose = flatten(carFwd, n)
		if nose:Dot(nose) > 1e-4 then
			st.carHeading = turnToward(st.carHeading, nose.Unit, n, ease(M.groundHeadingRate, dt))
		end
		if st.carOrigin and st.carCamPos then
			-- bumps: rising/falling along the normal drags the pitch briefly
			local rise = (carOrigin - st.carOrigin):Dot(n)
			local rope = elevation(st.carOrigin - st.carCamPos + n * rise, n)
			st.carPitch = rope + (angle - rope) * ease(M.ropeRateGround, dt)
		else
			st.carPitch = angle
		end
	else
		-- CalculateDesiredAirRotation: car facing while controllable, pulled toward travel at speed
		-- (a dodge keeps the pre-dodge heading; a nose pointing straight up/down, e.g. off a wall, defers to travel)
		local desired = st.carHeading
		local nose = flatten(carFwd, n)
		local facingValid = nose.Magnitude > 0.3 and carUp:Dot(n) > 0.25
		if facingValid and not a.flipping then
			desired = nose.Unit
		end
		local travel = flatten(vel, n)
		local sp = travel.Magnitude
		if sp > 1 then
			local w = M.airVelocityInfluence * math.min(1, sp / C.CAR_MAX_SPEED)
			if not facingValid and not a.flipping then
				w = math.min(1, sp / 500)
			end
			local mix = desired * (1 - w) + (travel / sp) * w
			if mix.Magnitude > 1e-3 then desired = mix.Unit end
		end
		st.carHeading = turnToward(st.carHeading, desired, n, ease(M.airFacingRate, dt))
		st.carPitch += (angle - st.carPitch) * ease(M.airPitchRate, dt)
	end
	st.carPitch = math.clamp(st.carPitch, -1.45, 1.45)
	local carDir = pitched(st.carHeading, n, st.carPitch)
	st.carCamPos = carOrigin - carDir * dist
	st.carOrigin = carOrigin

	-- ---- ball cam (same up vector, so it also rides walls)
	local ballOrigin = carOrigin
	st.ballHeading = perpendicular(n, st.ballHeading)
	local toBall = flatten(ballPos - ballOrigin, n)
	if toBall.Magnitude > 1 then
		st.ballHeading = turnToward(st.ballHeading, toBall.Unit, n, ease(M.ballYawRate, dt))
	end
	local seenFrom = st.ballCamPos or (ballOrigin - pitched(st.ballHeading, n, angle) * dist)
	local ballElev = elevation(ballPos - seenFrom, n)
	local ballTarget = math.clamp(math.min(math.max(angle, ballElev - M.ballBandAbove * DEG), ballElev + M.ballBandBelow * DEG), -1.4, M.ballPitchMaxDeg * DEG)
	st.ballPitch += (ballTarget - st.ballPitch) * ease(M.ballPitchRate, dt)
	local ballDir = pitched(st.ballHeading, n, st.ballPitch)
	st.ballCamPos = ballOrigin - ballDir * dist

	-- ---- car cam <-> ball cam
	local blendTarget = if ballCamWanted then 1 else 0
	st.blend += (blendTarget - st.blend) * ease(M.transitionRate * math.max(0.1, Settings.TransitionSpeed), dt)
	if math.abs(blendTarget - st.blend) < 1e-3 then
		st.blend = blendTarget
	end
	local origin: Vector3, dir: Vector3 = carOrigin, carDir
	if st.blend == 1 then
		dir = ballDir
	elseif st.blend > 0 then
		local heading = turnToward(perpendicular(n, carDir), perpendicular(n, ballDir), n, st.blend)
		dir = pitched(heading, n, elevation(carDir, n) + (elevation(ballDir, n) - elevation(carDir, n)) * st.blend)
	end

	-- ---- swivel (right stick), returns to centre when released
	local lookX, lookY = 0, 0
	if UIS.GamepadEnabled then
		for _, s in UIS:GetGamepadState(Enum.UserInputType.Gamepad1) do
			if s.KeyCode == Enum.KeyCode.Thumbstick2 then
				lookX, lookY = s.Position.X, s.Position.Y
			end
		end
	end
	if math.abs(lookX) > 0.1 or math.abs(lookY) > 0.1 then
		local maxStep = Settings.SwivelSpeed * M.swivelDegPerSecPerSpeed * DEG * dt
		st.swivelYaw += math.clamp(lookX * M.swivelMaxDeg * DEG - st.swivelYaw, -maxStep, maxStep)
		st.swivelPitch += math.clamp(lookY * 0.55 - st.swivelPitch, -maxStep, maxStep)
	else
		local die = ease(M.swivelDieRate, dt)
		st.swivelYaw -= st.swivelYaw * die
		st.swivelPitch -= st.swivelPitch * die
	end
	if st.swivelYaw ~= 0 or st.swivelPitch ~= 0 then
		local heading = CFrame.fromAxisAngle(n, -st.swivelYaw) * perpendicular(n, dir)
		dir = pitched(heading, n, math.clamp(elevation(dir, n) + st.swivelPitch, -1.45, 1.45))
	end

	-- ---- output: look through the look point with the view's up vector, never below the floor or outside the arena
	local pos = origin - dir * dist
	if pos.Y < M.minHeight then
		pos = Vector3.new(pos.X, M.minHeight, pos.Z)
	end
	local simP = Vector3.new(pos.X, pos.Z, pos.Y)
	for _ = 1, 3 do
		local d, nrm = arenaQ.Query(simP)
		if d >= 20 then
			break
		end
		simP += nrm * (20 - d)
	end
	pos = Vector3.new(simP.X, simP.Z, simP.Y)
	-- screen up: world up (level horizon) plus RollScale of the surface roll; surface up when looking along world up
	local uW, uN = flatten(UP, dir), flatten(n, dir)
	local wWorld = math.clamp((uW.Magnitude - 0.2) / 0.4, 0, 1) * (1 - M.rollScale)
	local upVec = (if uW.Magnitude > 1e-4 then uW.Unit * wWorld else Vector3.zero)
		+ (if uN.Magnitude > 1e-4 then uN.Unit * (1 - wWorld) else Vector3.zero)
	if upVec.Magnitude < 1e-3 then upVec = if uW.Magnitude > 1e-4 then uW else UP end
	-- on the ceiling the view turns over with the car: rotate the level up toward the surface up about the look
	-- direction, by how far into the ceiling the (smoothed) surface normal is. Floor / walls: untouched.
	local over = math.clamp((n.Y - M.ceilingFrom) / (M.ceilingTo - M.ceilingFrom), 0, 1)
	if over > 0 and uN.Magnitude > 1e-4 then
		local a, b = upVec.Unit, uN.Unit
		local ang = math.atan2(a:Cross(b):Dot(dir.Unit), a:Dot(b))
		upVec = CFrame.fromAxisAngle(dir.Unit, ang * over) * a
	end
	local cf = CFrame.lookAt(pos * S, (pos + dir) * S, upVec.Unit)
	if Settings.Shake and shake > 0.01 then
		shakeClock += dt * timeScale * 40
		local t = shakeClock
		local off = Vector3.new(math.noise(t, 4), math.noise(t, 5), math.noise(t, 6)) * 0.28 * shake
		cf = cf * CFrame.new(off) * CFrame.Angles(math.noise(t, 1) * 0.022 * shake, math.noise(t, 2) * 0.022 * shake, math.noise(t, 3) * 0.018 * shake)
		shake = math.max(0, shake - dt * timeScale * (1.6 + shake))
	end
	cam.CFrame = cf
end

return CameraController
