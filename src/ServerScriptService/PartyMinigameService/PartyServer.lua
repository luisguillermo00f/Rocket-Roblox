--!strict
-- PartyServer.lua: parties on this server (code, host, up to 4 members: players or bots the host added), their
-- Party Points, and the only entry point to start a minigame. Everything is validated here; clients only ask.
--
-- Party Points are decided here from the placements a minigame returns (the minigame never awards points).
-- A party lives on one server; its code works from any server (CodeDirectory teleports the joiner to it).
local Players = game:GetService("Players")
local CodeDirectory = require(script.Parent.CodeDirectory)
local Cosmetics = require(game:GetService("ServerScriptService"):WaitForChild("Economy"):WaitForChild("CosmeticsService"))

local PartyServer = {}
PartyServer.__index = PartyServer

local MAX_MEMBERS = 4
local PARTY_POINTS = { 10, 6, 3, 1 } -- by placement (ties share the better one)
local BOT_NAMES = { "Vórtice", "Nitro", "Cometa", "Titán", "Raptor", "Ónix", "Pulso", "Cénit", "Órbita", "Rayo" }

function PartyServer.new(service: any)
	local self = setmetatable({}, PartyServer)
	self.service = service
	self.parties = {} -- code -> party
	self.ofPlayer = {} -- Player -> party
	self.nextBot = 1
	self.startGuard = {} -- party code -> true while a start is being processed
	return self
end

local function newCode(existing: { [string]: any }): string
	local rng = Random.new()
	for _ = 1, 50 do
		local code = ("RR-%04d"):format(rng:NextInteger(0, 9999))
		if not existing[code] and not CodeDirectory.Taken(code) then return code end
	end
	return "RR-" .. tostring(os.clock()):gsub("%.", "")
end

function PartyServer.State(self: any, party: any): any
	local members = {}
	for _, m in party.members do
		table.insert(members, {
			id = m.id, name = m.name, isBot = m.kind == "bot", userId = m.userId,
			isHost = m.userId ~= nil and m.userId == party.hostUserId, points = party.points[m.id] or 0,
			cosmetics = if m.kind == "player" and m.player then Cosmetics.LoadoutFor(m.player) else nil,
		})
	end
	return {
		code = party.code, hostUserId = party.hostUserId, members = members,
		inSession = party.session ~= nil, sessionMinigame = party.session and party.session.def.Id,
		catalogue = self.service.registry.Catalogue(),
	}
end

function PartyServer.Push(self: any, party: any)
	local st = self:State(party)
	for _, m in party.members do
		if m.kind == "player" and m.player and m.player.Parent then
			self.service.remotes.PartyState:FireClient(m.player, st)
		end
	end
end

local function memberOfPlayer(player: Player): any
	return { id = "u" .. player.UserId, kind = "player", player = player, userId = player.UserId, name = player.DisplayName, hitbox = "Octane", skin = "Octane" }
end

function PartyServer.Create(self: any, player: Player): any
	local existing = self.ofPlayer[player]
	if existing then return existing end
	local party = { code = newCode(self.parties), hostUserId = player.UserId, members = { memberOfPlayer(player) }, points = {}, session = nil, rounds = 0 }
	self.parties[party.code] = party
	self.ofPlayer[player] = party
	CodeDirectory.Register(party.code)
	self:Push(party)
	return party
end

function PartyServer.Join(self: any, player: Player, code: string): (any, string?)
	if type(code) ~= "string" or #code > 12 then return nil, "código inválido" end
	code = string.upper(code)
	local party = self.parties[code]
	if not party then
		-- hosted on another server? go there (the client re-joins with the code on arrival)
		local entry = CodeDirectory.Lookup(code)
		if entry then
			local _, err = CodeDirectory.TeleportTo(player, entry, { joinParty = code })
			return nil, err or "viajando al servidor del grupo..."
		end
		return nil, "no existe esa party"
	end
	if self.ofPlayer[player] == party then return party, nil end
	if #party.members >= MAX_MEMBERS then return nil, "la party está llena" end
	if self.ofPlayer[player] then self:Leave(player) end
	local m = memberOfPlayer(player)
	table.insert(party.members, m)
	self.ofPlayer[player] = party
	if party.session then
		party.session:HandleLateJoin(m) -- watches this round, plays the next one
	end
	self:Push(party)
	return party, nil
end

