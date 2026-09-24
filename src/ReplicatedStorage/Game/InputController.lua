--!strict
-- InputController.lua: keyboard + gamepad -> RocketSim CarControls. Physics never reads devices directly.
-- Every gameplay button comes from Keybinds (rebindable in AJUSTES › BOTONES). Defaults = Rocket League's:
-- Keyboard: W/S throttle & pitch, A/D steer & yaw, Space jump (also RMB), Shift boost (also LMB),
--           Ctrl powerslide / air roll (turns A/D into roll while airborne), Q/E air roll left/right.
-- Gamepad: RT/LT throttle, left stick steer/pitch/yaw (fixed), A jump, B boost, X powerslide/air roll, LB/RB air roll,
--           Y ball cam, Select/View/Share: tap = pause, hold = scoreboard (Roblox keeps Start/Menu for its own
--           menu; Start still pauses if it gets through), R3 controls help, d-pad training tools.
-- Pause and scoreboard may share one input on either device: a tap pauses, holding shows the scoreboard.
-- The left-stick dead zone is a player setting (GraphicsSettings "deadzone").
local UIS = game:GetService("UserInputService")
local Keybinds = require(script.Parent.Keybinds)

local InputController = {}

local toggles = { ballCam = true, debug = false, help = true, prediction = false }
local listeners: { [string]: { () -> () } } = {}

function InputController.On(action: string, fn: () -> ())
	listeners[action] = listeners[action] or {}
	table.insert(listeners[action], fn)
end

local function fire(action: string)
	for _, fn in listeners[action] or {} do
		fn()
	end
end

-- rebindable actions that fire once on press
local PRESS = { ballCam = true, help = true, reset = true, pause = true, launchBall = true, pinchDrill = true, unlimitedBoost = true }
-- fixed developer / training keys (only when the key isn't bound to something else)
local FIXED = {
	F3 = "debug", P = "prediction",
	One = "car1", Two = "car2", Three = "car3", Four = "car4", Five = "car5", Six = "car6",
}

local Glyphs: any = nil
local function menuActive(): boolean
	if Glyphs == nil then
		local ok, m = pcall(function() return require(script.Parent.InputGlyphs) end)
		Glyphs = if ok then m else false
	end
	return Glyphs and (Glyphs.MenuActive() or Glyphs.JustClosed()) or false
end

-- input -> (device, name). Pad buttons count as pad even when a driver / remote input reports a keyboard type.
local function identify(input: InputObject): (string?, string?)
	local t = input.UserInputType
	if t == Enum.UserInputType.MouseButton1 or t == Enum.UserInputType.MouseButton2 or t == Enum.UserInputType.MouseButton3 then
		return "kb", t.Name
	end
	local kc = input.KeyCode
	if kc == Enum.KeyCode.Unknown then return nil, nil end
	local n = kc.Name
	if string.sub(t.Name, 1, 7) == "Gamepad" or string.sub(n, 1, 6) == "Button" or string.sub(n, 1, 4) == "DPad" then
		return "pad", n
	end
	if t == Enum.UserInputType.Keyboard then return "kb", n end
	return nil, nil
end

-- pause + scoreboard on one input: tap = pause, hold = scoreboard
local TAP = 0.3
local BOARD_AFTER = 0.18
local held: { [string]: { at: number, fromMenu: boolean } } = {} -- device -> the shared input being held

UIS.InputEnded:Connect(function(input)
	local device, name = identify(input)
	if not device or not name then return end
	local h = held[device]
	if h and Keybinds.Shared(device) == name then
		held[device] = nil
		if os.clock() - h.at < TAP and not h.fromMenu and not menuActive() then
			fire("pause")
		end
	end
end)

UIS.InputBegan:Connect(function(input, processed)
	local device, name = identify(input)
	if not device or not name then return end
	-- Roblox flags the pad's Select as processed (its UI-navigation binding); everything else processed (chat, a
	-- focused text box, a selected button) isn't ours
	if processed and not (device == "pad" and name == "ButtonSelect") then return end
	if Keybinds.Shared(device) == name then
		held[device] = { at = os.clock(), fromMenu = menuActive() } -- the tap that closes a menu must not reopen the pause
		return
	end
	local matched = Keybinds.Match(device, name)
	if device == "pad" and menuActive() then
		return -- in a menu the pad navigates; its buttons aren't gameplay actions there
	end
	for _, id in matched do
		if PRESS[id] then
			if toggles[id] ~= nil then toggles[id] = not toggles[id] end
			fire(id)
		end
	end
	if device == "kb" and #matched == 0 and FIXED[name] then
		local id = FIXED[name]
		if toggles[id] ~= nil then toggles[id] = not toggles[id] end
		fire(id)
	end
	-- Start / Options: Roblox usually keeps it for its menu, but if it reaches the game it pauses
	if device == "pad" and name == "ButtonStart" and not table.find(matched, "pause") then
		fire("pause")
	end
end)

