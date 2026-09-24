--!strict
-- Sounds.lua: every sound in the game, in one place (client only).
--   * a catalogue of Creator Store sounds (Pro Sound Effects / Roblox Resources / APM stings, all free and public)
--   * Sounds.Play(name, pos?, opts?)   one-shots: 2D (UI, stingers) or 3D at a world point (hits, explosions)
--   * Sounds.CarRig(car, part)          engine / boost / supersonic wind loops for one car visual (CarVisual owns it)
--   * Sounds.Message(text)              the centre message ("3", "2", "1", "¡YA!", "¡PRÓRROGA!") -> beeps / horn
--   * Sounds.Result(won)                end-of-round stinger;  Sounds.Ambient(on) the stadium crowd bed
--   * Sounds.Init()                     UI: every button in the PlayerGui clicks and ticks on hover / gamepad focus
-- Everything goes through one SoundGroup ("SFX") so a single volume controls it all.
local Players = game:GetService("Players")
local SoundService = game:GetService("SoundService")
local RunService = game:GetService("RunService")

local Sounds = {}

local ID = {
	engine = 80317022777602, -- Car-Engine-Loop (Roblox Resources)
	boost = 135314203986462, -- rocket loop
	wind = 90482517852713, -- wind draft (supersonic)
	kick1 = 9119326824, kick2 = 9119326976, kick3 = 9119327493, kick4 = 9119329104, -- Soccer Ball Kicks (PSE)
	jump = 9114374642, flip = 9114373678, -- Fast Pass By Airy Whooshes (PSE)
	whoosh = 9125920594, -- Searing Whoosh (PSE)
	goalBoom = 138533090376585, -- Explosion Blast Impact Boom
	boom = 140278004623742, -- explosion
	demoCrash = 9116546326, -- Metal Crash 2 (PSE)
	bump = 132846127748664, -- metal impact
	crowdGoal = 94222923580383, -- crowd cheering, goal
	crowdBed = 9112766176, -- Crowd Cheer And Applause loop (PSE)
	horn = 9114075901, -- Diesel Truck Air Horn (PSE)
	beep = 7743999789, -- countdown beep
	click = 9119717523, tick = 9119717529, -- Switch Click (PSE)
	pickupBig = 96137646682236, -- power-up
	win = 9045808811, -- "We Good" sting (APM)
	lose = 1840076509, -- "Through the Roof" sting (APM)
	rattle = 9113923314, -- Coral On Granite (PSE): a ball dropping into a cup
	turbo = 80948439885942, -- turbo dash
}
Sounds.ID = ID

local group: SoundGroup? = nil
local function sfxGroup(): SoundGroup
	if group and group.Parent then return group end
	local g = SoundService:FindFirstChild("SFX") :: SoundGroup?
	if not g then
		g = Instance.new("SoundGroup")
		g.Name = "SFX"
		g.Volume = 0.8
		g.Parent = SoundService
	end
	group = g
	return g :: SoundGroup
end

local emitters: Folder? = nil
local function emitterFolder(): Folder
	if emitters and emitters.Parent then return emitters end
	local f = Instance.new("Folder")
	f.Name = "SfxEmitters"
	f.Parent = workspace
	emitters = f
	return f
end

local function make(name: string, parent: Instance, volume: number?, looped: boolean?): Sound
	local s = Instance.new("Sound")
	s.Name = name
	s.SoundId = "rbxassetid://" .. tostring(ID[name] or name)
	s.Volume = volume or 0.5
	s.Looped = looped == true
	s.SoundGroup = sfxGroup()
	s.Parent = parent
	return s
end

-- one-shot. opts: volume, pitch (PlaybackSpeed), stopAfter (s), min / max roll-off distances (studs)
function Sounds.Play(name: string, pos: Vector3?, opts: { [string]: any }?)
	local o = opts or {}
	local s
	if pos then
		local a = Instance.new("Part")
		a.Name = "Sfx_" .. name
		a.Anchored = true
		a.CanCollide = false
		a.CanQuery = false
		a.CanTouch = false
		a.Transparency = 1
		a.Size = Vector3.one
		a.Position = pos
		a.Parent = emitterFolder()
		s = make(name, a, o.volume or 0.6)
		s.RollOffMode = Enum.RollOffMode.InverseTapered
		s.RollOffMinDistance = o.min or 18
		s.RollOffMaxDistance = o.max or 600
		s.Ended:Once(function() a:Destroy() end)
		task.delay(o.stopAfter or 12, function() if a.Parent then a:Destroy() end end)
	else
		s = make(name, sfxGroup(), o.volume or 0.5)
		s.Ended:Once(function() s:Destroy() end)
		task.delay(o.stopAfter or 12, function() if s.Parent then s:Destroy() end end)
	end
	s.PlaybackSpeed = o.pitch or 1
	s:Play()
	return s
