--!strict
-- LootboxScreen.lua: CAJAS, the second tab of TIENDA (docs/lootboxes.md §12).
--   * left: your boxes (count per type); right: the selected box - its PRICE and its ODDS (per opening and long-run
--     with pity) are always on screen before ABRIR / COMPRAR, plus the pity counters
--   * PROBABILIDADES: every item with its exact %; HISTORIAL: your last 50 openings; FRAGMENTOS: pick an item
--   * restricted accounts (PolicyService): no price, no COMPRAR; in "fragments" mode no ABRIR either - CANJEAR turns a
--     box into fragments and the list shows fragment costs instead of odds
-- Every open / buy sends the OddsVersion of the numbers shown here; the server refuses different ones. Structure and
-- logic only; the look is polished in Studio.
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local UIS = game:GetService("UserInputService")

local InputGlyphs = require(script.Parent.InputGlyphs)
local EconomyClient = require(script.Parent.EconomyClient)
local LootboxReveal = require(script.Parent.LootboxReveal)
local Economy = script.Parent.Parent:WaitForChild("Economy")
local Catalog = require(Economy:WaitForChild("CosmeticCatalog"))
local Data = require(Economy:WaitForChild("LootboxData"))
local Config = require(Economy:WaitForChild("LootboxConfig"))

local LootboxScreen = {}

local gui: ScreenGui? = nil

export type Ctx = {
	modal: (title: string, subtitle: string?, color: Color3?, items: { { any } }, opts: { [string]: any }?) -> (),
	closeModal: () -> (),
	modalOpen: () -> boolean,
	openShop: (() -> ())?, -- back to the OBJETOS tab
}

function LootboxScreen.Close()
	if gui then
		gui:Destroy()
		gui = nil
	end
end

-- a request that may meet "busy" (another request of ours still saving): retried with the SAME requestId, so the
-- server answers it once and returns the stored result afterwards
local function request(action: string, arg: { [string]: any }): { [string]: any }
	arg.requestId = arg.requestId or HttpService:GenerateGUID(false)
	for _ = 1, 6 do
		local res = EconomyClient.Request("LootboxRequest", action, arg)
		if res.ok or res.error ~= "busy" then return res end
		task.wait(1.1)
	end
	return { ok = false, error = "EL SERVIDOR ESTÁ OCUPADO: INTÉNTALO DE NUEVO" }
end

