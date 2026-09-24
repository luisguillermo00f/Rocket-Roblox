--!strict
-- PartyMinigameService (server): creates the Party / match remotes, owns PartyServer (parties + minigames), the
-- MatchMaker (online matches) and every running session, and drives all sessions from ONE Heartbeat connection.
-- The client never decides anything that matters: it sends controls and receives state.
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local RS = game:GetService("ReplicatedStorage")
local SSS = game:GetService("ServerScriptService")

local Net = require(RS:WaitForChild("Party"):WaitForChild("Net"))
local remotesFolder = Net.CreateRemotes()

local Registry = require(script.MinigameRegistry)
local Session = require(script.MinigameSession)
local PartyServer = require(script.PartyServer)
local MatchMaker = require(script.MatchMaker)

local service: any = {}
service.remotes = {}
for _, r in remotesFolder:GetChildren() do
	service.remotes[r.Name] = r
end
service.registry = Registry
service.sessions = {} -- session -> true
service.playerSession = {} :: { [Player]: any } -- the session each player is playing in (party round or match)
service.matchDef = require(script.Minigames:WaitForChild("Soccar"))
service.party = PartyServer.new(service)
service.matches = MatchMaker.new(service)

-- online match results go straight to the player's profile (ProfileService), never through the client
local profileSubmit = SSS:WaitForChild("ProfileService"):WaitForChild("ServerSubmit", 10) :: BindableEvent?
service.submitMatch = function(player: Player, result: any)
	if profileSubmit then profileSubmit:Fire(player, result) end
end

function service.StartSession(self: any, party: any, def: any, members: { any }, roundId: number): any
	local s = Session.new(self, party, def, members, roundId)
	self.sessions[s] = true
	for _, m in members do
		if m.kind == "player" and m.player then self.playerSession[m.player] = s end
	end
	s:Begin()
	return s
end

function service.OnSessionDone(self: any, s: any)
	self.sessions[s] = nil
	for p, ps in self.playerSession do
		if ps == s then self.playerSession[p] = nil end
	end
	if s.party.kind == "match" then
		self.matches:OnSessionDone(s)
	else
		self.party:OnSessionDone(s.party)
	end
end

-- ---------------------------------------------------------------- remotes
service.remotes.PartyRequest.OnServerInvoke = function(player: Player, action: any, arg: any)
	local ok, res = pcall(service.party.Handle, service.party, player, action, arg)
	if not ok then
		warn("[PartyMinigameService] party request failed:", res)
		return { ok = false, error = "error del servidor" }
	end
	return res
end

service.remotes.MatchRequest.OnServerInvoke = function(player: Player, action: any, arg: any)
	local ok, res = pcall(service.matches.Handle, service.matches, player, action, arg)
	if not ok then
		warn("[PartyMinigameService] match request failed:", res)
		return { ok = false, error = "error del servidor" }
	end
	return res
end

-- controls only; never trusted for anything else. Rate limited per player.
local inputBudget: { [Player]: { t: number, n: number } } = {}
service.remotes.MgInput.OnServerEvent:Connect(function(player: Player, payload: any)
	local b = inputBudget[player]
	local now = os.clock()
	if not b or now - b.t > 1 then
		b = { t = now, n = 0 }
		inputBudget[player] = b
	end
	b.n += 1
	if b.n > 150 then return end -- > 150 packets / s: ignore the excess
	local list = Net.DecodeInputs(payload)
	if not list then return end
	local s = service.playerSession[player]
	if s then
		s:PushInputs("u" .. player.UserId, list)
	end
end)

service.remotes.MgReady.OnServerEvent:Connect(function(player: Player, sessionId: any)
	local s = service.playerSession[player]
	if s and s.id == sessionId then
		s:MarkReady(player)
	end
end)

Players.PlayerRemoving:Connect(function(player)
	inputBudget[player] = nil
	service.matches:Leave(player)
	service.party:Leave(player)
	service.playerSession[player] = nil
end)

-- ---------------------------------------------------------------- one loop for every session
local lastMatchmaking = 0
RunService.Heartbeat:Connect(function(dt)
	for s in service.sessions do
		local ok, err = pcall(s.Step, s, dt)
		if not ok then
			warn("[PartyMinigameService] session error, cancelling:", err)
			pcall(s.Cancel, s, "error")
			if service.sessions[s] then
				service.sessions[s] = nil
				if s.party then s.party.session = nil end
			end
		end
	end
	local now = os.clock()
	if now - lastMatchmaking >= 0.5 then
		lastMatchmaking = now
		local ok, err = pcall(service.matches.Update, service.matches)
		if not ok then warn("[PartyMinigameService] matchmaking error:", err) end
	end
end)

game:BindToClose(function()
	for s in service.sessions do
		pcall(s.Cancel, s, "server closing")
	end
end)
