--!strict
-- PartyLobbyArena.lua: The vibrant, chaotic, high-energy Party Mode Playground.
-- Underground festival skatepark at Y = 500: Showcase stage, Jumbotron, mega-ramps,
-- bouncy trampoline launch pad, chrome pinball bumpers, giant party ball, and stadium lights.

local Lighting = game:GetService("Lighting")
local TweenService = game:GetService("TweenService")
local PartyConfig = require(script.Parent.PartyConfig)

local PartyLobbyArena = {}
PartyLobbyArena.__index = PartyLobbyArena

local ORIGIN = PartyConfig.ORIGIN
local floorY = ORIGIN.Y

local function part(parent: Instance, name: string, size: Vector3, cf: CFrame, color: Color3, material: Enum.Material?, canCollide: boolean?): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Size = size
	p.CFrame = cf
	p.Color = color
	p.Material = material or Enum.Material.SmoothPlastic
	p.Anchored = true
	p.CanCollide = if canCollide ~= nil then canCollide else true
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Parent = parent
	return p
end

local function cylinder(parent: Instance, name: string, size: Vector3, cf: CFrame, color: Color3, material: Enum.Material?, canCollide: boolean?): Part
	local p = part(parent, name, size, cf, color, material, canCollide)
	p.Shape = Enum.PartType.Cylinder
	return p
end

