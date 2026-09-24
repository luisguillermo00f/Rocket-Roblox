--!strict
-- BoostPadVisuals.lua: the 34 Soccar pads, RL look. Purely visual; pickup logic lives in World (RocketSim BoostPad).
--   small pad: dark recessed plate, glowing gold ring + inner disc that breathes
--   big pad:   plate with a gold ring, a floating neon orb with a rotating halo ring, a soft light column, sparks
--   picked up: flash + pop, then the pad sits dark; on respawn it grows back with an overshoot
local RenderMap = require(script.Parent.RenderMap)
local GS = require(script.Parent.GraphicsSettings)
local S = RenderMap.S

local BoostPadVisuals = {}
BoostPadVisuals.__index = BoostPadVisuals

local GOLD = Color3.fromRGB(255, 142, 24) -- neon blooms toward yellow, so the base sits orange
local HOT = Color3.fromRGB(255, 200, 110)
local DIM = Color3.fromRGB(64, 58, 50)
local PLATE = Color3.fromRGB(34, 36, 42)
local ROT = CFrame.Angles(0, 0, math.rad(90)) -- cylinder axis X -> up

local function part(folder: Instance, shape: Enum.PartType, size: Vector3, cf: CFrame, color: Color3, mat: Enum.Material): Part
	local p = Instance.new("Part")
	p.Shape = shape
	p.Size = size
	p.CFrame = cf
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Material = mat
	p.Color = color
	p.Parent = folder
	return p
end

function BoostPadVisuals.new(pads: { any }, parent: Instance)
	local self = setmetatable({ items = {} }, BoostPadVisuals)
	local folder = Instance.new("Folder")
	folder.Name = "BoostPads"
	folder.Parent = parent
	for _, pad in pads do
		local base = RenderMap.Pos(Vector3.new(pad.pos.X, pad.pos.Y, 0))
		local big = pad.isBig
		local r = (if big then 160 else 78) * S -- visual size only; pickup radius lives in World
		local it: { [string]: any } = { pad = pad, big = big, base = base, wasActive = pad.isActive, grow = 1 }
		-- plate + bevel
		local plate = part(folder, Enum.PartType.Cylinder, Vector3.new(0.14, r * 2, r * 2), CFrame.new(base + Vector3.new(0, 0.07, 0)) * ROT, PLATE, Enum.Material.Metal)
		plate.Reflectance = 0.08
		part(folder, Enum.PartType.Cylinder, Vector3.new(0.16, r * 2.12, r * 2.12), CFrame.new(base + Vector3.new(0, 0.05, 0)) * ROT, Color3.fromRGB(18, 18, 22), Enum.Material.SmoothPlastic)
		-- glowing ring (outer neon disc minus a plate disc on top)
		local ringR = r * (if big then 1.62 else 1.55)
		it.ring = part(folder, Enum.PartType.Cylinder, Vector3.new(0.16, ringR, ringR), CFrame.new(base + Vector3.new(0, 0.1, 0)) * ROT, GOLD, Enum.Material.Neon)
		part(folder, Enum.PartType.Cylinder, Vector3.new(0.17, ringR * 0.84, ringR * 0.84), CFrame.new(base + Vector3.new(0, 0.11, 0)) * ROT, PLATE, Enum.Material.Metal)
		if big then
			it.orbY = 3.3
			it.orb = part(folder, Enum.PartType.Ball, Vector3.new(2.4, 2.4, 2.4), CFrame.new(base + Vector3.new(0, it.orbY, 0)), GOLD, Enum.Material.Neon)
			it.shell = part(folder, Enum.PartType.Ball, Vector3.new(3.1, 3.1, 3.1), CFrame.new(base + Vector3.new(0, it.orbY, 0)), HOT, Enum.Material.ForceField)
			-- halo: a ring of small neon segments (no torus primitive), spun as one rigid set
			it.halo = {}
			for k = 1, 14 do
				table.insert(it.halo, part(folder, Enum.PartType.Block, Vector3.new(0.12, 0.12, 0.85), CFrame.new(base), GOLD, Enum.Material.Neon))
			end
			-- light column: a camera-facing beam from the plate to above the orb
			local a0 = Instance.new("Attachment"); a0.Parent = plate; a0.WorldPosition = base + Vector3.new(0, 0.9, 0)
			local a1 = Instance.new("Attachment"); a1.Parent = plate; a1.WorldPosition = base + Vector3.new(0, 7.5, 0)
			local beam = Instance.new("Beam")
			beam.Attachment0 = a0; beam.Attachment1 = a1
			beam.Width0 = r * 1.1; beam.Width1 = 0.6
			beam.FaceCamera = true
			beam.LightEmission = 1
			beam.LightInfluence = 0
			beam.Color = ColorSequence.new(HOT, GOLD)
			beam.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1), NumberSequenceKeypoint.new(0.15, 0.78), NumberSequenceKeypoint.new(0.5, 0.86), NumberSequenceKeypoint.new(1, 1) })
			beam.Parent = plate
			it.beam = beam
			local light = Instance.new("PointLight")
			light.Color = GOLD; light.Range = 14; light.Brightness = 1.6; light.Shadows = false
			light.Parent = it.orb
			it.light = light
			local sp = Instance.new("ParticleEmitter")
			sp.Color = ColorSequence.new(HOT, GOLD)
			sp.LightEmission = 1
			sp.Rate = 7
			sp.Lifetime = NumberRange.new(0.8, 1.4)
			sp.Speed = NumberRange.new(1.5, 3)
			sp.Size = NumberSequence.new(0.18, 0)
			sp.SpreadAngle = Vector2.new(25, 25)
			sp.EmissionDirection = Enum.NormalId.Top
			sp.Parent = a0
			it.sparks = sp
		else
			it.core = part(folder, Enum.PartType.Cylinder, Vector3.new(0.18, r * 0.95, r * 0.95), CFrame.new(base + Vector3.new(0, 0.13, 0)) * ROT, GOLD, Enum.Material.Neon)
			it.coreSize = it.core.Size
		end
		it.ringSize = it.ring.Size
		table.insert(self.items, it)
	end
	return self
