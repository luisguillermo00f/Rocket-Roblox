--!strict
-- PartyManager.lua: Pure, breathtaking Night Stadium Aerial Lobby for Party Mode.
-- The camera overlooks the night arena while players soar, boost, flip, and perform
-- continuous aerodynamic freestyle acrobatics in the dark sky. No fake playground,
-- pure Rocket League aerial soul.
--
-- The party itself lives on the server (ServerScriptService.PartyMinigameService): this lobby shows its roster,
-- asks it to add bots / join by code / start a minigame, and steps aside while a round runs (MinigameClient),
-- coming back with the updated Party Points when it ends.

local RS = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UIS = game:GetService("UserInputService")
local Lighting = game:GetService("Lighting")

local PartyConfig = require(script.Parent.PartyConfig)
local PartyUI = require(script.Parent.PartyUI)
local MinigameRegistry = require(script.Parent.MinigameRegistry)
local Net = require(script.Parent.Net)
local MinigameClient = require(script.Parent.MinigameClient)
local Upper = require(script.Parent.MinigameHud).Upper -- string.upper is ASCII-only

local CarVisual = require(RS.Game.CarVisual)
local Phys = RS.Physics
local CarConfig = require(Phys.CarConfig)
local World = require(Phys.World)

local PartyManager = {}
PartyManager.__index = PartyManager

local activeSession: any = nil
local origLighting = {
	timeOfDay = "14:00",
	ambient = Color3.fromRGB(128, 128, 128),
	outdoorAmbient = Color3.fromRGB(128, 128, 128),
	brightness = 1.0,
	colorShiftTop = Color3.new(0, 0, 0),
	colorShiftBottom = Color3.new(0, 0, 0),
}

function PartyManager.GetActive()
	return activeSession
end

-- one signature colour per seat (the host's seat is gold)
local PLAYER_PALETTES = {
	[1] = { color = Color3.fromRGB(255, 200, 30) }, -- Electric Gold
	[2] = { color = Color3.fromRGB(0, 225, 255) }, -- Electric Cyan
	[3] = { color = Color3.fromRGB(255, 60, 140) }, -- Neon Coral
	[4] = { color = Color3.fromRGB(65, 255, 95) }, -- Acid Lime
}

-- 4 Synchronized Airshow Flight Paths across the Night Stadium
-- Kept in ideal spectator camera volume (X: -28..28, Y: 26..42, Z: -26..26)
local AERIAL_ROUTINES = {
	-- Seat 1 (Host - Gold): Sweeping infinity loop with continuous air rolls and climbing loops
	[1] = function(t: number)
		local u = t * 0.75
		local x = math.sin(u) * 25
		local z = math.sin(u * 2) * 18
		local y = 30 + math.sin(u * 1.5) * 8
		local dx = math.cos(u) * 25 * 0.75
		local dz = math.cos(u * 2) * 36 * 0.75
		local dy = math.cos(u * 1.5) * 12 * 0.75
		local fwd = Vector3.new(dx, dy, dz).Unit
		local roll = (t * 3.4) % (math.pi * 2)
		local pitch = math.sin(t * 1.6) * math.rad(18)
		return CFrame.lookAt(Vector3.new(x, y, z), Vector3.new(x, y, z) + fwd)
			* CFrame.Angles(pitch, 0, roll)
	end,

	-- Seat 2 (Cyan): Inverse orbital corkscrew weaving across the midfield
	[2] = function(t: number)
		local u = t * 0.8 + 1.8
		local x = math.cos(u) * 26
		local z = math.sin(u * 1.1) * 22
		local y = 34 + math.cos(u * 1.8) * 7
		local dx = -math.sin(u) * 26 * 0.8
		local dz = math.cos(u * 1.1) * 24 * 0.8
		local dy = -math.sin(u * 1.8) * 12 * 0.8
		local fwd = Vector3.new(dx, dy, dz).Unit
		local roll = (-t * 3.8) % (math.pi * 2)
		return CFrame.lookAt(Vector3.new(x, y, z), Vector3.new(x, y, z) + fwd)
			* CFrame.Angles(math.rad(-10), 0, roll)
	end,

	-- Seat 3 (Coral): Dynamic parabolic dive & climb with half-flip rotations
	[3] = function(t: number)
		local u = t * 0.7 + 3.5
		local x = math.sin(u * 1.2) * 22
		local z = math.cos(u * 1.2) * 20
		local y = 28 + math.sin(u * 2.2) * 8
		local fwd = Vector3.new(math.cos(u * 1.2), math.cos(u * 2.2) * 0.5, -math.sin(u * 1.2)).Unit
		local roll = (t * 4.2) % (math.pi * 2)
		return CFrame.lookAt(Vector3.new(x, y, z), Vector3.new(x, y, z) + fwd)
			* CFrame.Angles(math.rad(14), 0, roll)
	end,

	-- Seat 4 (Lime): Supersonic diagonal flyover cutting across formations
	[4] = function(t: number)
		local u = (t * 0.85 + 0.9) % (math.pi * 2)
		local x = -math.cos(u) * 28
		local z = -math.sin(u) * 24
		local y = 36 + math.sin(u * 2.0) * 8
		local fwd = Vector3.new(math.sin(u), math.cos(u * 2.0) * 0.4, -math.cos(u)).Unit
		local roll = (t * 3.2) % (math.pi * 2)
		return CFrame.lookAt(Vector3.new(x, y, z), Vector3.new(x, y, z) + fwd)
			* CFrame.Angles(0, 0, roll)
	end,
}

local function applyCarStyling(v: any, color: Color3)
	if not v or not v.model then return end

	-- 1. Body paint with vibrant signature color
	for _, p in ipairs(v.model:GetChildren()) do
		if p:IsA("BasePart") then
			if p.Name == "Part 1" or p.Name == "Part 2" or p.Name == "Part" or p.Name == "Part 4" then
				p.Color = color
				p.Material = Enum.Material.SmoothPlastic
			end
		end
	end

	-- 2. Vibrant colored boost trail
	if v.boostTrail then
		v.boostTrail.Color = ColorSequence.new(color)
		v.boostTrail.WidthScale = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1.4),
			NumberSequenceKeypoint.new(1, 0),
		})
		v.boostTrail.Lifetime = 0.9
		v.boostTrail.Enabled = true
	end

	-- 3. Supercharged boost flame
	if v.flame then
		v.flame.Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Color3.new(1, 1, 1)),
			ColorSequenceKeypoint.new(0.25, color),
			ColorSequenceKeypoint.new(1, color),
		})
		v.flame.Size = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1.6),
			NumberSequenceKeypoint.new(1, 0.4),
		})
		v.flame.Rate = 180
	end