end

-- a random variation of a family ("kick" -> kick1..kick4)
function Sounds.PlayVariant(prefix: string, count: number, pos: Vector3?, opts: { [string]: any }?)
	return Sounds.Play(prefix .. math.random(1, count), pos, opts)
end

-- ---------------------------------------------------------------- per-car loops
-- rig: engine hum pitched by speed, rocket boost, wind when supersonic, whoosh on take-off
function Sounds.CarRig(part: BasePart): any
	local att = Instance.new("Attachment")
	att.Name = "CarAudio"
	att.Parent = part
	local function loop(name: string, vol: number): Sound
		local s = make(name, att, 0, true)
		s.RollOffMode = Enum.RollOffMode.InverseTapered
		s.RollOffMinDistance = 14
		s.RollOffMaxDistance = 320
		s:SetAttribute("base", vol)
		return s
	end
	local rig = {
		att = att,
		engine = loop("engine", 0.32),
		boost = loop("boost", 0.42),
		wind = loop("wind", 0.3),
		playing = false,
		grounded = true,
		lastWhoosh = 0,
	}
	return rig
end

local function fade(s: Sound, target: number, dt: number, rate: number)
	local v = s.Volume
	v += math.clamp(target - v, -rate * dt, rate * dt)
	s.Volume = v
	if v > 0.001 and not s.IsPlaying then s:Play() elseif v <= 0.001 and s.IsPlaying then s:Pause() end
end

-- per frame: speed (uu/s), boosting, supersonic, wheels on the ground, visible
function Sounds.CarRigUpdate(rig: any, dt: number, speed: number, boosting: boolean, supersonic: boolean, wheels: number, visible: boolean, pos: Vector3?)
	if not visible then
		for _, s in { rig.engine, rig.boost, rig.wind } do
			s.Volume = 0
			if s.IsPlaying then s:Pause() end
		end
		rig.grounded = true
		return
	end
	local k = math.clamp(speed / 2300, 0, 1)
	rig.engine.PlaybackSpeed = 0.75 + k * 0.85 + (if boosting then 0.08 else 0)
	fade(rig.engine, rig.engine:GetAttribute("base") * (0.45 + 0.55 * k), dt, 2)
	fade(rig.boost, if boosting then rig.boost:GetAttribute("base") else 0, dt, 5)
	fade(rig.wind, if supersonic then rig.wind:GetAttribute("base") else 0, dt, 1.5)
	-- take-off whoosh (a jump or driving off a ledge fast) and a landing thump
	local grounded = wheels >= 3
	local now = os.clock()
	if rig.grounded and wheels == 0 and pos and now - rig.lastWhoosh > 0.35 then
		rig.lastWhoosh = now
		Sounds.Play("jump", pos, { volume = 0.35, pitch = 1.1 + math.random() * 0.15, min = 12, max = 250 })
	elseif not rig.grounded and grounded and pos and now - rig.lastWhoosh > 0.35 then
		Sounds.Play("kick4", pos, { volume = 0.25, pitch = 0.55, min = 12, max = 200 })
	end
	if wheels == 0 then rig.grounded = false elseif grounded then rig.grounded = true end
end

function Sounds.CarRigDestroy(rig: any)
	if rig and rig.att then rig.att:Destroy() end
end

-- ---------------------------------------------------------------- game moments
-- a car touches the ball: louder and brighter with the strength (0..1)
function Sounds.Hit(pos: Vector3, strength: number)
	local s = math.clamp(strength, 0, 1)
	Sounds.PlayVariant("kick", 3, pos, { volume = 0.35 + s * 0.6, pitch = 0.85 + s * 0.35, min = 20, max = 500 })
end