function LootboxScreen.Open(UI: any, ctx: Ctx)
	local frame, text, button = UI.frame, UI.text, UI.button
	LootboxScreen.Close()
	local g = UI.newGui("LootboxMenu", 25)
	gui = g
	local conns: { any } = {}
	g.Destroying:Connect(function()
		for _, c in conns do
			if typeof(c) == "RBXScriptConnection" then c:Disconnect() else c() end
		end
	end)

	local back = button(g, { Size = UDim2.fromScale(1, 1), BackgroundColor3 = Color3.new(0, 0, 0), BackgroundTransparency = 0.4, Selectable = false })
	back.MouseButton1Click:Connect(LootboxScreen.Close)
	local p = frame(g, { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(1500, 840), BackgroundColor3 = UI.CREAM })
	UI.brackets(p, UI.EDGE, 10, 18, 3)
	text(p, { Position = UDim2.fromOffset(40, 24), Size = UDim2.fromOffset(400, 50), Text = "TIENDA", TextSize = 46, TextXAlignment = Enum.TextXAlignment.Left })
	-- tabs: OBJETOS | CAJAS
	local function tab(label: string, x: number, on: boolean, fn: (() -> ())?)
		local b = button(p, { Position = UDim2.fromOffset(x, 34), Size = UDim2.fromOffset(150, 40), BackgroundColor3 = if on then UI.CHIP else UI.BAR, Selectable = false })
		text(b, { Size = UDim2.fromScale(1, 1), Text = label, TextSize = 22, TextColor3 = if on then UI.WHITE else UI.INK })
		if fn then b.MouseButton1Click:Connect(fn) end
	end
	local function toShop()
		if ctx.openShop then
			LootboxScreen.Close()
			ctx.openShop()
		end
	end
	tab("OBJETOS", 260, false, toShop)
	tab("CAJAS", 418, true, nil)
	InputGlyphs.Chip(p, "tabs", { dark = true, height = 30, position = UDim2.fromOffset(584, 54), anchor = Vector2.new(0, 0.5) })
	local credits = text(p, { AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -70, 0, 30), Size = UDim2.fromOffset(300, 44), Text = "", TextSize = 40, TextXAlignment = Enum.TextXAlignment.Right })
	UI.gem(p, { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(1, -50, 0, 54), Size = UDim2.fromOffset(16, 16) })
	local status = text(p, { Position = UDim2.fromOffset(42, 76), Size = UDim2.fromOffset(1400, 24), Text = "", TextSize = 18, TextColor3 = UI.MUTED, TextXAlignment = Enum.TextXAlignment.Left, FontFace = UI.OSWALD_REG })

	local left = frame(p, { Position = UDim2.fromOffset(40, 116), Size = UDim2.fromOffset(380, 640), BackgroundTransparency = 1 })
	local right = frame(p, { Position = UDim2.fromOffset(450, 116), Size = UDim2.fromOffset(1010, 640), BackgroundTransparency = 1 })
	local close = button(p, { AnchorPoint = Vector2.new(1, 1), Position = UDim2.new(1, -28, 1, -28), Size = UDim2.fromOffset(250, 64), BackgroundColor3 = UI.CHIP })
	text(close, { Position = UDim2.fromOffset(22, 0), Size = UDim2.new(1, -100, 1, 0), Text = "CERRAR", TextSize = 28, TextColor3 = UI.WHITE, TextXAlignment = Enum.TextXAlignment.Left })
	UI.chip(close, "ESC", false)
	close.MouseButton1Click:Connect(LootboxScreen.Close)

	local state: { [string]: any } = {}
	local selected = Data.BOX_ORDER[1]
	local view = "detail" -- detail | odds | history | redeem
	local busy = false
	local firstFocus: GuiObject? = nil
	local render: () -> () = function() end

	local function noRandom(): boolean
		return state.restricted == true and state.mode == "fragments"
	end

	local function applyState(s: any)
		if type(s) == "table" and s.ok ~= false then
			state = s
		end
	end

	local function refresh()
		local res = EconomyClient.Request("LootboxRequest", "state")
		if gui ~= g then return end
		if res.ok then applyState(res) else status.Text = tostring(res.error) end
		render()
	end

	-- ---------------------------------------------------------------- actions
	local openBox: (boxId: string) -> ()
	openBox = function(boxId: string)
		if busy then return end
		local box = Data.Get(boxId) :: Data.Box
		busy = true
		local result: any = nil
		task.spawn(function()
			result = request("open", { box = boxId, oddsVersion = Data.OddsVersion(box) })
			if type(result) == "table" and result.state then applyState(result.state) end
		end)
		LootboxReveal.Play(UI, box, function()
			while result == nil do task.wait() end
			return result
		end, {
			again = function()
				busy = false
				openBox(boxId)
			end,
			equip = function(r: any)
				local it = Catalog.Get(r.item)
				if it then task.spawn(EconomyClient.Request, "CosmeticsRequest", "equip", { slot = it.slot, id = it.id }) end
			end,
			closed = function()
				busy = false
				if gui == g then render() end
			end,
		})
		busy = false
		if gui == g then render() end
	end

	local function buyBox(box: Data.Box)
		local odds = box.odds
		local epicPlus = ((odds.epic or 0) + (odds.legendary or 0) + (odds.exotic or 0)) / 10000
		ctx.modal("¿COMPRAR " .. box.name .. "?", string.format("%s CRÉDITOS  ·  ÉPICA O MEJOR: %s  ·  LEGENDARIA O MEJOR: %s", UI.fmtInt(box.price),
			Data.FormatPct(epicPlus), Data.FormatPct(((odds.legendary or 0) + (odds.exotic or 0)) / 10000)), box.color, {
			{ "COMPRAR", "ENTER", function()
				ctx.closeModal()
				task.spawn(function()
					status.Text = "COMPRANDO…"
					local res = request("buy", { box = box.id, oddsVersion = Data.OddsVersion(box) })
					if gui ~= g then return end
					status.Text = if res.ok then "¡CAJA COMPRADA!" else tostring(res.error)
					applyState(res.state)
					render()
				end)
			end },
			{ "VER PROBABILIDADES", "R", function() ctx.closeModal(); view = "odds"; render() end },
			{ "CANCELAR", "ESC", function() ctx.closeModal() end },
		})
	end

	local function convertBox(box: Data.Box)
		ctx.modal("¿CANJEAR " .. box.name .. "?", string.format("+%d FRAGMENTOS DE ESTA CAJA (SIN AZAR)", box.convertFragments), box.color, {
			{ "CANJEAR", "ENTER", function()
				ctx.closeModal()
				task.spawn(function()
					local res = request("convert", { box = box.id })
					if gui ~= g then return end
					status.Text = if res.ok then string.format("+%d FRAGMENTOS", res.fragments or 0) else tostring(res.error)
					applyState(res.state)
					render()
				end)
			end },
			{ "CANCELAR", "ESC", function() ctx.closeModal() end },
		})
	end

	local function redeem(box: Data.Box, id: string, cost: number)
		local it = Catalog.Get(id)
		if not it then return end
		ctx.modal("¿CANJEAR?", string.format("%s  ·  %s FRAGMENTOS", it.name, UI.fmtInt(cost)), Catalog.RARITIES[it.rarity].color, {
			{ "CANJEAR", "ENTER", function()
				ctx.closeModal()
				task.spawn(function()
					local res = request("redeem", { box = box.id, item = id })
					if gui ~= g then return end
					status.Text = if res.ok then "¡CONSEGUIDO: " .. it.name .. "!" else tostring(res.error)
					applyState(res.state)
					render()
				end)
			end },
			{ "CANCELAR", "ESC", function() ctx.closeModal() end },
		})
	end

	-- ---------------------------------------------------------------- drawing
	local function smallButton(parent: Instance, label: string, pos: UDim2, w: number, dark: boolean, fn: () -> ()): TextButton
		local b = button(parent, { Position = pos, Size = UDim2.fromOffset(w, 56), BackgroundColor3 = if dark then UI.CHIP else UI.BAR })
		text(b, { Size = UDim2.fromScale(1, 1), Text = label, TextSize = 22, TextColor3 = if dark then UI.WHITE else UI.INK })
		b.MouseButton1Click:Connect(fn)
		return b
	end

	local function scroller(parent: Instance, y: number): ScrollingFrame
		local sf = Instance.new("ScrollingFrame")
		sf.Position = UDim2.fromOffset(0, y)
		sf.Size = UDim2.new(1, 0, 1, -y)
		sf.BackgroundTransparency = 1
		sf.BorderSizePixel = 0
		sf.ScrollBarThickness = 6
		sf.CanvasSize = UDim2.new()
		sf.AutomaticCanvasSize = Enum.AutomaticSize.Y
		sf.Selectable = false
		sf.Parent = parent
		local l = Instance.new("UIListLayout")
		l.Padding = UDim.new(0, 6)
		l.SortOrder = Enum.SortOrder.LayoutOrder
		l.Parent = sf
		return sf
	end

	local function backRow(parent: Instance, title: string)
		text(parent, { Size = UDim2.fromOffset(700, 40), Text = title, TextSize = 34, TextXAlignment = Enum.TextXAlignment.Left })
		firstFocus = smallButton(parent, "‹  VOLVER", UDim2.new(1, -180, 0, -4), 180, false, function() view = "detail"; render() end)
	end

	local function drawOdds(box: Data.Box)
		backRow(right, if noRandom() then "CONTENIDO · " .. box.name else "PROBABILIDADES · " .. box.name)
		local sf = scroller(right, 56)
		for i, e in Data.ItemOdds(box) do
			local it = Catalog.Get(e.id)
			local rar = Catalog.RARITIES[e.rarity]
			local row = button(sf, { LayoutOrder = i, Size = UDim2.new(1, -12, 0, 44), BackgroundColor3 = UI.PANEL, AutoButtonColor = false })
			frame(row, { Size = UDim2.new(0, 6, 1, 0), BackgroundColor3 = rar.color })
			text(row, { Position = UDim2.fromOffset(20, 0), Size = UDim2.fromOffset(160, 44), Text = rar.name, TextSize = 18, TextColor3 = UI.MUTED, TextXAlignment = Enum.TextXAlignment.Left, FontFace = UI.OSWALD_REG })
			text(row, { Position = UDim2.fromOffset(180, 0), Size = UDim2.fromOffset(520, 44), Text = (if it then it.name else e.id) .. "  ·  " .. (if it then Catalog.SLOT_NAMES[it.slot] or "" else ""), TextSize = 22, TextXAlignment = Enum.TextXAlignment.Left })
			local right2 = if noRandom() then UI.fmtInt(Config.REDEEM_COST[e.rarity]) .. " FRAGMENTOS" else Data.FormatPct(e.p)
			text(row, { AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -20, 0, 0), Size = UDim2.fromOffset(240, 44), Text = right2, TextSize = 22, TextXAlignment = Enum.TextXAlignment.Right })
		end
	end

	local function drawHistory()
		backRow(right, "HISTORIAL  ·  ÚLTIMAS " .. Config.HISTORY_SIZE)
		local sf = scroller(right, 56)
		local hist = state.history or {}
		if #hist == 0 then
			text(sf, { Size = UDim2.new(1, 0, 0, 40), Text = "TODAVÍA NO HAS ABIERTO NINGUNA CAJA", TextSize = 22, TextColor3 = UI.MUTED })
		end
		for i = #hist, 1, -1 do
			local h = hist[i]
			local it = Catalog.Get(h.item)
			local rar = Catalog.RARITIES[h.rarity] or Catalog.RARITIES.common
			local box = Data.Get(h.box)
			local row = button(sf, { LayoutOrder = #hist - i, Size = UDim2.new(1, -12, 0, 44), BackgroundColor3 = UI.PANEL, AutoButtonColor = false })
			frame(row, { Size = UDim2.new(0, 6, 1, 0), BackgroundColor3 = rar.color })
			local lt = os.date("*t", h.t) :: any -- local time
			text(row, { Position = UDim2.fromOffset(20, 0), Size = UDim2.fromOffset(150, 44), Text = string.format("%02d/%02d %02d:%02d", lt.day, lt.month, lt.hour, lt.min), TextSize = 18, TextColor3 = UI.MUTED, TextXAlignment = Enum.TextXAlignment.Left, FontFace = UI.OSWALD_REG })
			text(row, { Position = UDim2.fromOffset(170, 0), Size = UDim2.fromOffset(250, 44), Text = if box then box.name else tostring(h.box), TextSize = 18, TextColor3 = UI.MUTED, TextXAlignment = Enum.TextXAlignment.Left, FontFace = UI.OSWALD_REG })
			text(row, { Position = UDim2.fromOffset(420, 0), Size = UDim2.fromOffset(330, 44), Text = if it then it.name else tostring(h.item), TextSize = 22, TextColor3 = rar.color, TextXAlignment = Enum.TextXAlignment.Left })
			local extra = if h.dup then (if h.gave and h.gave.credits then "DUPLICADO +" .. h.gave.credits .. " CR" else "DUPLICADO +" .. tostring(h.gave and h.gave.fragments or 0) .. " FRAG") else "NUEVO"
			if h.pity then extra ..= "  ·  GARANTÍA" end
			text(row, { AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -20, 0, 0), Size = UDim2.fromOffset(240, 44), Text = extra, TextSize = 18, TextXAlignment = Enum.TextXAlignment.Right })
		end
		if (state.unseen or 0) > 0 then
			task.spawn(EconomyClient.Request, "LootboxRequest", "ack")
			state.unseen = 0
		end
	end

	local function drawRedeem(box: Data.Box)
		local have = (state.fragments or {})[box.id] or 0
		backRow(right, string.format("FRAGMENTOS · %s  (%s)", box.name, UI.fmtInt(have)))
		local owned = {}
		local prof = EconomyClient.Get()
		for _, id in (prof and prof.owned or {}) :: { string } do owned[id] = true end
		local sf = scroller(right, 56)
		for i, e in Data.ItemOdds(box) do
			local it = Catalog.Get(e.id)
			local rar = Catalog.RARITIES[e.rarity]
			local cost = Config.REDEEM_COST[e.rarity]
			local mine = owned[e.id] == true
			local row = button(sf, { LayoutOrder = i, Size = UDim2.new(1, -12, 0, 44), BackgroundColor3 = UI.PANEL, BackgroundTransparency = if mine then 0.5 else 0 })
			frame(row, { Size = UDim2.new(0, 6, 1, 0), BackgroundColor3 = rar.color })
			text(row, { Position = UDim2.fromOffset(20, 0), Size = UDim2.fromOffset(600, 44), Text = (if it then it.name else e.id) .. "  ·  " .. rar.name, TextSize = 22, TextXAlignment = Enum.TextXAlignment.Left })
			text(row, { AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -20, 0, 0), Size = UDim2.fromOffset(260, 44),
				Text = if mine then "YA LO TIENES" else UI.fmtInt(cost) .. " FRAGMENTOS", TextSize = 20, TextColor3 = if have >= cost and not mine then UI.BLUE else UI.MUTED, TextXAlignment = Enum.TextXAlignment.Right })
			if not mine then row.MouseButton1Click:Connect(function() redeem(box, e.id, cost) end) end
		end
	end

	local function drawDetail(box: Data.Box)
		local count = (state.boxes or {})[box.id] or 0
		local available = not box.season or state.seasonActive == true
		frame(right, { Size = UDim2.new(1, 0, 0, 8), BackgroundColor3 = box.color })
		text(right, { Position = UDim2.fromOffset(0, 16), Size = UDim2.fromOffset(700, 48), Text = box.name, TextSize = 44, TextXAlignment = Enum.TextXAlignment.Left })
		text(right, { Position = UDim2.fromOffset(2, 64), Size = UDim2.fromOffset(1000, 22), Text = box.description, TextSize = 17, TextColor3 = UI.MUTED, TextXAlignment = Enum.TextXAlignment.Left, FontFace = UI.OSWALD_REG })
		-- price (never shown to restricted accounts)
		if not state.restricted then
			local priceText = if available then UI.fmtInt(box.price) else "NO DISPONIBLE"
			text(right, { AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -30, 0, 18), Size = UDim2.fromOffset(300, 44), Text = priceText, TextSize = 40, TextXAlignment = Enum.TextXAlignment.Right })
			if available then UI.gem(right, { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(1, -12, 0, 40), Size = UDim2.fromOffset(16, 16) }) end
		end
		-- odds table: always visible before any ABRIR / COMPRAR
		local tbl = frame(right, { Position = UDim2.fromOffset(0, 100), Size = UDim2.fromOffset(620, 250), BackgroundColor3 = UI.PANEL })
		if noRandom() then
			text(tbl, { Position = UDim2.fromOffset(20, 16), Size = UDim2.new(1, -40, 1, -32), TextWrapped = true, TextYAlignment = Enum.TextYAlignment.Top, TextXAlignment = Enum.TextXAlignment.Left,
				Text = "EN TU CUENTA LAS CAJAS NO SE ABREN AL AZAR NI SE PUEDEN COMPRAR. CANJEA CADA CAJA POR " .. box.convertFragments
					.. " FRAGMENTOS Y ELIGE EL OBJETO QUE QUIERAS EN «CONTENIDO».", TextSize = 22 })
		else
			local eff = Data.EffectiveRates(box)
			text(tbl, { Position = UDim2.fromOffset(20, 10), Size = UDim2.fromOffset(200, 26), Text = "RAREZA", TextSize = 18, TextColor3 = UI.MUTED, TextXAlignment = Enum.TextXAlignment.Left })
			text(tbl, { Position = UDim2.fromOffset(250, 10), Size = UDim2.fromOffset(160, 26), Text = "POR CAJA", TextSize = 18, TextColor3 = UI.MUTED, TextXAlignment = Enum.TextXAlignment.Right })
			text(tbl, { Position = UDim2.fromOffset(420, 10), Size = UDim2.fromOffset(180, 26), Text = "MEDIA CON GARANTÍA", TextSize = 18, TextColor3 = UI.MUTED, TextXAlignment = Enum.TextXAlignment.Right })
			for i, r in Data.RARITIES do
				local rar = Catalog.RARITIES[r]
				local y = 40 + (i - 1) * 40
				frame(tbl, { Position = UDim2.fromOffset(20, y + 8), Size = UDim2.fromOffset(18, 18), BackgroundColor3 = rar.color })
				text(tbl, { Position = UDim2.fromOffset(48, y), Size = UDim2.fromOffset(200, 34), Text = rar.name, TextSize = 24, TextXAlignment = Enum.TextXAlignment.Left })
				text(tbl, { Position = UDim2.fromOffset(250, y), Size = UDim2.fromOffset(160, 34), Text = Data.FormatPct((box.odds[r] or 0) / 10000), TextSize = 24, TextXAlignment = Enum.TextXAlignment.Right })
				text(tbl, { Position = UDim2.fromOffset(420, y), Size = UDim2.fromOffset(180, 34), Text = Data.FormatPct(eff[r] or 0), TextSize = 24, TextColor3 = UI.MUTED, TextXAlignment = Enum.TextXAlignment.Right })
			end
		end
		-- pity
		local pity = (state.pity or {})[box.id]
		if pity and not noRandom() then
			text(right, { Position = UDim2.fromOffset(0, 360), Size = UDim2.fromOffset(1000, 26), TextXAlignment = Enum.TextXAlignment.Left, TextSize = 20,
				Text = string.format("ÉPICA O MEJOR GARANTIZADA COMO MUCHO EN %d CAJAS  ·  LEGENDARIA O MEJOR EN %d", pity.epicIn, pity.legendaryIn) })
		end
		-- side info
		local fr = (state.fragments or {})[box.id] or 0
		text(right, { Position = UDim2.fromOffset(660, 110), Size = UDim2.fromOffset(340, 220), TextWrapped = true, TextYAlignment = Enum.TextYAlignment.Top, TextXAlignment = Enum.TextXAlignment.Left,
			TextSize = 18, TextColor3 = UI.MUTED, FontFace = UI.OSWALD_REG,
			Text = string.format("TIENES %d  ·  FRAGMENTOS: %s\nDUPLICADOS → %s\nCOMPRAS QUE TE QUEDAN HOY: %d\nSE CONSIGUEN: NIVELES, DESAFÍOS SEMANALES Y AL TERMINAR PARTIDAS EN LÍNEA (MÁX. %d AL DÍA)",
				count, UI.fmtInt(fr), if state.dupMode == "credits" then "CRÉDITOS" else "FRAGMENTOS", state.buysLeft or 0, Config.DAILY_DROP_CAP) })

		-- buttons (row 1: the main actions; row 2: lists and options)
		local y1, y2 = 410, 480
		local x = 0
		local function add(label: string, w: number, dark: boolean, fn: () -> (), row: number): TextButton
			local b = smallButton(right, label, UDim2.fromOffset(x, if row == 1 then y1 else y2), w, dark, fn)
			x += w + 12
			if not firstFocus then firstFocus = b end
			return b
		end
		if noRandom() then
			if count > 0 then add(string.format("CANJEAR CAJA  (×%d)", count), 300, true, function() convertBox(box) end, 1) end
		else
			if count > 0 then add(string.format("ABRIR  (×%d)", count), 240, true, function() openBox(box.id) end, 1) end
			if not state.restricted and available then add("COMPRAR · " .. UI.fmtInt(box.price), 240, count == 0, function() buyBox(box) end, 1) end
		end
		x = 0
		add(if noRandom() then "CONTENIDO" else "PROBABILIDADES", 220, false, function() view = "odds"; render() end, 2)
		add("FRAGMENTOS · " .. UI.fmtInt(fr), 240, false, function() view = "redeem"; render() end, 2)
		add("HISTORIAL" .. (if (state.unseen or 0) > 0 then " (" .. state.unseen .. ")" else ""), 200, false, function() view = "history"; render() end, 2)
		add("DUPLICADOS: " .. (if state.dupMode == "credits" then "CRÉDITOS" else "FRAGMENTOS"), 300, false, function()
			local mode = if state.dupMode == "credits" then "fragments" else "credits"
			task.spawn(function()
				local res = EconomyClient.Request("LootboxRequest", "dupMode", mode)
				if res.ok then state.dupMode = mode end
				if gui == g then render() end
			end)
		end, 2)
		if (state.unseen or 0) > 0 then
			text(right, { Position = UDim2.fromOffset(0, 552), Size = UDim2.fromOffset(1000, 26), Text = "¡TIENES OBJETOS NUEVOS DE CAJAS! MÍRALOS EN HISTORIAL", TextSize = 20, TextColor3 = UI.BLUE, TextXAlignment = Enum.TextXAlignment.Left })
		end
	end

	render = function()
		if gui ~= g then return end
		left:ClearAllChildren()
		right:ClearAllChildren()
		firstFocus = nil
		credits.Text = UI.fmtInt(state.credits or 0)
		for i, box in Data.All() do
			local count = (state.boxes or {})[box.id] or 0
			local on = box.id == selected
			local b = button(left, { Position = UDim2.fromOffset(0, (i - 1) * 132), Size = UDim2.fromOffset(380, 120), BackgroundColor3 = if on then UI.CHIP else UI.PANEL })
			frame(b, { Size = UDim2.new(0, 8, 1, 0), BackgroundColor3 = box.color })
			text(b, { Position = UDim2.fromOffset(26, 16), Size = UDim2.fromOffset(250, 40), Text = box.name, TextSize = 28, TextColor3 = if on then UI.WHITE else UI.INK, TextXAlignment = Enum.TextXAlignment.Left, TextWrapped = true })
			text(b, { AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -20, 0, 16), Size = UDim2.fromOffset(90, 44), Text = "×" .. count, TextSize = 40, TextColor3 = if on then UI.GOLD else UI.INK, TextXAlignment = Enum.TextXAlignment.Right })
			local sub = if box.season and not state.seasonActive then "FUERA DE TEMPORADA" elseif state.restricted then "" else UI.fmtInt(box.price) .. " CRÉDITOS"
			text(b, { Position = UDim2.fromOffset(26, 74), Size = UDim2.fromOffset(330, 26), Text = sub, TextSize = 18, TextColor3 = UI.MUTED, TextXAlignment = Enum.TextXAlignment.Left, FontFace = UI.OSWALD_REG })
			b.MouseButton1Click:Connect(function()
				selected = box.id
				view = "detail"
				render()
			end)
		end
		local box = Data.Get(selected) :: Data.Box
		if not state.boxes then
			text(right, { Size = UDim2.new(1, 0, 0, 40), Text = "CARGANDO…", TextSize = 24, TextColor3 = UI.MUTED })
		elseif view == "odds" then
			drawOdds(box)
		elseif view == "history" then
			drawHistory()
		elseif view == "redeem" then
			drawRedeem(box)
		else
			drawDetail(box)
		end
		if state.canSpend == false then status.Text = "TU PERFIL NO SE ESTÁ GUARDANDO: LAS CAJAS NO SE PUEDEN USAR AHORA" end
		InputGlyphs.RefreshFocus()
	end

	table.insert(conns, UIS.InputBegan:Connect(function(input)
		if ctx.modalOpen() or InputGlyphs.JustClosed() or busy then return end
		if (Players.LocalPlayer:FindFirstChild("PlayerGui") :: any):FindFirstChild("LootboxOpening") then return end -- the reveal owns the keys
		local k = input.KeyCode
		if k == Enum.KeyCode.Escape or k == Enum.KeyCode.Backspace then
			if view ~= "detail" then
				view = "detail"
				render()
			else
				LootboxScreen.Close()
			end
		elseif k == Enum.KeyCode.ButtonL1 or k == Enum.KeyCode.Q then
			toShop()
		elseif k == Enum.KeyCode.ButtonR1 or k == Enum.KeyCode.E then
			local i = table.find(Data.BOX_ORDER, selected) or 1
			selected = Data.BOX_ORDER[i % #Data.BOX_ORDER + 1]
			view = "detail"
			render()
		end
	end))
	table.insert(conns, EconomyClient.OnUpdate(function(prof)
		if type(prof) == "table" and type(prof.credits) == "number" then
			state.credits = prof.credits
			if type(prof.boxes) == "table" then state.boxes = prof.boxes end
			if gui == g and not busy then render() end
		end
	end))

	render()
	InputGlyphs.PushPanel(g, function() return firstFocus or close end, function()
		if view ~= "detail" then
			view = "detail"
			render()
		else
			LootboxScreen.Close()
		end
	end)
	task.spawn(refresh)
end

return LootboxScreen
