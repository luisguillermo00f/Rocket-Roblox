--!strict
-- MinigameState.lua: the session phases and the only allowed transitions. Any phase may jump to CLEANUP (cancel).
local MinigameState = {
	LOADING = "LOADING",
	COUNTDOWN = "COUNTDOWN",
	ACTIVE = "ACTIVE",
	ENDING = "ENDING",
	RESULTS = "RESULTS",
	CLEANUP = "CLEANUP",
	DONE = "DONE",
}

local NEXT = {
	LOADING = "COUNTDOWN",
	COUNTDOWN = "ACTIVE",
	ACTIVE = "ENDING",
	ENDING = "RESULTS",
	RESULTS = "CLEANUP",
	CLEANUP = "DONE",
}

-- seconds each timed phase lasts (ACTIVE comes from the minigame's MaxDuration)
MinigameState.DURATION = {
	LOADING = 6, -- hard cap waiting for clients to load; starts early once all humans report ready
	COUNTDOWN = 3.2,
	ENDING = 1.6,
	RESULTS = 5,
}

function MinigameState.CanTransition(from: string, to: string): boolean
	if from == MinigameState.DONE then
		return false
	end
	return NEXT[from] == to or (to == MinigameState.CLEANUP and from ~= MinigameState.CLEANUP)
end

function MinigameState.Next(from: string): string?
	return NEXT[from]
end

return MinigameState
