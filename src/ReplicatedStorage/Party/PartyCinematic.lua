--!strict
-- PartyCinematic.lua: High-octane cinematic choreography for Party Mode.
-- Updates CarVisual directly via visual:Update(cf, true).
-- Elevated, clean hero camera angle with 360 overview of all 4 cars.

local RunService = game:GetService("RunService")
local PartyConfig = require(script.Parent.PartyConfig)

local PartyCinematic = {}

local camera = workspace.CurrentCamera
local spectatorConn: RBXScriptConnection? = nil
local lastVariation = 0
local ORIGIN = PartyConfig.ORIGIN

local function clamp(x: number, a: number, b: number): number
	return math.max(a, math.min(b, x))
end

local function smooth(t: number): number
	t = clamp(t, 0, 1)
	return t * t * (3 - 2 * t)
end

-- 1. Host Entrance Cinematic (~2.4s)
-- Low camera -> aggressive FOV -> wheel close-up -> acceleration -> jump -> orbit -> landing on Slot 1
function PartyCinematic.PlayHostEntrance(visual: any, targetCF: CFrame, onComplete: (() -> ())?)
	if not visual then
		if onComplete then onComplete() end
		return
	end

	camera.CameraType = Enum.CameraType.Scriptable

	local startPos = targetCF.Position + Vector3.new(0, 0, -45)
	local endPos = targetCF.Position

	local t0 = os.clock()
	local DURATION = 2.2

	local conn
	conn = RunService.RenderStepped:Connect(function()
		local elapsed = os.clock() - t0
		local progress = clamp(elapsed / DURATION, 0, 1)

		if progress < 0.4 then
			-- Phase 1: Fast launch acceleration
			local p1 = progress / 0.4
			local carPos = startPos:Lerp(startPos + Vector3.new(0, 0, 18), smooth(p1))
			local carCF = CFrame.lookAt(carPos, carPos + Vector3.new(0, 0, 1))
			visual:Update(carCF, true)

			camera.FieldOfView = 82
			local camOffset = Vector3.new(4.2, 1.4, -4.2)
			camera.CFrame = CFrame.lookAt(carPos + camOffset, carPos + Vector3.new(0, 0.8, 2))

		elseif progress < 0.75 then
			-- Phase 2: Launch jump into air with roll, camera orbits to 3/4 front
			local p2 = (progress - 0.4) / 0.35
			local jumpY = math.sin(p2 * math.pi) * 7.5
			local carPos = (startPos + Vector3.new(0, 0, 18)):Lerp(endPos, p2) + Vector3.new(0, jumpY, 0)
			local roll = math.sin(p2 * math.pi) * math.rad(20)
			local carCF = CFrame.lookAt(carPos, endPos) * CFrame.Angles(0, 0, roll)
			visual:Update(carCF, true)

			camera.FieldOfView = 72
			local orbitAngle = math.rad(-25 + p2 * 45)
			local camDist = 16
			local camPos = carPos + Vector3.new(math.sin(orbitAngle) * camDist, 4.2, math.cos(orbitAngle) * camDist)
			camera.CFrame = CFrame.lookAt(camPos, carPos + Vector3.new(0, 1, 0))

		else
			-- Phase 3: Suspension bounce on Slot 1 pedestal, hero front settle
			local p3 = (progress - 0.75) / 0.25
			local bounce = math.sin(p3 * math.pi * 2) * (1 - p3) * 1.0
			local carCF = targetCF * CFrame.new(0, bounce, 0)
			visual:Update(carCF, true)

			camera.FieldOfView = 64
			local heroCamPos = endPos + targetCF.LookVector * 18 + Vector3.new(0, 4.0, 0)
			camera.CFrame = CFrame.lookAt(heroCamPos, endPos + Vector3.new(0, 1.2, 0))
		end

		if progress >= 1 then
			conn:Disconnect()
			visual:Update(targetCF, true)
			if onComplete then onComplete() end
		end
	end)
end