end

local function applyNightLighting()
	Lighting.TimeOfDay = "21:30"
	Lighting.OutdoorAmbient = Color3.fromRGB(75, 88, 120)
	Lighting.Ambient = Color3.fromRGB(90, 105, 135)
	Lighting.Brightness = 2.0
	Lighting.ColorShift_Top = Color3.fromRGB(180, 210, 255)
	Lighting.ColorShift_Bottom = Color3.fromRGB(25, 32, 45)
end

local function restoreLighting()
	Lighting.TimeOfDay = origLighting.timeOfDay
	Lighting.Ambient = origLighting.ambient
	Lighting.OutdoorAmbient = origLighting.outdoorAmbient
	Lighting.Brightness = origLighting.brightness
	Lighting.ColorShift_Top = origLighting.colorShiftTop
	Lighting.ColorShift_Bottom = origLighting.colorShiftBottom
end

function PartyManager.Start(partyCode: string?, isHost: boolean?)
	if activeSession then
		activeSession:Destroy()
	end

	-- 0. Clean up any leftover MenuCinematic artifacts
	pcall(function()
		local MC = require(RS.Game.MenuCinematic)
		if MC and MC.IsRunning() then MC.Stop() end
	end)
	local oldMC = workspace:FindFirstChild("MenuCinematic")
	if oldMC then oldMC:Destroy() end

	pcall(function()
		local MainMenu = require(RS.Game.MainMenu)
		if MainMenu and MainMenu.Hide then MainMenu.Hide() end
		local lp = Players.LocalPlayer
		local pg = lp and lp:FindFirstChild("PlayerGui")
		if pg then
			local oldMM = pg:FindFirstChild("MainMenu")
			if oldMM then oldMM:Destroy() end
			local oldOverlay = pg:FindFirstChild("MainMenuOverlay")
			if oldOverlay then oldOverlay:Destroy() end
		end
	end)

	-- 1. Apply Authentic Night Stadium Lighting
	origLighting.timeOfDay = Lighting.TimeOfDay
	origLighting.ambient = Lighting.Ambient
	origLighting.outdoorAmbient = Lighting.OutdoorAmbient
	origLighting.brightness = Lighting.Brightness
	origLighting.colorShiftTop = Lighting.ColorShift_Top
	origLighting.colorShiftBottom = Lighting.ColorShift_Bottom
	applyNightLighting()

	-- 2. Add 4 Corner Stadium Floodlight Masts
	local fldr = workspace:FindFirstChild("PartyStadiumLights")
	if fldr then fldr:Destroy() end
	fldr = Instance.new("Folder")
	fldr.Name = "PartyStadiumLights"
	fldr.Parent = workspace

	local corners = {
		Vector3.new(150, 58, 190),
		Vector3.new(-150, 58, 190),
		Vector3.new(150, 58, -190),
		Vector3.new(-150, 58, -190),
	}
	for i, pos in ipairs(corners) do
		local p = Instance.new("Part")
		p.Name = "FloodlightMast_" .. i
		p.Size = Vector3.new(4, 4, 4)
		p.CFrame = CFrame.new(pos)
		p.Anchored = true
		p.CanCollide = false
		p.Transparency = 1
		p.Parent = fldr

		local sl = Instance.new("SpotLight")
		sl.Brightness = 4.5
		sl.Range = 260
		sl.Angle = 110
		sl.Color = Color3.fromRGB(220, 235, 255)
		sl.Face = Enum.NormalId.Bottom
		sl.Shadows = false
		sl.Parent = p

		local pl = Instance.new("PointLight")
		pl.Brightness = 2.5
		pl.Range = 180
		pl.Color = Color3.fromRGB(200, 225, 255)
		pl.Shadows = false
		pl.Parent = p
	end

	local session = setmetatable({}, PartyManager)
	session.partyCode = partyCode or "RR-····"
	session.isHost = if isHost ~= nil then isHost else true
	session.active = true
	session.suspended = false
	session.conns = {}
	session.cars = {} -- member id -> { visual, color, routine, tOffset }
	session.members = {}
	session.catalogue = {}
	session.lightsFolder = fldr

	activeSession = session

	-- 3. Create Aerial Cars Container in Workspace
	local container = Instance.new("Folder")
	container.Name = "PartyAerialCars"
	container.Parent = workspace
	session.container = container

	-- 4. World for car physics data structures (visual only: the aerial show is scripted)
	session.world = World.new({ seed = 1, boostPads = false })

	-- 6. Camera Setup: Hero Aerial Spectator Camera
	local camera = workspace.CurrentCamera
	camera.CameraType = Enum.CameraType.Scriptable
	camera.FieldOfView = 65

	-- 7. Initialize Clean, Unobtrusive Party UI
	session.ui = PartyUI.new(session.partyCode, session.isHost)
	session.ui:Notify("CREANDO GRUPO...", PLAYER_PALETTES[1].color)

	-- 8. Hook Up UI Buttons (they ask the server; the party state that comes back updates everything)
	session.ui.simButton.MouseButton1Click:Connect(function()
		session:SimulateFriendJoin()
	end)
	session.ui.removeBotButton.MouseButton1Click:Connect(function()
		session:Request("removeBot")
	end)
	session.ui.joinButton.MouseButton1Click:Connect(function()
		session:JoinByCode(session.ui.codeInput.Text)
	end)
	session.ui.codeInput.FocusLost:Connect(function(enter)
		if enter then session:JoinByCode(session.ui.codeInput.Text) end
	end)

	session.ui.startButton.MouseButton1Click:Connect(function()
		session:StartPartyMatch()
	end)

	if session.ui.exitButton then
		session.ui.exitButton.MouseButton1Click:Connect(function()
			session:Exit()
		end)
	end

	-- Keyboard shortcuts (ESC removed, only clickable button returns to main menu)
	local keyConn = UIS.InputBegan:Connect(function(inp, processed)
		if processed or session.suspended then return end
		if inp.KeyCode == Enum.KeyCode.M or inp.KeyCode == Enum.KeyCode.ButtonY then
			session.ui:ToggleMinigameModal(not session.ui.minigameModal.Visible)
		end
	end)
	table.insert(session.conns, keyConn)

	-- 9. Server party: state pushes, and rounds taking over the screen
	MinigameClient.Init()
	local stateRemote = Net.Remote("PartyState")
	table.insert(session.conns, stateRemote.OnClientEvent:Connect(function(st)
		if session.active then session:ApplyState(st) end
	end))
	session.offStart = MinigameClient.OnRoundStart(function()
		if session.active then session:Suspend() end
	end)
	session.offEnd = MinigameClient.OnRoundEnd(function()
		if session.active then session:Resume() end
	end)
	task.spawn(function()
		local res = session:Request("create")
		if res and res.ok and session.active then
			session.ui:Notify("¡MODO GRUPO! COMPARTE EL CÓDIGO " .. tostring(res.state and res.state.code or ""), PLAYER_PALETTES[1].color)
		end
	end)

	-- 10. Main Render Loop: Aerial Acrobatics & Dynamic Hero Camera
	local startTime = os.clock()
	local stepConn = RunService.RenderStepped:Connect(function(dt)
		if not session.active or session.suspended then return end
		local now = os.clock() - startTime

		local focusPos = Vector3.zero
		local count = 0

		for _, pData in pairs(session.cars) do
			if pData.visual and pData.routine then
				local cf = pData.routine(now + pData.tOffset)
				pData.visual:Update(cf, true)

				-- Maintain boost flames and trails
				if pData.visual.flame then pData.visual.flame.Rate = 180 end
				if pData.visual.boostTrail then pData.visual.boostTrail.Enabled = true end

				focusPos += cf.Position
				count += 1
			end
		end

		if count > 0 then
			focusPos /= count
		else
			focusPos = Vector3.new(0, 32, 0)
		end

		-- Hero Aerial Camera: low angle looking UP into the acrobatic airshow
		local camAngle = math.rad(-90) + math.sin(now * 0.15) * math.rad(22)
		local camDist = 58 + math.cos(now * 0.12) * 5
		local camH = 12 + math.sin(now * 0.18) * 3
		local camPos = Vector3.new(
			math.sin(camAngle) * camDist,
			camH,
			math.cos(camAngle) * camDist
		)

		local lookTarget = focusPos:Lerp(Vector3.new(0, 31, 0), 0.5)
		camera.CameraType = Enum.CameraType.Scriptable
		camera.CFrame = CFrame.lookAt(camPos, lookTarget)
	end)
	table.insert(session.conns, stepConn)

	return session
