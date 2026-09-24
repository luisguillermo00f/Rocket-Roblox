--!strict
-- GarageScreen.lua: GARAJE (docs/cosmetics.md §9). Slots on the left, the slot's items on the right, the menu car
-- (MenuCinematic) wears what is selected. Owned items are equipped through the server (CosmeticsRequest "equip");
-- items you don't own can be tried on (preview only) and say how to get them. Leaving restores the saved loadout.
-- Controller: engine selection over the slot list and the item grid (gold frame), LB / RB change slot, B closes.
-- Structure and logic only; the look is polished in Studio.
local UIS = game:GetService("UserInputService")

local InputGlyphs = require(script.Parent.InputGlyphs)
local EconomyClient = require(script.Parent.EconomyClient)
local Effects = require(script.Parent.Effects)
local Economy = script.Parent.Parent:WaitForChild("Economy")
local Catalog = require(Economy:WaitForChild("CosmeticCatalog"))

local GarageScreen = {}

local gui: ScreenGui? = nil

export type Ctx = {
	preview: (loadout: { [string]: string }) -> (), -- dress the menu car
}

function GarageScreen.Close()
	if gui then
		gui:Destroy()
		gui = nil
	end
end

-- UI: MainMenu.UI helpers ; ctx: see Ctx
function GarageScreen.Open(UI: any, ctx: Ctx)
	local frame, text, button = UI.frame, UI.text, UI.button
	GarageScreen.Close()
	local g = UI.newGui("GarageMenu", 25)
	gui = g

	local prof: { [string]: any } = EconomyClient.Get() or {}
	local owned: { [string]: boolean } = {}
	local equipped: { [string]: string } = Catalog.Defaults()
	local trying: { [string]: string } = {}
	local function setState(ownedList: any, eq: any)
		if type(ownedList) == "table" then
			owned = {}
			for _, id in ownedList do owned[id] = true end
		end
		if type(eq) == "table" then
			for slot, id in eq do equipped[slot] = id end
		end
	end
	setState(prof.owned, prof.equipped)
	local function isOwned(id: string): boolean
		local it = Catalog.Get(id)
		return it ~= nil and (it.default == true or owned[id] == true)
	end
	local function currentLook(): { [string]: string }
		local out = table.clone(equipped)
		for slot, id in trying do out[slot] = id end
		return out
	end

	local conns: { any } = {}
	g.Destroying:Connect(function()
		for _, c in conns do
			if typeof(c) == "RBXScriptConnection" then c:Disconnect() else c() end
		end
		ctx.preview(equipped) -- try-ons end with the screen
	end)

	-- left panel (the car stays visible on the right)
	local shade = frame(g, { Size = UDim2.new(0, 1180, 1, 0), BackgroundColor3 = Color3.new(0, 0, 0), BackgroundTransparency = 0.35 })
	local sg = Instance.new("UIGradient")
	sg.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0), NumberSequenceKeypoint.new(0.8, 0.2), NumberSequenceKeypoint.new(1, 1) })
	sg.Parent = shade
	local root = frame(g, { Position = UDim2.fromOffset(110, 120), Size = UDim2.fromOffset(1060, 860), BackgroundTransparency = 1 })
	text(root, { Size = UDim2.fromOffset(700, 90), Text = "GARAJE", TextSize = 88, TextColor3 = UI.WHITE, TextXAlignment = Enum.TextXAlignment.Left })
	frame(root, { Position = UDim2.fromOffset(4, 92), Size = UDim2.fromOffset(90, 6), BackgroundColor3 = UI.BLUE })
	local status = text(root, { Position = UDim2.fromOffset(4, 104), Size = UDim2.fromOffset(1000, 26), Text = "", TextSize = 20, TextColor3 = UI.GOLD, TextXAlignment = Enum.TextXAlignment.Left, FontFace = UI.OSWALD_REG })

	-- slot list
	local slotCol = frame(root, { Position = UDim2.fromOffset(0, 150), Size = UDim2.fromOffset(330, 700), BackgroundTransparency = 1 })
	local slotRows: { [string]: any } = {}
	local current = Catalog.SLOTS[1]
	local grid = Instance.new("ScrollingFrame")
	grid.Position = UDim2.fromOffset(360, 150)
	grid.Size = UDim2.fromOffset(700, 640)
	grid.BackgroundTransparency = 1
	grid.BorderSizePixel = 0
	grid.ScrollBarThickness = 6
	grid.CanvasSize = UDim2.new()
	grid.AutomaticCanvasSize = Enum.AutomaticSize.Y
	grid.Selectable = false
	grid.Parent = root
	local layout = Instance.new("UIGridLayout")
	layout.CellSize = UDim2.fromOffset(222, 150)
	layout.CellPadding = UDim2.fromOffset(12, 12)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = grid
	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(0, 6)
	pad.PaddingLeft = UDim.new(0, 6)
	pad.Parent = grid

	local firstItem: GuiObject? = nil
	local renderGrid: () -> () = function() end

	local function paintSlots()
		for slot, r in slotRows do
			local on = slot == current
			r.b.BackgroundTransparency = if on then 0 else 1
			r.name.TextColor3 = if on then UI.INK else UI.WHITE
			r.item.TextColor3 = if on then UI.MUTED else Color3.fromRGB(190, 194, 206)
			local it = Catalog.Get(trying[slot] or equipped[slot])
			r.item.Text = if it then it.name else ""
		end
	end

	local function selectSlot(slot: string)
		current = slot
		paintSlots()
		renderGrid()
	end

	for i, slot in Catalog.SLOTS do
		local b = button(slotCol, { Position = UDim2.fromOffset(0, (i - 1) * 78), Size = UDim2.fromOffset(330, 70), BackgroundColor3 = UI.CREAM, BackgroundTransparency = 1 })
		local name = text(b, { Position = UDim2.fromOffset(18, 6), Size = UDim2.new(1, -30, 0, 34), Text = Catalog.SLOT_NAMES[slot], TextSize = 32, TextColor3 = UI.WHITE, TextXAlignment = Enum.TextXAlignment.Left })
		local item = text(b, { Position = UDim2.fromOffset(18, 40), Size = UDim2.new(1, -30, 0, 22), Text = "", TextSize = 17, TextXAlignment = Enum.TextXAlignment.Left, FontFace = UI.OSWALD_REG, TextTruncate = Enum.TextTruncate.AtEnd })
		b.MouseButton1Click:Connect(function() selectSlot(slot) end)
		b.SelectionGained:Connect(function() if current ~= slot then selectSlot(slot) end end)
		slotRows[slot] = { b = b, name = name, item = item }
	end

	local busy = false
	local function equip(it: Catalog.Item)
		if busy then return end
		busy = true
		status.Text = "EQUIPANDO…"
		local res = EconomyClient.Request("CosmeticsRequest", "equip", { slot = it.slot, id = it.id })
		busy = false
		if gui ~= g then return end
		if res.ok then
			setState(nil, res.equipped)
			trying[it.slot] = nil
			status.Text = "EQUIPADO: " .. it.name
		else
			status.Text = tostring(res.error or "NO SE PUDO EQUIPAR")
		end
		ctx.preview(currentLook())
		paintSlots()
		renderGrid()
	end

	local function pick(it: Catalog.Item)
		if isOwned(it.id) then
			if equipped[it.slot] ~= it.id or trying[it.slot] then equip(it) end
		else
			-- try it on: the menu car wears it until you leave or pick another one
			trying[it.slot] = it.id
			status.Text = "PROBANDO " .. it.name .. "  ·  SE CONSIGUE EN: " .. Catalog.SourceText(it)
			ctx.preview(currentLook())
			paintSlots()
			renderGrid()
		end
		if it.slot == "goal" then
			-- show the explosion in front of the camera
			local cam = workspace.CurrentCamera
			Effects.Goal((cam.CFrame * CFrame.new(0, -4, -45)).Position, UI.BLUE, false, it.id)
		end
	end

	renderGrid = function()
		for _, c in grid:GetChildren() do
			if c:IsA("GuiObject") then c:Destroy() end
		end
		firstItem = nil
		for i, it in Catalog.OfSlot(current) do
			local rar = Catalog.RARITIES[it.rarity]
			local isEq = equipped[it.slot] == it.id and trying[it.slot] == nil
			local isTry = trying[it.slot] == it.id
			local mine = isOwned(it.id)
			local b = button(grid, { LayoutOrder = i, BackgroundColor3 = if isEq then UI.CREAM else UI.PANEL, BackgroundTransparency = if mine then 0 else 0.25 })
			frame(b, { Size = UDim2.new(1, 0, 0, 6), BackgroundColor3 = rar and rar.color or UI.MUTED })
			text(b, { Position = UDim2.fromOffset(14, 14), Size = UDim2.new(1, -28, 0, 18), Text = rar and rar.name or "", TextSize = 14, TextColor3 = UI.MUTED, TextXAlignment = Enum.TextXAlignment.Left, FontFace = UI.OSWALD_REG })
			text(b, { Position = UDim2.fromOffset(14, 34), Size = UDim2.new(1, -28, 0, 56), Text = it.name, TextSize = 26, TextWrapped = true, TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Top })
			local foot = if isEq then "EQUIPADO" elseif isTry then "PROBANDO" elseif mine then "EQUIPAR" else "BLOQUEADO · " .. Catalog.SourceText(it)
			text(b, { Position = UDim2.fromOffset(14, 112), Size = UDim2.new(1, -28, 0, 24), Text = foot, TextSize = if mine then 20 else 15,
				TextColor3 = if isEq then UI.BLUE else UI.INK, TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd })
			b.MouseButton1Click:Connect(function() pick(it) end)
			if not firstItem then firstItem = b end
		end
		InputGlyphs.RefreshFocus()
	end

	-- bottom: back + hints
	local back = button(root, { Position = UDim2.fromOffset(0, 800), Size = UDim2.fromOffset(330, 56), BackgroundTransparency = 1 })
	local bl = text(back, { Size = UDim2.fromScale(1, 1), Text = "‹  VOLVER", TextSize = 40, TextColor3 = UI.WHITE, TextXAlignment = Enum.TextXAlignment.Left })
	back.MouseEnter:Connect(function() bl.TextColor3 = UI.GOLD end)
	back.MouseLeave:Connect(function() bl.TextColor3 = UI.WHITE end)
	back.MouseButton1Click:Connect(GarageScreen.Close)
	InputGlyphs.HintBar(g, { { "tabs", "RANURA" }, { "confirm", "EQUIPAR / PROBAR" }, { "back", "VOLVER" } }, { position = UDim2.new(1, -56, 1, -30), height = 34, textSize = 18 })

	table.insert(conns, UIS.InputBegan:Connect(function(input)
		local k = input.KeyCode
		local idx = table.find(Catalog.SLOTS, current) or 1
		if k == Enum.KeyCode.Escape or k == Enum.KeyCode.Backspace then
			GarageScreen.Close()
		elseif k == Enum.KeyCode.ButtonL1 or k == Enum.KeyCode.Q then
			selectSlot(Catalog.SLOTS[(idx - 2) % #Catalog.SLOTS + 1])
			InputGlyphs.Focus(firstItem)
		elseif k == Enum.KeyCode.ButtonR1 or k == Enum.KeyCode.E then
			selectSlot(Catalog.SLOTS[idx % #Catalog.SLOTS + 1])
			InputGlyphs.Focus(firstItem)
		end
	end))
	table.insert(conns, EconomyClient.OnUpdate(function(p)
		if type(p) == "table" then
			setState(p.owned, p.equipped)
			paintSlots()
			renderGrid()
		end
	end))

	selectSlot(current)
	InputGlyphs.PushPanel(g, function() return firstItem or slotRows[current].b end, GarageScreen.Close)
	-- fresh inventory from the server
	task.spawn(function()
		local res = EconomyClient.Request("CosmeticsRequest", "state")
		if gui == g and res.ok then
			setState(res.owned, res.equipped)
			paintSlots()
			renderGrid()
		end
	end)
end

return GarageScreen