-- 2. Joining Player Entrance Cinematic (2.0s, 4 variations)
function PartyCinematic.PlayJoinEntrance(slotIndex: number, visual: any, targetCF: CFrame, variationIndex: number?, onComplete: (() -> ())?)
	if not visual then
		if onComplete then onComplete() end
		return
	end

	local var = variationIndex
	if not var then
		var = (lastVariation % 4) + 1
		lastVariation = var
	end

	camera.CameraType = Enum.CameraType.Scriptable
	local endPos = targetCF.Position
	local t0 = os.clock()
	local DURATION = 2.0

	local conn
	conn = RunService.RenderStepped:Connect(function()
		local elapsed = os.clock() - t0
		local progress = clamp(elapsed / DURATION, 0, 1)

		if var == 1 then
			-- Ramp Flight
			local startPos = endPos + Vector3.new(slotIndex == 2 and -45 or 45, 12, -18)
			local p = smooth(progress)
			local jumpY = math.sin(p * math.pi) * 8
			local carPos = startPos:Lerp(endPos, p) + Vector3.new(0, jumpY, 0)
			local carCF = CFrame.lookAt(carPos, endPos) * CFrame.Angles(math.rad(-12 + (1-p)*20), 0, 0)
			visual:Update(carCF, true)

			camera.FieldOfView = 74
			local lowCam = endPos + Vector3.new(slotIndex == 2 and -12 or 12, 2.2, 8)
			camera.CFrame = CFrame.lookAt(lowCam, carPos)

		elseif var == 2 then
			-- Drift Slide
			local startPos = endPos + Vector3.new(0, 0, 40)
			local p = smooth(progress)
			local carPos = startPos:Lerp(endPos, p)
			local driftAngle = math.rad(math.sin(p * math.pi) * 70)
			local carCF = CFrame.lookAt(carPos, endPos) * CFrame.Angles(0, driftAngle, 0)
			visual:Update(carCF, true)

			camera.FieldOfView = 70
			local sideCam = endPos + Vector3.new(15, 2.8, -10)
			camera.CFrame = CFrame.lookAt(sideCam, carPos + Vector3.new(0, 1.2, 0))

		elseif var == 3 then
			-- Retro Drop
			local dropY = (1 - smooth(progress)) * 36
			local bounce = math.sin(progress * math.pi * 3) * (1 - progress) * 1.6
			local carCF = targetCF * CFrame.new(0, dropY + bounce, 0)
			visual:Update(carCF, true)

			camera.FieldOfView = 76
			local highCam = endPos + Vector3.new(10, 16, 12)
			camera.CFrame = CFrame.lookAt(highCam, targetCF.Position)

		else
			-- Sprint Follow
			local startPos = endPos - targetCF.LookVector * 42
			local p = smooth(progress)
			local carPos = startPos:Lerp(endPos, p)
			local carCF = CFrame.lookAt(carPos, endPos)
			visual:Update(carCF, true)

			camera.FieldOfView = 80 - p * 15
			local rearCam = carPos - targetCF.LookVector * 15 + Vector3.new(0, 3.6, 0)
			camera.CFrame = CFrame.lookAt(rearCam, carPos + Vector3.new(0, 1.0, 0))
		end

		if progress >= 1 then
			conn:Disconnect()
			visual:Update(targetCF, true)
			if onComplete then onComplete() end
		end
	end)
end

-- 3. Dynamic Playground Spectator Camera
function PartyCinematic.StartLobbySpectator(getActiveMovingCar: (() -> any?)?)
	PartyCinematic.Stop()

	camera.CameraType = Enum.CameraType.Scriptable
	local cycleDuration = 7.0
	local phaseStart = os.clock()
	local mode = 1

	spectatorConn = RunService.RenderStepped:Connect(function()
		local now = os.clock()
		if now - phaseStart > cycleDuration then
			phaseStart = now
			mode = (mode % 3) + 1
		end

		local center = ORIGIN + Vector3.new(0, 1.5, -4)

		if mode == 1 then
			-- Elevated Hero Overview: Clear 3/4 downward angle showing all 4 cars and the playground
			local baseCam = ORIGIN + Vector3.new(0, 22, 54)
			local sway = Vector3.new(math.sin(now * 0.25) * 6, math.cos(now * 0.3) * 1.5, 0)
			camera.FieldOfView = 62
			camera.CFrame = CFrame.lookAt(baseCam + sway, center + Vector3.new(0, 1, 0))

		elseif mode == 2 then
			-- 360 Smooth Orbital Pan around the 4 pedestals
			local angle = now * 0.2
			local dist = 44
			local camPos = center + Vector3.new(math.sin(angle) * dist, 14, math.cos(angle) * dist)
			camera.FieldOfView = 64
			camera.CFrame = CFrame.lookAt(camPos, center)

		else
			-- Front 3/4 Low Hero Angle of Host and Stage
			local camPos = ORIGIN + Vector3.new(24, 7, -34) + Vector3.new(math.sin(now * 0.2) * 3, 0, 0)
			camera.FieldOfView = 65
			camera.CFrame = CFrame.lookAt(camPos, center + Vector3.new(0, 1.5, 0))
		end
	end)
end

function PartyCinematic.Stop()
	if spectatorConn then
		spectatorConn:Disconnect()
		spectatorConn = nil
	end
end

return PartyCinematic