end

-- ---------------------------------------------------------------- server requests
local requestRemote: any = nil
function PartyManager:Request(action: string, arg: any?): any
	requestRemote = requestRemote or Net.Remote("PartyRequest")
	if not requestRemote then
		self.ui:Notify("SIN CONEXIÓN CON EL SERVIDOR DE GRUPOS", Color3.fromRGB(255, 80, 80))
		return nil
	end
	local ok, res = pcall(function()
		return requestRemote:InvokeServer(action, arg)
	end)
	if not ok or type(res) ~= "table" then
		self.ui:Notify("EL SERVIDOR NO RESPONDIÓ", Color3.fromRGB(255, 80, 80))
		return nil
	end
	if res.state and self.active then
		self:ApplyState(res.state)
	end
	if not res.ok and res.error then
		self.ui:Notify(Upper(tostring(res.error)), Color3.fromRGB(255, 80, 80))
	end
	return res
end

-- the server's party -> roster, aerial cars, host controls, available minigames
function PartyManager:ApplyState(st: any)
	if type(st) ~= "table" or type(st.members) ~= "table" then return end
	local lp = Players.LocalPlayer
	self.partyCode = st.code
	self.isHost = st.hostUserId == lp.UserId
	self.members = st.members
	self.inSession = st.inSession == true
	self.ui:SetCode(st.code or "")

	-- aerial cars: one per member, seat colours in party order
	local seen = {}
	local rosterRows = {}
	for i, m in st.members do
		seen[m.id] = true
		local pal = PLAYER_PALETTES[i] or { color = Color3.new(1, 1, 1) }
		local e = self.cars[m.id]
		if not e then
			local phys = self.world:AddCar(0, CarConfig.Octane)
			phys.isBoosting = true
			local v = CarVisual.new(phys, self.container, m.cosmetics or "Octane") -- seat colour still paints it below
			e = { visual = v }
			self.cars[m.id] = e
			if #st.members > 1 then
				self.ui:Notify(string.format("¡%s SE UNIÓ Y DESPEGÓ!", Upper(m.name or "?")), pal.color)
			end
		end
		if e.seat ~= i then
			e.seat = i
			e.color = pal.color
			e.routine = AERIAL_ROUTINES[i] or AERIAL_ROUTINES[1]
			e.tOffset = if i == 1 then 0 else i * 1.5
			applyCarStyling(e.visual, pal.color)
		end
		table.insert(rosterRows, { id = m.id, name = m.name, isBot = m.isBot, isHost = m.isHost, userId = m.userId, points = m.points, color = pal.color })
	end
	for id, e in self.cars do
		if not seen[id] then
			e.visual:Destroy()
			self.cars[id] = nil
		end
	end
	self.ui:SetHost(self.isHost)
	self.ui:UpdatePlayerCount(#st.members)
	self.ui:SetRoster(rosterRows)

	-- what the server can run
	local available = {}
	for _, c in st.catalogue or {} do
		available[c.id] = true
	end
	self.catalogue = st.catalogue or {}
	self.ui:SetAvailable(available)
end

function PartyManager:SimulateFriendJoin()
	if #self.members >= PartyConfig.MAX_PLAYERS then
		self.ui:Notify("¡EL LOBBY YA TIENE 4 JUGADORES (MÁXIMO)!", Color3.fromRGB(255, 180, 50))
		return
	end
	self:Request("addBot")
end

function PartyManager:JoinByCode(code: string)
	local c = string.upper(string.gsub(code or "", "%s", ""))
	if c == "" then return end
	if not string.find(c, "^RR%-") then c = "RR-" .. c end
	local res = self:Request("join", c)
	if res and res.ok then
		self.ui.codeInput.Text = ""
		self.ui:Notify("¡TE UNISTE AL GRUPO " .. c .. "!", Color3.fromRGB(0, 225, 255))
	end
end

function PartyManager:StartPartyMatch()
	if not self.isHost then
		self.ui:Notify("SOLO EL ANFITRIÓN PUEDE INICIAR", Color3.fromRGB(255, 180, 50))
		return
	end
	local n = #self.members
	if n < PartyConfig.MIN_PLAYERS_TO_START then
		self.ui:Notify("SE NECESITAN AL MENOS 2 JUGADORES", Color3.fromRGB(255, 80, 80))
		return
	end
	-- selected in the modal AND runnable by the server for this many players
	local pool = {}
	for _, c in self.catalogue do
		if self.ui.selectedMinigames[c.id] ~= false and n >= c.minPlayers and n <= c.maxPlayers then
			table.insert(pool, c.id)
		end
	end
	if #pool == 0 then
		self.ui:Notify("NO HAY MINIJUEGOS ACTIVOS PARA " .. n .. " JUGADORES", Color3.fromRGB(255, 80, 80))
		return
	end
	local id = pool[Random.new():NextInteger(1, #pool)]
	local def = MinigameRegistry.Get(id)
	self.ui:Notify("MINIJUEGO: " .. (if def then def.name else string.upper(id)) .. " · ¡A JUGAR!", Color3.fromRGB(255, 215, 0))
	self:Request("start", id)
end

-- a round takes the screen: hide the lobby, give the round normal daylight to set its own mood
function PartyManager:Suspend()
	if self.suspended then return end
	self.suspended = true
	self.ui:ToggleMinigameModal(false)
	if self.ui.screenGui then self.ui.screenGui.Enabled = false end
	pcall(function() require(RS.Game.InputGlyphs).RefreshFocus() end) -- release the selection for the round
	self.container.Parent = nil
	self.lightsFolder.Parent = nil
	restoreLighting()
end

function PartyManager:Resume()
	if not self.suspended then return end
	self.suspended = false
	if self.ui.screenGui then self.ui.screenGui.Enabled = true end
	pcall(function() require(RS.Game.InputGlyphs).RefreshFocus() end) -- the lobby takes the controller again
	self.container.Parent = workspace
	self.lightsFolder.Parent = workspace
	applyNightLighting()
	local camera = workspace.CurrentCamera
	camera.CameraType = Enum.CameraType.Scriptable
	camera.FieldOfView = 65
	self.ui:Notify("¡RONDA TERMINADA! PUNTOS FIESTA ACTUALIZADOS", Color3.fromRGB(255, 215, 0))
	task.spawn(function() self:Request("state") end)
end

function PartyManager:Exit()
	task.spawn(function() self:Request("leave") end)
	self:Destroy()
	local returnEvent = RS.Game:FindFirstChild("ReturnToMenuEvent") :: BindableEvent?
	if returnEvent then
		returnEvent:Fire()
	else
		local MainMenu = require(RS.Game.MainMenu)
		if MainMenu and (MainMenu :: any).ReturnToMenu then
			(MainMenu :: any).ReturnToMenu()
		end
	end
end

function PartyManager:Destroy()
	self.active = false
	activeSession = nil

	for _, c in ipairs(self.conns) do c:Disconnect() end
	table.clear(self.conns)
	if self.offStart then self.offStart() end
	if self.offEnd then self.offEnd() end
	for _, e in self.cars do e.visual:Destroy() end
	table.clear(self.cars)

	if self.ui then self.ui:Destroy() end
	if self.container then self.container:Destroy() end
	if self.lightsFolder then self.lightsFolder:Destroy() end

	restoreLighting()
end

return PartyManager
