--!strict
-- Rumble.lua: controller vibration for game events (touches, pads, goals, demos...).
-- Only when the player is on a gamepad and "VIBRACIÓN" is on (GraphicsSettings "rumble"). Each pulse sets both
-- motors and a later pulse can only raise them; they fade back to 0 on their own.
local HapticService = game:GetService("HapticService")
local RunService = game:GetService("RunService")

local Rumble = {}

local PAD = Enum.UserInputType.Gamepad1
local LARGE, SMALL = Enum.VibrationMotor.Large, Enum.VibrationMotor.Small

local supported: { [Enum.VibrationMotor]: boolean } = {}
local level = { [LARGE] = 0, [SMALL] = 0 }
local untilT = { [LARGE] = 0, [SMALL] = 0 }
local fade = { [LARGE] = 0, [SMALL] = 0 }
local running = false

local function enabled(): boolean
	local okG, IG = pcall(function() return require(script.Parent.InputGlyphs) end)
	if not (okG and IG and IG.IsGamepad()) then return false end
	local okS, GS = pcall(function() return require(script.Parent.GraphicsSettings) end)
	if okS and GS and GS.Get("rumble") == false then return false end
	return true
end

local function motorOk(m: Enum.VibrationMotor): boolean
	if supported[m] == nil then
		local ok, v = pcall(function()
			return HapticService:IsVibrationSupported(PAD) and HapticService:IsMotorSupported(PAD, m)
		end)
		supported[m] = ok and v == true
	end
	return supported[m]
end

local function set(m: Enum.VibrationMotor, v: number)
	if motorOk(m) then pcall(HapticService.SetMotor, HapticService, PAD, m, v) end
end

local function loop()
	if running then return end
	running = true
	local conn: RBXScriptConnection
	conn = RunService.Heartbeat:Connect(function(dt)
		local now = os.clock()
		local any = false
		for _, m in { LARGE, SMALL } do
			if level[m] > 0 then
				if now > untilT[m] then
					level[m] = math.max(0, level[m] - fade[m] * dt)
				end
				set(m, level[m])
				any = any or level[m] > 0
			end
		end
		if not any then
			conn:Disconnect()
			running = false
		end
	end)
end

-- large/small in 0..1, hold seconds at full, then fades out over `release` seconds
function Rumble.Pulse(large: number, small: number, hold: number, release: number?)
	if not enabled() then return end
	local now = os.clock()
	local rel = math.max(0.03, release or 0.12)
	for m, v in { [LARGE] = large, [SMALL] = small } do
		v = math.clamp(v, 0, 1)
		if v > 0 and v >= level[m] * 0.8 then
			level[m] = math.max(level[m], v)
			untilT[m] = math.max(untilT[m], now + hold)
			fade[m] = level[m] / rel
		end
	end
	loop()
end

-- named events so every screen feels the same
function Rumble.Event(kind: string, strength: number?)
	local s = math.clamp(strength or 0.5, 0, 1)
	if kind == "hit" then
		Rumble.Pulse(0.15 + 0.45 * s, 0.35 + 0.5 * s, 0.05 + 0.06 * s, 0.1)
	elseif kind == "pad" then
		Rumble.Pulse(0, if s > 0.5 then 0.45 else 0.25, 0.04, 0.06)
	elseif kind == "pinch" then
		Rumble.Pulse(0.8, 0.9, 0.12, 0.2)
	elseif kind == "goal" then
		Rumble.Pulse(0.9, 0.6, 0.35, 0.6)
	elseif kind == "demo" then
		Rumble.Pulse(1, 0.8, 0.25, 0.4)
	elseif kind == "demoed" then
		Rumble.Pulse(1, 1, 0.4, 0.5)
	elseif kind == "bump" then
		Rumble.Pulse(0.3 + 0.4 * s, 0.2, 0.06, 0.1)
	elseif kind == "land" then
		Rumble.Pulse(0.12 + 0.25 * s, 0, 0.04, 0.08)
	elseif kind == "ui" then
		Rumble.Pulse(0, 0.18, 0.02, 0.04)
	elseif kind == "eliminated" then
		Rumble.Pulse(1, 0.7, 0.45, 0.6)
	elseif kind == "ring" then
		Rumble.Pulse(0.1, 0.4, 0.05, 0.08)
	end
end

function Rumble.Stop()
	for _, m in { LARGE, SMALL } do
		level[m] = 0
		set(m, 0)
	end
end

return Rumble