function PartyLobbyArena.Build(container: Instance, partyCode: string)
	local root = Instance.new("Folder")
	root.Name = "PartyLobbyMap"
	root.Parent = container

	local sizeW, sizeL = 190, 200
	local halfW = sizeW / 2
	local halfL = sizeL / 2
	local wallH = 28

	-- 1. Main Asphalt Playground Floor
	local floor = part(root, "PlaygroundFloor", Vector3.new(sizeW, 4, sizeL), CFrame.new(ORIGIN.X, floorY - 2, ORIGIN.Z), Color3.fromRGB(24, 26, 32), Enum.Material.Concrete)
	floor.CastShadow = true

	-- Painted street-art track lines
	cylinder(root, "CenterCircle", Vector3.new(0.15, 52, 52), CFrame.new(ORIGIN.X, floorY + 0.05, ORIGIN.Z) * CFrame.Angles(0, 0, math.rad(90)), Color3.fromRGB(220, 225, 235), Enum.Material.SmoothPlastic, false)
	cylinder(root, "CenterInner", Vector3.new(0.2, 50, 50), CFrame.new(ORIGIN.X, floorY + 0.06, ORIGIN.Z) * CFrame.Angles(0, 0, math.rad(90)), Color3.fromRGB(24, 26, 32), Enum.Material.Concrete, false)

	-- 2. Perimeter Walls with Industrial Fencing & Neon Edge Trim
	local wallThick = 4
	local walls = {
		{ name = "WallNorth", size = Vector3.new(sizeW + wallThick*2, wallH, wallThick), pos = Vector3.new(0, floorY + wallH/2, -halfL - wallThick/2) },
		{ name = "WallSouth", size = Vector3.new(sizeW + wallThick*2, wallH, wallThick), pos = Vector3.new(0, floorY + wallH/2, halfL + wallThick/2) },
		{ name = "WallWest", size = Vector3.new(wallThick, wallH, sizeL), pos = Vector3.new(-halfW - wallThick/2, floorY + wallH/2, 0) },
		{ name = "WallEast", size = Vector3.new(wallThick, wallH, sizeL), pos = Vector3.new(halfW + wallThick/2, floorY + wallH/2, 0) },
	}
	for _, w in ipairs(walls) do
		part(root, w.name, w.size, CFrame.new(w.pos), Color3.fromRGB(18, 20, 26), Enum.Material.SmoothPlastic)
		-- Top rail with warm festival neon
		local railSize = if w.size.X > w.size.Z then Vector3.new(w.size.X, 0.8, 0.8) else Vector3.new(0.8, 0.8, w.size.Z)
		part(root, w.name .. "Rail", railSize, CFrame.new(w.pos.X, floorY + wallH, w.pos.Z), Color3.fromRGB(255, 140, 30), Enum.Material.Neon, false)
	end

	-- 3. Four Corner Stadium Floodlight Towers (Creates dynamic volumetric party lighting)
	local corners = {
		Vector3.new(-halfW + 8, floorY, -halfL + 8),
		Vector3.new(halfW - 8, floorY, -halfL + 8),
		Vector3.new(-halfW + 8, floorY, halfL - 8),
		Vector3.new(halfW - 8, floorY, halfL - 8),
	}
	for i, cPos in ipairs(corners) do
		local tower = part(root, "LightTower_" .. i, Vector3.new(3, 40, 3), CFrame.new(cPos + Vector3.new(0, 20, 0)), Color3.fromRGB(45, 48, 58), Enum.Material.Metal)
		local head = part(root, "LightHead_" .. i, Vector3.new(8, 4, 3), CFrame.new(cPos + Vector3.new(0, 40, 0)), Color3.fromRGB(30, 32, 40), Enum.Material.Metal)
		
		local colors = { Color3.fromRGB(255, 200, 100), Color3.fromRGB(0, 200, 255), Color3.fromRGB(255, 80, 140), Color3.fromRGB(100, 255, 120) }
		local spot = Instance.new("SpotLight")
		spot.Color = colors[(i - 1) % #colors + 1]
		spot.Range = 120
		spot.Brightness = 2.0
		spot.Angle = 60
		spot.Face = Enum.NormalId.Front
		spot.Parent = head
		head.CFrame = CFrame.lookAt(cPos + Vector3.new(0, 40, 0), ORIGIN + Vector3.new(0, 2, 0))
	end

	-- 4. Overhead Party String Lights (Festoon lights across the arena)
	for s = -30, 30, 30 do
		local cable = part(root, "Cable_" .. s, Vector3.new(sizeW - 20, 0.2, 0.2), CFrame.new(0, floorY + 32, s), Color3.fromRGB(40, 40, 40), Enum.Material.Metal, false)
		for b = -halfW + 30, halfW - 30, 25 do
			local bulb = part(root, "Bulb", Vector3.new(0.8, 0.8, 0.8), CFrame.new(b, floorY + 31.5, s), Color3.fromRGB(255, 220, 150), Enum.Material.Neon, false)
			bulb.Shape = Enum.PartType.Ball
		end
	end

	-- 5. Elevated Showcase Stage & Jumbotron (South Wall)
	local stageY = floorY + 4
	local stageZ = halfL - 32
	local stage = part(root, "ShowcaseStage", Vector3.new(130, 4, 34), CFrame.new(0, floorY + 2, stageZ), Color3.fromRGB(32, 35, 45), Enum.Material.DiamondPlate)
	
	-- Stage Dual Access Ramps
	local function makeWedge(name: string, pos: Vector3, angY: number, size: Vector3, col: Color3): WedgePart
		local w = Instance.new("WedgePart")
		w.Name = name
		w.Size = size
		w.CFrame = CFrame.new(pos) * CFrame.Angles(0, math.rad(angY), 0)
		w.Color = col
		w.Material = Enum.Material.Concrete
		w.Anchored = true
		w.Parent = root
		return w
	end

	makeWedge("StageRampL", Vector3.new(-52, floorY + 2, stageZ - 23), 0, Vector3.new(18, 4, 12), Color3.fromRGB(36, 40, 52))
	makeWedge("StageRampR", Vector3.new(52, floorY + 2, stageZ - 23), 0, Vector3.new(18, 4, 12), Color3.fromRGB(36, 40, 52))

	-- Giant Jumbotron Screen Behind the Stage
	local jumbotron = part(root, "JumbotronBack", Vector3.new(64, 20, 3), CFrame.new(0, floorY + 20, halfL - 6), Color3.fromRGB(20, 22, 28), Enum.Material.Metal)
	local screenFace = part(root, "JumbotronScreen", Vector3.new(60, 16, 0.5), CFrame.new(0, floorY + 20, halfL - 7.6), Color3.fromRGB(12, 14, 18), Enum.Material.SmoothPlastic)

	local sg = Instance.new("SurfaceGui")
	sg.Face = Enum.NormalId.Front
	sg.LightInfluence = 0
	sg.AlwaysOnTop = false
	sg.Parent = screenFace

	local jFrame = Instance.new("Frame")
	jFrame.Size = UDim2.fromScale(1, 1)
	jFrame.BackgroundColor3 = Color3.fromRGB(15, 18, 24)
	jFrame.BorderSizePixel = 0
	jFrame.Parent = sg

	local jTitle = Instance.new("TextLabel")
	jTitle.Size = UDim2.new(1, 0, 0, 40)
	jTitle.Position = UDim2.fromOffset(0, 10)
	jTitle.BackgroundTransparency = 1
	jTitle.FontFace = Font.new("rbxasset://fonts/families/Oswald.json", Enum.FontWeight.Bold)
	jTitle.Text = "★ SALA DE FIESTA: #" .. partyCode .. " ★"
	jTitle.TextSize = 34
	jTitle.TextColor3 = Color3.fromRGB(255, 204, 34)
	jTitle.Parent = jFrame

	local jSub = Instance.new("TextLabel")
	jSub.Size = UDim2.new(1, 0, 0, 28)
	jSub.Position = UDim2.fromOffset(0, 52)
	jSub.BackgroundTransparency = 1
	jSub.FontFace = Font.new("rbxasset://fonts/families/Oswald.json", Enum.FontWeight.Regular)
	jSub.Text = "PLAYGROUND ABIERTO · ¡MANEJA, SALTA Y CHOCA CON TUS AMIGOS!"
	jSub.TextSize = 20
	jSub.TextColor3 = Color3.fromRGB(0, 210, 255)
	jSub.Parent = jFrame

	-- 6. 4 Stunt & Launch Ramps in Playground Pit
	-- East / West Quarter-Pipes with Boost Pads
	makeWedge("QuarterPipeWest", Vector3.new(-halfW + 28, floorY + 6, -10), 90, Vector3.new(38, 12, 44), Color3.fromRGB(38, 42, 54))
	makeWedge("QuarterPipeEast", Vector3.new(halfW - 28, floorY + 6, -10), -90, Vector3.new(38, 12, 44), Color3.fromRGB(38, 42, 54))
	
	-- North Stunt Launcher pointing towards the Jumbotron
	makeWedge("NorthMegaRamp", Vector3.new(0, floorY + 6, -halfL + 34), 0, Vector3.new(34, 12, 40), Color3.fromRGB(38, 42, 54))

	-- 7. Center Trampoline Jump Pad (High-bouncing spring launch pad)
	local trampBase = cylinder(root, "TrampolineBase", Vector3.new(1.2, 22, 22), CFrame.new(0, floorY + 0.6, 0) * CFrame.Angles(0, 0, math.rad(90)), Color3.fromRGB(40, 44, 55), Enum.Material.Metal)
	local trampMat = cylinder(root, "TrampolineMat", Vector3.new(0.3, 19, 19), CFrame.new(0, floorY + 1.25, 0) * CFrame.Angles(0, 0, math.rad(90)), Color3.fromRGB(0, 230, 160), Enum.Material.Neon, false)

	-- Trampoline physics trigger
	trampBase.Touched:Connect(function(hit)
		local model = hit:FindFirstAncestorWhichIsA("Model")
		if model then
			local rootPart = model:FindFirstChildWhichIsA("BasePart")
			if rootPart and not rootPart.Anchored then
				rootPart.AssemblyLinearVelocity = Vector3.new(rootPart.AssemblyLinearVelocity.X, 95, rootPart.AssemblyLinearVelocity.Z)
			end
		end
	end)

	-- 8. Chrome Pinball Bumpers
	local bumperPositions = {
		Vector3.new(-42, floorY + 3.5, 30),
		Vector3.new(42, floorY + 3.5, 30),
		Vector3.new(-38, floorY + 3.5, -45),
		Vector3.new(38, floorY + 3.5, -45),
	}
	for i, bPos in ipairs(bumperPositions) do
		local post = cylinder(root, "PinballPost_" .. i, Vector3.new(5.0, 9, 9), CFrame.new(bPos) * CFrame.Angles(0, 0, math.rad(90)), Color3.fromRGB(50, 55, 70), Enum.Material.Metal)
		local bumperRing = cylinder(root, "PinballRing_" .. i, Vector3.new(1.2, 10.5, 10.5), CFrame.new(bPos + Vector3.new(0, 1.8, 0)) * CFrame.Angles(0, 0, math.rad(90)), Color3.fromRGB(255, 50, 100), Enum.Material.SmoothPlastic)
		
		bumperRing.Touched:Connect(function(hit)
			local model = hit:FindFirstAncestorWhichIsA("Model")
			if model then
				local bp = model:FindFirstChildWhichIsA("BasePart")
				if bp and not bp.Anchored then
					local dir = (bp.Position - bPos).Unit
					bp.AssemblyLinearVelocity = Vector3.new(dir.X * 80, 45, dir.Z * 80)
				end
			end
		end)
	end

	-- 9. Giant Bouncy Party Ball (11 studs, fun and interactive)
	local partyBall = Instance.new("Part")
	partyBall.Name = "GiantPartyBall"
	partyBall.Shape = Enum.PartType.Ball
	partyBall.Size = Vector3.new(11, 11, 11)
	partyBall.CFrame = CFrame.new(0, floorY + 6, -20)
	partyBall.Color = Color3.fromRGB(255, 210, 40)
	partyBall.Material = Enum.Material.SmoothPlastic
	partyBall.CanCollide = true
	partyBall.Anchored = false
	partyBall.CustomPhysicalProperties = PhysicalProperties.new(0.35, 0.3, 0.95, 1, 1)
	partyBall.Parent = root

	-- 10. 4 Parking Bays / Pedestals on the Showcase Stage
	local slotPedestals = {}
	local stageSlotPositions = {
		[1] = Vector3.new(0, stageY + 0.4, stageZ - 2),      -- Host Center
		[2] = Vector3.new(-32, stageY + 0.4, stageZ - 2),    -- Left
		[3] = Vector3.new(32, stageY + 0.4, stageZ - 2),     -- Right
		[4] = Vector3.new(0, stageY + 0.4, stageZ + 10),     -- Back center
	}

	for idx, sInfo in pairs(PartyConfig.SLOTS) do
		local pPos = stageSlotPositions[idx]
		local bay = part(root, "ParkingBay_" .. idx, Vector3.new(18, 0.2, 14), CFrame.new(pPos), Color3.fromRGB(26, 28, 36), Enum.Material.SmoothPlastic, false)
		
		-- Border strip
		local border = part(root, "BayBorder_" .. idx, Vector3.new(18.4, 0.25, 14.4), CFrame.new(pPos), sInfo.accentColor, Enum.Material.SmoothPlastic, false)

		-- Nameplate billboard anchor
		local bbPart = part(root, "SlotAnchor_" .. idx, Vector3.new(1, 1, 1), CFrame.new(pPos + Vector3.new(0, 6, 0)), Color3.new(0,0,0), nil, false)
		bbPart.Transparency = 1

		local bb = Instance.new("BillboardGui")
		bb.Name = "SlotTag"
		bb.Size = UDim2.fromOffset(240, 54)
		bb.AlwaysOnTop = true
		bb.MaxDistance = 180
		bb.Parent = bbPart

		local titleLbl = Instance.new("TextLabel")
		titleLbl.Size = UDim2.new(1, 0, 0, 28)
		titleLbl.BackgroundTransparency = 1
		titleLbl.FontFace = Font.new("rbxasset://fonts/families/Oswald.json", Enum.FontWeight.Bold)
		titleLbl.TextSize = 26
		titleLbl.TextColor3 = sInfo.nameColor
		titleLbl.TextStrokeColor3 = Color3.new(0, 0, 0)
		titleLbl.TextStrokeTransparency = 0.2
		titleLbl.Text = if sInfo.isHost then "★ HOST (SLOT 1)" else "SLOT " .. idx
		titleLbl.Parent = bb

		local subLbl = Instance.new("TextLabel")
		subLbl.Position = UDim2.fromOffset(0, 28)
		subLbl.Size = UDim2.new(1, 0, 0, 22)
		subLbl.BackgroundTransparency = 1
		subLbl.FontFace = Font.new("rbxasset://fonts/families/Oswald.json", Enum.FontWeight.Regular)
		subLbl.TextSize = 16
		subLbl.TextColor3 = Color3.fromRGB(180, 185, 195)
		subLbl.TextStrokeColor3 = Color3.new(0, 0, 0)
		subLbl.TextStrokeTransparency = 0.4
		subLbl.Text = "[+ DISPONIBLE]"
		subLbl.Parent = bb

		slotPedestals[idx] = {
			bay = bay,
			titleLabel = titleLbl,
			statusLabel = subLbl,
			color = sInfo.accentColor,
			position = pPos,
		}
	end

	return {
		root = root,
		pedestals = slotPedestals,
		ball = partyBall,
		jumbotronTitle = jTitle,
		stageSlotPositions = stageSlotPositions,
	}
end

return PartyLobbyArena
