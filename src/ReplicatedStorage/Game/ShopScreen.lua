--!strict
-- ShopScreen.lua: TIENDA (docs/cosmetics.md §5, §9). The week's featured item and the 6 daily items, exactly as the
-- server's CosmeticsRequest "state" returns them (the rotation is re-checked by the server on every purchase), with
-- price or COMPRADO / EQUIPADO. Buying asks for confirmation (MainMenu.Modal) and then the server decides.
-- Controller: engine selection over the cards (gold frame), A buys / equips, B closes. Structure and logic only.
local UIS = game:GetService("UserInputService")

local InputGlyphs = require(script.Parent.InputGlyphs)
local EconomyClient = require(script.Parent.EconomyClient)
local Economy = script.Parent.Parent:WaitForChild("Economy")
local Catalog = require(Economy:WaitForChild("CosmeticCatalog"))
local DateUtil = require(Economy:WaitForChild("DateUtil"))

local ShopScreen = {}

local gui: ScreenGui? = nil

export type Ctx = {
	modal: (title: string, subtitle: string?, color: Color3?, items: { { any } }, opts: { [string]: any }?) -> (),
	closeModal: () -> (),
	modalOpen: () -> boolean,
	-- extra tabs next to OBJETOS (the lootbox screen plugs in here): { { label, open(UI, ctx) } }
	tabs: { { any } }?,
}

function ShopScreen.Close()
	if gui then
		gui:Destroy()
		gui = nil
	end
end