function InputController.Toggle(name: string): boolean
	return toggles[name] == true
end

-- scoreboard is held, not toggled (after a short moment when it shares the pause input, so a tap doesn't flash it)
function InputController.ScoreboardHeld(): boolean
	for _, device in { "kb", "pad" } do
		if Keybinds.Shared(device) then
			local h = held[device]
			if h and os.clock() - h.at >= BOARD_AFTER then return true end
		elseif (if device == "kb" then Keybinds.KbDown("scoreboard") else Keybinds.PadDown("scoreboard")) then
			return true
		end
	end
	return false
end

local GS: any = nil
local function deadzone(): number
	if GS == nil then
		local ok, m = pcall(function() return require(script.Parent.GraphicsSettings) end)
		GS = if ok then m else false
	end
	local v = GS and GS.Get("deadzone")
	return if type(v) == "number" then math.clamp(v, 0, 0.5) else 0.12
end

local DEADZONE = 0.12
local function dz(v: number): number
	if math.abs(v) < DEADZONE then
		return 0
	end
	return math.sign(v) * (math.abs(v) - DEADZONE) / (1 - DEADZONE)
end

local function b(v: boolean): number
	return if v then 1 else 0
end

-- Returns a fresh controls table. `airborne` enables the air-roll modifier behaviour.
function InputController.Read(airborne: boolean)
	local K = Keybinds
	K.Poll()
	-- keyboard: forward/back also pitch (nose down / up), left/right also yaw
	local fwd, back = b(K.KbDown("throttle")), b(K.KbDown("reverse"))
	local throttle = fwd - back
	local pitch = back - fwd
	local steer = b(K.KbDown("steerRight")) - b(K.KbDown("steerLeft"))
	local roll = b(K.KbDown("airRollRight")) - b(K.KbDown("airRollLeft"))
	local jump = K.KbDown("jump")
	local boost = K.KbDown("boost")
	local handbrake = K.KbDown("powerslide")

	-- gamepad: the left stick is fixed; the rest follows the bindings
	if UIS.GamepadEnabled then
		DEADZONE = deadzone()
		for _, st in UIS:GetGamepadState(Enum.UserInputType.Gamepad1) do
			if st.KeyCode == Enum.KeyCode.Thumbstick1 then
				steer += dz(st.Position.X)
				pitch += -dz(st.Position.Y)
			end
		end
		throttle += K.PadAxis("throttle") - K.PadAxis("reverse")
		jump = jump or K.PadDown("jump")
		boost = boost or K.PadDown("boost")
		handbrake = handbrake or K.PadDown("powerslide")
		roll += b(K.PadDown("airRollRight")) - b(K.PadDown("airRollLeft"))
	end

	steer = math.clamp(steer, -1, 1)
	local yaw = steer
	-- RL "Air Roll" binding: while held in the air, left/right rolls instead of yawing
	if airborne and handbrake then
		roll = math.clamp(roll + steer, -1, 1)
		yaw = 0
	end

	return {
		throttle = math.clamp(throttle, -1, 1),
		steer = steer,
		pitch = math.clamp(pitch, -1, 1),
		yaw = math.clamp(yaw, -1, 1),
		roll = math.clamp(roll, -1, 1),
		jump = jump, boost = boost, handbrake = handbrake,
	}
end

return InputController