function Sounds.Goal(pos: Vector3)
	Sounds.Play("goalBoom", pos, { volume = 0.9, min = 60, max = 2000 })
	Sounds.Play("crowdGoal", nil, { volume = 0.55 })
	task.delay(0.15, function() Sounds.Play("horn", nil, { volume = 0.35, stopAfter = 2.2 }) end)
end

function Sounds.Demolish(pos: Vector3)
	Sounds.Play("demoCrash", pos, { volume = 0.7, min = 30, max = 900, stopAfter = 2.5 })
	Sounds.Play("boom", pos, { volume = 0.6, min = 30, max = 900, pitch = 1.1 })
end

function Sounds.Bump(pos: Vector3)
	Sounds.Play("bump", pos, { volume = 0.45, min = 20, max = 400, stopAfter = 0.8, pitch = 1.2 })
end

function Sounds.Pickup(pos: Vector3?, big: boolean)
	if big then
		Sounds.Play("pickupBig", pos, { volume = 0.35, pitch = 1.3, stopAfter = 1.2, min = 14, max = 200 })
	else
		Sounds.Play("tick", pos, { volume = 0.4, pitch = 1.8, min = 14, max = 150 })
	end
end

-- the centre message of either HUD
local lastMsg, lastMsgAt = "", 0
function Sounds.Message(text: string)
	local now = os.clock()
	if text == lastMsg and now - lastMsgAt < 0.5 then return end
	lastMsg, lastMsgAt = text, now
	if text == "3" or text == "2" or text == "1" then
		Sounds.Play("beep", nil, { volume = 0.5, pitch = 1 })
	elseif text == "¡YA!" then
		Sounds.Play("beep", nil, { volume = 0.6, pitch = 1.6 })
		Sounds.Play("whoosh", nil, { volume = 0.25 })
	elseif text == "¡PRÓRROGA!" or text == "¡GOL DE ORO!" or text == "¡FRENESÍ!" then
		Sounds.Play("horn", nil, { volume = 0.4, stopAfter = 1.6 })
	end
end

-- a big centre banner in a minigame
function Sounds.Banner()
	Sounds.Play("whoosh", nil, { volume = 0.22, pitch = 1.15 })
end

function Sounds.Result(won: boolean?)
	Sounds.Play("horn", nil, { volume = 0.35, stopAfter = 1.8 })
	task.delay(0.6, function()
		Sounds.Play(if won then "win" else "lose", nil, { volume = 0.5 })
	end)
end

-- the stadium crowd bed during a Soccar match
local bed: Sound? = nil
function Sounds.Ambient(on: boolean)
	if on then
		if not bed then
			bed = make("crowdBed", sfxGroup(), 0, true)
		end
		local b = bed :: Sound
		b.Volume = 0.12
		if not b.IsPlaying then b:Play() end
	elseif bed then
		bed:Stop()
	end
end

-- ---------------------------------------------------------------- UI
local hooked = setmetatable({}, { __mode = "k" })
local lastTick = 0
local function hookButton(b: GuiButton)
	if hooked[b] then return end
	hooked[b] = true
	b.Activated:Connect(function()
		Sounds.Play("click", nil, { volume = 0.45 })
	end)
	local function tick()
		local now = os.clock()
		if now - lastTick < 0.06 then return end
		lastTick = now
		Sounds.Play("tick", nil, { volume = 0.18, pitch = 1.5 })
	end
	b.MouseEnter:Connect(tick)
	b.SelectionGained:Connect(tick)
end

local inited = false
function Sounds.Init()
	if inited or not RunService:IsClient() then return end
	inited = true
	sfxGroup()
	local pg = Players.LocalPlayer:WaitForChild("PlayerGui")
	for _, d in pg:GetDescendants() do
		if d:IsA("GuiButton") then hookButton(d) end
	end
	pg.DescendantAdded:Connect(function(d)
		if d:IsA("GuiButton") then hookButton(d) end
	end)
	-- preload the common ones so the first hit / click isn't silent
	task.spawn(function()
		local list = {}
		for name in ID do
			local s = Instance.new("Sound")
			s.SoundId = "rbxassetid://" .. tostring(ID[name])
			table.insert(list, s)
		end
		pcall(function() game:GetService("ContentProvider"):PreloadAsync(list) end)
	end)
end

return Sounds
