--!strict
-- Keybinds.lua: the player's controls, one binding per action per device ("kb" = keyboard / mouse, "pad" = gamepad),
-- editable in AJUSTES › BOTONES and saved with the profile. Everything that reads buttons for gameplay goes through
-- here (InputController), and every prompt that shows a gameplay button asks here (InputGlyphs), so a rebind changes
-- the car and the icons at once.
--   * bindings are input names: a KeyCode name ("Space", "ButtonA", "DPadUp") or a mouse button ("MouseButton2");
--   * binding a key that another action already uses SWAPS them (nothing is ever left unbound by accident), except
--     pause + scoreboard, which may share one input: tap = pause, hold = scoreboard (default: the pad's Select);
--   * the left stick always steers / pitches on a pad (not rebindable), and the keyboard keeps arrow keys and the
--     mouse buttons as extra defaults (Space/RMB jump, Shift/LMB boost) until something else takes them.
local UIS = game:GetService("UserInputService")

local Keybinds = {}

-- id, label, keyboard default, pad default (nil = not rebindable on that device), group
Keybinds.ACTIONS = {
	{ id = "throttle", label = "ACELERAR", kb = "W", pad = "ButtonR2", group = "drive" },
	{ id = "reverse", label = "FRENAR / REVERSA", kb = "S", pad = "ButtonL2", group = "drive" },
	{ id = "steerLeft", label = "GIRAR A LA IZQUIERDA", kb = "A", pad = nil, group = "drive" },
	{ id = "steerRight", label = "GIRAR A LA DERECHA", kb = "D", pad = nil, group = "drive" },
	{ id = "jump", label = "SALTAR", kb = "Space", pad = "ButtonA", group = "drive" },
	{ id = "boost", label = "TURBO", kb = "LeftShift", pad = "ButtonB", group = "drive" },
	{ id = "powerslide", label = "DERRAPE / GIRO AÉREO", kb = "LeftControl", pad = "ButtonX", group = "drive" },
	{ id = "airRollLeft", label = "GIRO AÉREO IZQUIERDA", kb = "Q", pad = "ButtonL1", group = "drive" },
	{ id = "airRollRight", label = "GIRO AÉREO DERECHA", kb = "E", pad = "ButtonR1", group = "drive" },
	{ id = "ballCam", label = "CÁMARA BALÓN", kb = "C", pad = "ButtonY", group = "view" },
	{ id = "scoreboard", label = "MARCADOR (MANTENER)", kb = "CapsLock", pad = "ButtonSelect", group = "view" },
	{ id = "pause", label = "PAUSA", kb = "M", pad = "ButtonSelect", group = "view" },
	{ id = "help", label = "AYUDA DE CONTROLES", kb = "H", pad = "ButtonR3", group = "view" },
	{ id = "reset", label = "ENTRENAMIENTO: REINICIAR", kb = "R", pad = "DPadDown", group = "training" },
	{ id = "launchBall", label = "ENTRENAMIENTO: LANZAR BALÓN", kb = "G", pad = "DPadRight", group = "training" },
	{ id = "pinchDrill", label = "ENTRENAMIENTO: PINCH", kb = "T", pad = "DPadLeft", group = "training" },
	{ id = "unlimitedBoost", label = "ENTRENAMIENTO: TURBO INFINITO", kb = "B", pad = "DPadUp", group = "training" },
}
local BY_ID: { [string]: any } = {}
for _, a in Keybinds.ACTIONS do BY_ID[a.id] = a end

-- extra keyboard defaults (not shown, not saved); dropped as soon as the input is bound to something else
local ALT_DEFAULT = {
	throttle = "Up", reverse = "Down", steerLeft = "Left", steerRight = "Right", jump = "MouseButton2", boost = "MouseButton1",
}
-- actions that may share one input (tap / hold)
local SHARE = { pause = "scoreboard", scoreboard = "pause" }

-- can't be bound: Roblox's own keys, chat, the capture's cancel key, the menu button, the sticks
local RESERVED = {
	Escape = true, Backspace = true, Slash = true, Unknown = true, ButtonStart = true, Thumbstick1 = true, Thumbstick2 = true,
	F1 = true, F2 = true, F3 = true, F4 = true, F5 = true, F6 = true, F7 = true, F8 = true, F9 = true, F10 = true, F11 = true, F12 = true,
}

-- Enum lookup that returns nil for an unknown name (indexing an Enum with a bad name throws)
local function enumItem(enum: any, name: string): any
	local ok, v = pcall(function() return enum[name] end)
	return if ok then v else nil
end

local binds: { kb: { [string]: string }, pad: { [string]: string } } = { kb = {}, pad = {} }
local alt: { [string]: string } = {}
local listeners: { () -> () } = {}

local function defaults()
	binds = { kb = {}, pad = {} }
	for _, a in Keybinds.ACTIONS do
		binds.kb[a.id] = a.kb
		if a.pad then binds.pad[a.id] = a.pad end
	end
	alt = table.clone(ALT_DEFAULT)
end
defaults()

local function changed()
	for _, fn in table.clone(listeners) do task.spawn(fn) end
end

function Keybinds.OnChanged(fn: () -> ()): () -> ()
	table.insert(listeners, fn)
	return function()
		local i = table.find(listeners, fn)
		if i then table.remove(listeners, i) end
	end
end

function Keybinds.Get(device: string, id: string): string?
	return binds[device] and binds[device][id]
end

function Keybinds.Action(id: string): any
	return BY_ID[id]
end

-- is this a valid binding for the device? (used by the capture screen)
function Keybinds.Accepts(device: string, name: string): boolean
	if RESERVED[name] then return false end
	if device == "pad" then
		return string.sub(name, 1, 6) == "Button" or string.sub(name, 1, 4) == "DPad"
	end
	if name == "MouseButton2" or name == "MouseButton3" then return true end
	if string.sub(name, 1, 6) == "Button" or string.sub(name, 1, 4) == "DPad" or string.sub(name, 1, 5) == "Mouse" then return false end
	return enumItem(Enum.KeyCode, name) ~= nil
end

-- bind; returns the action it swapped with (or nil)
function Keybinds.Set(device: string, id: string, name: string): string?
	local a = BY_ID[id]
	if not a or (device == "pad" and not a.pad) or not Keybinds.Accepts(device, name) then return nil end
	local t = binds[device]
	local old = t[id]
	if old == name then return nil end
	local swapped = nil
	for other, v in t do
		if other ~= id and v == name and SHARE[id] ~= other then
			t[other] = old
			swapped = other
		end
	end
	t[id] = name
	if device == "kb" then
		for k, v in alt do
			if v == name then alt[k] = nil end
		end
	end
	changed()
	return swapped
end

function Keybinds.ResetDefaults()
	defaults()
	changed()
end

-- saved blob { kb = { id = name }, pad = { id = name } }; anything unknown or invalid is ignored
function Keybinds.Load(blob: any)
	defaults()
	if type(blob) == "table" then
		for _, device in { "kb", "pad" } do
			local t = blob[device]
			if type(t) == "table" then
				for id, name in t do
					local a = BY_ID[id]
					if a and type(name) == "string" and (device == "kb" or a.pad) and Keybinds.Accepts(device, name) then
						binds[device][id] = name
					end
				end
			end
		end
		for k, v in alt do
			for _, bound in binds.kb do
				if bound == v then alt[k] = nil end
			end
		end
	end
	changed()
end

function Keybinds.Export(): any
	return { kb = table.clone(binds.kb), pad = table.clone(binds.pad) }
end

-- actions bound to this input on this device
function Keybinds.Match(device: string, name: string): { string }
	local out = {}
	for id, v in binds[device] do
		if v == name then table.insert(out, id) end
	end
	if device == "kb" then
		for id, v in alt do
			if v == name and not table.find(out, id) then table.insert(out, id) end
		end
	end
	return out
end

-- does pause share its input with the scoreboard on this device? (tap = pause, hold = scoreboard)
function Keybinds.Shared(device: string): string?
	local p = binds[device].pause
	return if p ~= nil and p == binds[device].scoreboard then p else nil
end

-- ---------------------------------------------------------------- reading the devices
local PAD = Enum.UserInputType.Gamepad1
local triggers = { ButtonL2 = 0, ButtonR2 = 0 }

-- once per read: analog triggers
function Keybinds.Poll()
	triggers.ButtonL2, triggers.ButtonR2 = 0, 0
	if not UIS.GamepadEnabled then return end
	for _, s in UIS:GetGamepadState(PAD) do
		if s.KeyCode == Enum.KeyCode.ButtonL2 then triggers.ButtonL2 = s.Position.Z
		elseif s.KeyCode == Enum.KeyCode.ButtonR2 then triggers.ButtonR2 = s.Position.Z end
	end
end

local function kbDown(name: string?): boolean
	if not name then return false end
	if string.sub(name, 1, 11) == "MouseButton" then
		local t = enumItem(Enum.UserInputType, name)
		return t ~= nil and UIS:IsMouseButtonPressed(t)
	end
	local kc = enumItem(Enum.KeyCode, name)
	return kc ~= nil and UIS:IsKeyDown(kc)
end

-- 0..1: analog for a trigger, 0/1 for a button
function Keybinds.PadAxis(id: string): number
	local name = binds.pad[id]
	if not name or not UIS.GamepadEnabled then return 0 end
	if triggers[name] ~= nil then return triggers[name] end
	local kc = enumItem(Enum.KeyCode, name)
	return if kc ~= nil and UIS:IsGamepadButtonDown(PAD, kc) then 1 else 0
end

function Keybinds.PadDown(id: string): boolean
	return Keybinds.PadAxis(id) > 0.4
end

function Keybinds.KbDown(id: string): boolean
	return kbDown(binds.kb[id]) or kbDown(alt[id])
end

function Keybinds.Down(id: string): boolean
	return Keybinds.KbDown(id) or Keybinds.PadDown(id)
end

-- ---------------------------------------------------------------- display
local KEY_LABEL = {
	Space = "ESPACIO", LeftShift = "SHIFT", RightShift = "SHIFT DER.", LeftControl = "CTRL", RightControl = "CTRL DER.",
	LeftAlt = "ALT", RightAlt = "ALT GR", CapsLock = "BLOQ MAYÚS", Return = "ENTER", Tab = "TAB", Up = "↑", Down = "↓",
	Left = "←", Right = "→", MouseButton1 = "CLIC IZQ.", MouseButton2 = "CLIC DER.", MouseButton3 = "RUEDA",
	Zero = "0", One = "1", Two = "2", Three = "3", Four = "4", Five = "5", Six = "6", Seven = "7", Eight = "8", Nine = "9",
	Comma = ",", Period = ".", Semicolon = "Ñ", Minus = "-", Plus = "+", Quote = "´", LeftBracket = "[", RightBracket = "]",
	BackSlash = "\\", Insert = "INSERT", Delete = "SUPR", Home = "INICIO", End = "FIN", PageUp = "RE PÁG", PageDown = "AV PÁG",
	KeypadZero = "NUM 0", KeypadOne = "NUM 1", KeypadTwo = "NUM 2", KeypadThree = "NUM 3", KeypadFour = "NUM 4",
	KeypadFive = "NUM 5", KeypadSix = "NUM 6", KeypadSeven = "NUM 7", KeypadEight = "NUM 8", KeypadNine = "NUM 9",
	KeypadEnter = "NUM ENTER", KeypadPlus = "NUM +", KeypadMinus = "NUM -", KeypadMultiply = "NUM *", KeypadDivide = "NUM /",
	KeypadPeriod = "NUM .", LessThan = "<",
}
function Keybinds.Label(name: string?): string
	if not name then return "—" end
	return KEY_LABEL[name] or string.upper(name)
end

-- the keyboard label of an action ("W", "ESPACIO"...)
function Keybinds.KbLabel(id: string): string
	return Keybinds.Label(binds.kb[id])
end

-- the pad KeyCode of an action (for its glyph), nil if none
function Keybinds.PadKeyCode(id: string): Enum.KeyCode?
	local name = binds.pad[id]
	return if name then enumItem(Enum.KeyCode, name) else nil
end

return Keybinds