end

-- world-space centre of a pad (studs), for pickup effects
function BoostPadVisuals.PadPos(self: any, pad: any): Vector3
	for _, it in self.items do
		if it.pad == pad then return it.base end
	end
	return RenderMap.Pos(Vector3.new(pad.pos.X, pad.pos.Y, 0))
end

-- property write only when the value changed (Roblox re-uploads a part on every write, even with the same value)
local function set(it: any, key: string, inst: Instance, prop: string, v: any)
	if it[key] ~= v then
		it[key] = v;
		(inst :: any)[prop] = v
	end
end

local WHITE = Color3.new(1, 1, 1)

function BoostPadVisuals.Update(self: any, t: number)
	local pm = GS.ParticleMult()
	local moveParts, moveCFs = {}, {}
	for i, it in self.items do
		local active = it.pad.isActive
		if active ~= it.wasActive then
			it.wasActive = active
			if active then it.grow = 0 else it.popT = t end
		end
		if it.grow < 1 then it.grow = math.min(1, it.grow + 1 / 22) end
		local g = it.grow
		local scale = g * (if g < 1 then 1 + math.sin(g * math.pi) * 0.35 else 1)
		local popping = it.popT ~= nil and t - it.popT < 0.14
		if popping then scale = 1 + (t - it.popT) / 0.14 * 0.6 elseif it.popT then it.popT = nil end
		local on = active or popping
		-- breathing quantised to a few steps: colours get rewritten a handful of times per second, not every frame
		local breathe = math.floor((0.5 + 0.5 * math.sin(t * 3 + i)) * 5 + 0.5) / 5
		set(it, "_rc", it.ring, "Color", if popping then WHITE elseif active then GOLD:Lerp(HOT, breathe * 0.4) else DIM)
		set(it, "_rm", it.ring, "Material", if on then Enum.Material.Neon else Enum.Material.SmoothPlastic)
		if it.big then
			local sc = if on then math.max(scale, 0.01) else 0.01
			set(it, "_os", it.orb, "Size", Vector3.new(2.4, 2.4, 2.4) * sc)
			set(it, "_ot", it.orb, "Transparency", if not on then 1 elseif popping then math.floor((t - it.popT) / 0.14 * 4) / 4 else 0)
			set(it, "_oc", it.orb, "Color", if popping then WHITE else GOLD)
			set(it, "_ss", it.shell, "Size", Vector3.new(3.1, 3.1, 3.1) * sc * (1 + 0.06 * breathe))
			set(it, "_st", it.shell, "Transparency", if on then 0.35 else 1)
			set(it, "_be", it.beam, "Enabled", on)
			set(it, "_sp", it.sparks, "Enabled", active and pm > 0)
			set(it, "_sr", it.sparks, "Rate", 7 * pm)
			set(it, "_lb", it.light, "Brightness", if on then 1.4 + 0.6 * breathe else 0)
			for k, seg in it.halo do
				set(it, "_h" .. k, seg, "Transparency", if on then 0 else 1)
			end
			if on then
				-- orb bob + halo spin: every frame, batched into one BulkMoveTo for all big pads
				local c = CFrame.new(it.base + Vector3.new(0, it.orbY + math.sin(t * 2 + i) * 0.25, 0))
				table.insert(moveParts, it.orb); table.insert(moveCFs, c)
				table.insert(moveParts, it.shell); table.insert(moveCFs, c)
				local tilt = c * CFrame.Angles(math.rad(18) + math.sin(t) * 0.12, t * 1.6, 0)
				local rad = 2.1 * sc
				for k, seg in it.halo do
					table.insert(moveParts, seg)
					table.insert(moveCFs, tilt * CFrame.Angles(0, (k / #it.halo) * math.pi * 2, 0) * CFrame.new(rad, 0, 0))
				end
			end
		else
			local sc = if on then scale else 1
			set(it, "_cs", it.core, "Size", Vector3.new(it.coreSize.X, it.coreSize.Y * sc, it.coreSize.Z * sc))
			set(it, "_cc", it.core, "Color", if popping then WHITE elseif active then GOLD:Lerp(HOT, breathe * 0.5) else DIM)
			set(it, "_cm", it.core, "Material", if on then Enum.Material.Neon else Enum.Material.SmoothPlastic)
			set(it, "_ct", it.core, "Transparency", if popping then math.floor((t - it.popT) / 0.14 * 4) / 4 else 0)
		end
	end
	if #moveParts > 0 then
		workspace:BulkMoveTo(moveParts, moveCFs, Enum.BulkMoveMode.FireCFrameChanged)
	end
end

return BoostPadVisuals