function ShopScreen.Open(UI: any, ctx: Ctx)
	local frame, text, button = UI.frame, UI.text, UI.button
	ShopScreen.Close()
	local g = UI.newGui("ShopMenu", 25) -- under MainMenu.Modal (30): the purchase confirmation shows on top
	gui = g
	local conns: { any } = {}
	g.Destroying:Connect(function()
		for _, c in conns do
			if typeof(c) == "RBXScriptConnection" then c:Disconnect() else c() end
		end
	end)

	local back = button(g, { Size = UDim2.fromScale(1, 1), BackgroundColor3 = Color3.new(0, 0, 0), BackgroundTransparency = 0.4, Selectable = false })
	back.MouseButton1Click:Connect(ShopScreen.Close)
	local p = frame(g, { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(1500, 840), BackgroundColor3 = UI.CREAM })
	UI.brackets(p, UI.EDGE, 10, 18, 3)
	text(p, { Position = UDim2.fromOffset(40, 24), Size = UDim2.fromOffset(400, 50), Text = "TIENDA", TextSize = 46, TextXAlignment = Enum.TextXAlignment.Left })
	-- tabs (OBJETOS + whatever ctx.tabs adds)
	local tabRow = frame(p, { Position = UDim2.fromOffset(260, 34), Size = UDim2.fromOffset(600, 40), BackgroundTransparency = 1 })
	local tabList = Instance.new("UIListLayout")
	tabList.FillDirection = Enum.FillDirection.Horizontal
	tabList.Padding = UDim.new(0, 8)
	tabList.Parent = tabRow
	local function tab(label: string, on: boolean, fn: (() -> ())?)
		local b = button(tabRow, { Size = UDim2.fromOffset(150, 40), BackgroundColor3 = if on then UI.CHIP else UI.BAR, Selectable = false })
		text(b, { Size = UDim2.fromScale(1, 1), Text = label, TextSize = 22, TextColor3 = if on then UI.WHITE else UI.INK })
		if fn then b.MouseButton1Click:Connect(fn) end
	end
	tab("OBJETOS", true, nil)
	local extraTabs: { { any } } = ctx.tabs or {}
	for _, t in extraTabs do
		tab(t[1], false, function()
			ShopScreen.Close()
			t[2](UI, ctx)
		end)
	end
	if #extraTabs > 0 then
		InputGlyphs.Chip(p, "tabs", { dark = true, height = 30, position = UDim2.fromOffset(260 + (#extraTabs + 1) * 158 + 8, 54), anchor = Vector2.new(0, 0.5) })
	end

	-- credits
	local credits = text(p, { AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -70, 0, 30), Size = UDim2.fromOffset(300, 44), Text = "", TextSize = 40, TextXAlignment = Enum.TextXAlignment.Right })
	UI.gem(p, { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(1, -50, 0, 54), Size = UDim2.fromOffset(16, 16) })
	local status = text(p, { Position = UDim2.fromOffset(42, 76), Size = UDim2.fromOffset(1100, 24), Text = "", TextSize = 18, TextColor3 = UI.MUTED, TextXAlignment = Enum.TextXAlignment.Left, FontFace = UI.OSWALD_REG })

	local featuredHolder = frame(p, { Position = UDim2.fromOffset(40, 116), Size = UDim2.fromOffset(440, 610), BackgroundTransparency = 1 })
	local dailyHolder = frame(p, { Position = UDim2.fromOffset(510, 116), Size = UDim2.fromOffset(950, 610), BackgroundTransparency = 1 })
	local resetLabel = text(p, { Position = UDim2.fromOffset(510, 740), Size = UDim2.fromOffset(600, 26), Text = "", TextSize = 18, TextColor3 = UI.MUTED, TextXAlignment = Enum.TextXAlignment.Left, FontFace = UI.OSWALD_REG })
	local close = button(p, { AnchorPoint = Vector2.new(1, 1), Position = UDim2.new(1, -28, 1, -28), Size = UDim2.fromOffset(250, 64), BackgroundColor3 = UI.CHIP })
	text(close, { Position = UDim2.fromOffset(22, 0), Size = UDim2.new(1, -100, 1, 0), Text = "CERRAR", TextSize = 28, TextColor3 = UI.WHITE, TextXAlignment = Enum.TextXAlignment.Left })
	UI.chip(close, "ESC", false)
	close.MouseButton1Click:Connect(ShopScreen.Close)

	local state: { [string]: any } = {}
	local fetchedAt = EconomyClient.Now()
	local firstCard: GuiObject? = nil
	local busy = false
	local render: () -> () = function() end

	local function refresh()
		local res = EconomyClient.Request("CosmeticsRequest", "state")
		if gui ~= g then return end
		if res.ok then
			state = res
			fetchedAt = EconomyClient.Now()
			status.Text = if res.canSpend == false then "TU PERFIL NO SE ESTÁ GUARDANDO: NO SE PUEDE COMPRAR AHORA" else ""
		else
			status.Text = tostring(res.error)
		end
		render()
	end

	local function owns(id: string): boolean
		return table.find(state.owned or {}, id) ~= nil
	end

	local function equip(it: Catalog.Item)
		local res = EconomyClient.Request("CosmeticsRequest", "equip", { slot = it.slot, id = it.id })
		if gui ~= g then return end
		status.Text = if res.ok then "EQUIPADO: " .. it.name else tostring(res.error)
		task.spawn(refresh)
	end

	local function buy(it: Catalog.Item)
		if busy then return end
		busy = true
		status.Text = "COMPRANDO…"
		local res = EconomyClient.Request("CosmeticsRequest", "buy", it.id)
		busy = false
		if gui ~= g then return end
		if res.ok then
			state = res
			render()
			ctx.modal("¡COMPRADO!", it.name .. "  ·  " .. (Catalog.SLOT_NAMES[it.slot] or ""), Catalog.RARITIES[it.rarity].color, {
				{ "EQUIPAR", "ENTER", function() ctx.closeModal(); equip(it) end },
				{ "CERRAR", "ESC", function() ctx.closeModal() end },
			})
			status.Text = ""
		else
			status.Text = tostring(res.error)
		end
	end

	local function clicked(it: Catalog.Item)
		if busy then return end
		if owns(it.id) then
			if (state.equipped or {})[it.slot] ~= it.id then equip(it) end
			return
		end
		local price = it.price or 0
		local have = state.credits or 0
		ctx.modal("¿COMPRAR?", string.format("%s  ·  %s CRÉDITOS  (TIENES %s)", it.name, UI.fmtInt(price), UI.fmtInt(have)), Catalog.RARITIES[it.rarity].color, {
			{ "COMPRAR", "ENTER", function() ctx.closeModal(); task.spawn(buy, it) end },
			{ "CANCELAR", "ESC", function() ctx.closeModal() end },
		})
	end

	local function card(parent: Instance, pos: UDim2, size: UDim2, it: Catalog.Item, big: boolean): TextButton
		local rar = Catalog.RARITIES[it.rarity]
		local mine = owns(it.id)
		local isEq = (state.equipped or {})[it.slot] == it.id
		local b = button(parent, { Position = pos, Size = size, BackgroundColor3 = UI.PANEL })
		frame(b, { Size = UDim2.new(1, 0, 0, if big then 10 else 6), BackgroundColor3 = rar.color })
		text(b, { Position = UDim2.fromOffset(20, 22), Size = UDim2.new(1, -40, 0, 20), Text = rar.name .. "  ·  " .. (Catalog.SLOT_NAMES[it.slot] or ""), TextSize = 16, TextColor3 = UI.MUTED, TextXAlignment = Enum.TextXAlignment.Left, FontFace = UI.OSWALD_REG })
		text(b, { Position = UDim2.fromOffset(20, 46), Size = UDim2.new(1, -40, 0, if big then 120 else 80), Text = it.name, TextSize = if big then 54 else 34, TextWrapped = true,
			TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Top })
		-- a colour swatch for paint-like items
		local sw = it.params.color or (it.params.gradient and it.params.gradient[1]) or (it.params.flame and it.params.flame[2])
		if typeof(sw) == "Color3" then
			local s = frame(b, { AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -20, 0, 22), Size = UDim2.fromOffset(28, 28), BackgroundColor3 = sw })
			UI.corner(s, UDim.new(0.5, 0))
		end
		local foot = frame(b, { AnchorPoint = Vector2.new(0, 1), Position = UDim2.new(0, 20, 1, -18), Size = UDim2.new(1, -40, 0, 40), BackgroundTransparency = 1 })
		if mine then
			text(foot, { Size = UDim2.fromScale(1, 1), Text = if isEq then "EQUIPADO" else "COMPRADO · EQUIPAR", TextSize = 24, TextColor3 = if isEq then UI.BLUE else UI.MUTED, TextXAlignment = Enum.TextXAlignment.Left })
		else
			text(foot, { Position = UDim2.fromOffset(24, 0), Size = UDim2.new(1, -24, 1, 0), Text = UI.fmtInt(it.price or 0), TextSize = 32, TextXAlignment = Enum.TextXAlignment.Left })
			UI.gem(foot, { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(0, 8, 0.5, 0) })
		end
		b.MouseButton1Click:Connect(function() clicked(it) end)
		return b
	end

	render = function()
		if gui ~= g then return end
		featuredHolder:ClearAllChildren()
		dailyHolder:ClearAllChildren()
		firstCard = nil
		credits.Text = UI.fmtInt(state.credits or 0)
		local shop = state.shop
		if not shop then
			text(dailyHolder, { Size = UDim2.new(1, 0, 0, 40), Text = "CARGANDO…", TextSize = 24, TextColor3 = UI.MUTED })
			return
		end
		local f = Catalog.Get(shop.featured)
		if f then
			text(featuredHolder, { Size = UDim2.new(1, 0, 0, 24), Text = "DESTACADO DE LA SEMANA", TextSize = 22, TextXAlignment = Enum.TextXAlignment.Left })
			firstCard = card(featuredHolder, UDim2.fromOffset(0, 34), UDim2.new(1, 0, 1, -34), f :: Catalog.Item, true)
		end
		text(dailyHolder, { Size = UDim2.new(1, 0, 0, 24), Text = "OBJETOS DEL DÍA", TextSize = 22, TextXAlignment = Enum.TextXAlignment.Left })
		for i, id in shop.items or {} do
			local it = Catalog.Get(id)
			if it then
				local col, row = (i - 1) % 3, (i - 1) // 3
				local b = card(dailyHolder, UDim2.fromOffset(col * 318, 34 + row * 292), UDim2.fromOffset(300, 276), it, false)
				if not firstCard then firstCard = b end
			end
		end
		InputGlyphs.RefreshFocus()
	end

	table.insert(conns, game:GetService("RunService").Heartbeat:Connect(function()
		local shop = state.shop
		if not shop then return end
		local gone = EconomyClient.Now() - fetchedAt
		local left, fLeft = (shop.resetIn or 0) - gone, (shop.featuredResetIn or 0) - gone
		resetLabel.Text = string.format("OBJETOS DEL DÍA: SE RENUEVAN EN %s  ·  DESTACADO: %s", DateUtil.FormatLeft(left), DateUtil.FormatLeft(fLeft))
		if left <= 0 and not busy then
			busy = true
			task.delay(2, function() busy = false; refresh() end) -- a new UTC day: new items
		end
	end))
	table.insert(conns, UIS.InputBegan:Connect(function(input)
		if ctx.modalOpen() or InputGlyphs.JustClosed() then return end -- the purchase confirmation owns the keys
		local k = input.KeyCode
		if k == Enum.KeyCode.Escape or k == Enum.KeyCode.Backspace then
			ShopScreen.Close()
		elseif (k == Enum.KeyCode.ButtonR1 or k == Enum.KeyCode.E) and #extraTabs > 0 then
			ShopScreen.Close()
			extraTabs[1][2](UI, ctx)
		end
	end))

	render()
	InputGlyphs.PushPanel(g, function() return firstCard or close end, ShopScreen.Close)
	task.spawn(refresh)
end

return ShopScreen