function PartyServer.Leave(self: any, player: Player)
	local party = self.ofPlayer[player]
	if not party then return end
	self.ofPlayer[player] = nil
	local id = "u" .. player.UserId
	for i, m in party.members do
		if m.id == id then table.remove(party.members, i) break end
	end
	if party.session then
		party.session:HandleLeave(id)
	end
	-- host migration, or disband when no human is left (bots alone never keep a party alive)
	local humans = {}
	for _, m in party.members do
		if m.kind == "player" then table.insert(humans, m) end
	end
	if #humans == 0 then
		if party.session then party.session:Cancel("party disbanded") end
		self.parties[party.code] = nil
		CodeDirectory.Unregister(party.code)
		return
	end
	if party.hostUserId == player.UserId then
		party.hostUserId = humans[1].userId
	end
	self:Push(party)
end

function PartyServer.AddBot(self: any, player: Player): (boolean, string?)
	local party = self.ofPlayer[player]
	if not party then return false, "no estás en una party" end
	if party.hostUserId ~= player.UserId then return false, "solo el anfitrión" end
	if party.session then return false, "hay un minijuego en curso" end
	if #party.members >= MAX_MEMBERS then return false, "la party está llena" end
	local name = BOT_NAMES[(self.nextBot - 1) % #BOT_NAMES + 1]
	table.insert(party.members, { id = "b" .. self.nextBot, kind = "bot", name = name, hitbox = "Octane", skin = "Octane" })
	self.nextBot += 1
	self:Push(party)
	return true, nil
end

function PartyServer.RemoveBot(self: any, player: Player, botId: string?): (boolean, string?)
	local party = self.ofPlayer[player]
	if not party or party.hostUserId ~= player.UserId then return false, "solo el anfitrión" end
	if party.session then return false, "hay un minijuego en curso" end
	for i = #party.members, 1, -1 do
		local m = party.members[i]
		if m.kind == "bot" and (botId == nil or m.id == botId) then
			table.remove(party.members, i)
			self:Push(party)
			return true, nil
		end
	end
	return false, "no hay bots"
end

function PartyServer.StartMinigame(self: any, player: Player, minigameId: string): (boolean, string?)
	local party = self.ofPlayer[player]
	if not party then return false, "no estás en una party" end
	if party.hostUserId ~= player.UserId then return false, "solo el anfitrión puede empezar" end
	if party.session or self.startGuard[party.code] then return false, "ya hay un minijuego en curso" end
	local def = self.service.registry.Get(minigameId)
	if not def then return false, "minijuego desconocido" end
	local n = #party.members
	if n < def.MinPlayers then return false, ("se necesitan al menos %d jugadores"):format(def.MinPlayers) end
	if n > def.MaxPlayers then return false, ("máximo %d jugadores"):format(def.MaxPlayers) end
	self.startGuard[party.code] = true
	party.rounds += 1
	local ok, err = pcall(function()
		party.session = self.service:StartSession(party, def, party.members, party.rounds)
	end)
	self.startGuard[party.code] = nil
	if not ok then
		party.session = nil
		warn("[PartyServer] could not start", minigameId, err)
		return false, "no se pudo iniciar el minijuego"
	end
	self:Push(party)
	return true, nil
end

function PartyServer.OnSessionDone(self: any, party: any)
	party.session = nil
	if self.parties[party.code] then
		self:Push(party)
	end
end

-- placements: { { id, placement } } -> { [memberId] = points awarded } (also added to party totals)
function PartyServer.AwardPartyPoints(self: any, party: any, placements: { any }): { [string]: number }
	local out = {}
	for _, p in placements do
		local pts = PARTY_POINTS[p.placement] or 0
		out[p.id] = pts
		party.points[p.id] = (party.points[p.id] or 0) + pts
	end
	return out
end

function PartyServer.OfPlayer(self: any, player: Player): any
	return self.ofPlayer[player]
end

-- RemoteFunction entry point
function PartyServer.Handle(self: any, player: Player, action: any, arg: any): any
	if type(action) ~= "string" then return { ok = false, error = "petición inválida" } end
	local ok, err
	if action == "create" then
		self:Create(player); ok = true
	elseif action == "join" then
		local p; p, err = self:Join(player, arg); ok = p ~= nil
	elseif action == "leave" then
		self:Leave(player); ok = true
	elseif action == "addBot" then
		ok, err = self:AddBot(player)
	elseif action == "removeBot" then
		ok, err = self:RemoveBot(player, if type(arg) == "string" then arg else nil)
	elseif action == "start" then
		ok, err = self:StartMinigame(player, arg)
	elseif action == "state" then
		ok = true
	else
		return { ok = false, error = "acción desconocida" }
	end
	local party = self.ofPlayer[player]
	return { ok = ok == true, error = err, state = party and self:State(party) }
end

return PartyServer
