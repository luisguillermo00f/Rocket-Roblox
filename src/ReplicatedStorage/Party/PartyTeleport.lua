--!strict
-- PartyTeleport.lua: Production TeleportService integration for multi-place Party Mode.
-- Teleports parties cleanly between the Main Place and the Party Place with TeleportData.

local TeleportService = game:GetService("TeleportService")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

local PartyTeleport = {
	PARTY_PLACE_ID = 0, -- Set in Game Settings / Place configuration when published
	MAIN_PLACE_ID = game.PlaceId,
}

export type PartyTeleportPayload = {
	partyCode: string,
	isHost: boolean,
	hostUserId: number,
	playerCount: number,
	selectedMinigames: { [string]: boolean }?,
}

function PartyTeleport.TeleportToParty(payload: PartyTeleportPayload, playerList: { Player }?)
	local lp = Players.LocalPlayer
	local targets = playerList or (if lp then { lp } else Players:GetPlayers())

	if RunService:IsStudio() or PartyTeleport.PARTY_PLACE_ID == 0 then
		print(string.format("[PartyTeleport] In Studio / Dev mode: simulating Party teleport for code '%s' (Host: %s)", payload.partyCode, tostring(payload.isHost)))
		return false
	end

	local teleportOptions = Instance.new("TeleportOptions")
	teleportOptions:SetTeleportData(payload)

	pcall(function()
		TeleportService:TeleportAsync(PartyTeleport.PARTY_PLACE_ID, targets, teleportOptions)
	end)
	return true
end

function PartyTeleport.TeleportBackToMain(player: Player?)
	local p = player or Players.LocalPlayer
	if not p then return end

	if RunService:IsStudio() then
		print("[PartyTeleport] In Studio: Teleport back to Main simulated")
		return
	end

	pcall(function()
		TeleportService:Teleport(PartyTeleport.MAIN_PLACE_ID, p)
	end)
end

return PartyTeleport
