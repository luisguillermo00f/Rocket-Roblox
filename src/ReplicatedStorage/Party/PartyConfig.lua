--!strict
-- PartyConfig.lua: Constants, slot layouts, colors, and tuning for Party Mode.
-- Elevated origin (Y = 500) completely isolates Party Mode from the main stadium.

export type SlotInfo = {
	index: number,
	isHost: boolean,
	position: Vector3,
	lookAt: Vector3,
	accentColor: Color3,
	nameColor: Color3,
	pedestalRadius: number,
}

local ORIGIN_Y = 500

local PartyConfig = {
	MAX_PLAYERS = 4,
	MIN_PLAYERS_TO_START = 2,
	ORIGIN = Vector3.new(0, ORIGIN_Y, 0),
	LOBBY_PLAYGROUND_SIZE = Vector3.new(160, 36, 180), -- studs (W, H, L)
	
	-- 4 Slot positions in world coordinates (Elevated at Y = 501.5)
	SLOTS = {
		[1] = {
			index = 1,
			isHost = true,
			position = Vector3.new(0, ORIGIN_Y + 1.2, -18),
			lookAt = Vector3.new(0, ORIGIN_Y + 1.2, 0),
			accentColor = Color3.fromRGB(255, 204, 34), -- Gold
			nameColor = Color3.fromRGB(255, 220, 80),
			pedestalRadius = 8,
		},
		[2] = {
			index = 2,
			isHost = false,
			position = Vector3.new(-28, ORIGIN_Y + 1.2, -4),
			lookAt = Vector3.new(0, ORIGIN_Y + 1.2, -4),
			accentColor = Color3.fromRGB(0, 180, 255), -- Electric Cyan
			nameColor = Color3.fromRGB(130, 220, 255),
			pedestalRadius = 7,
		},
		[3] = {
			index = 3,
			isHost = false,
			position = Vector3.new(28, ORIGIN_Y + 1.2, -4),
			lookAt = Vector3.new(0, ORIGIN_Y + 1.2, -4),
			accentColor = Color3.fromRGB(255, 65, 115), -- Neon Coral
			nameColor = Color3.fromRGB(255, 160, 190),
			pedestalRadius = 7,
		},
		[4] = {
			index = 4,
			isHost = false,
			position = Vector3.new(0, ORIGIN_Y + 1.2, 16),
			lookAt = Vector3.new(0, ORIGIN_Y + 1.2, 0),
			accentColor = Color3.fromRGB(80, 220, 70), -- Electric Lime
			nameColor = Color3.fromRGB(170, 255, 160),
			pedestalRadius = 7,
		},
	} :: { [number]: SlotInfo },

	-- Lucky Block tuning
	LUCKY_BLOCKS = {
		COUNT = 6,
		RESPAWN_SECONDS = 5.0,
		FLOAT_HEIGHT = ORIGIN_Y + 3.0,
		ROTATION_SPEED = 1.4,
		BOX_SIZE = Vector3.new(3.8, 3.8, 3.8),
		COLOR = Color3.fromRGB(245, 185, 30), -- Warm rich gold (not blinding)
		EFFECT_DURATION = 6.0,
	},

	-- Theme colors (Subtle, sleek, non-blinding)
	COLORS = {
		BG_DARK = Color3.fromRGB(18, 20, 26),
		ASPHALT = Color3.fromRGB(26, 28, 36),
		STAGE_DISC = Color3.fromRGB(34, 38, 48),
		LINE_WHITE = Color3.fromRGB(210, 215, 225),
		RAMP = Color3.fromRGB(36, 40, 52),
		HAZARD_YELLOW = Color3.fromRGB(230, 180, 25),
		GOLD = Color3.fromRGB(255, 204, 34),
		CREAM = Color3.fromRGB(248, 244, 236),
		INK = Color3.fromRGB(18, 18, 20),
		MUTED = Color3.fromRGB(115, 115, 125),
	},
}

return PartyConfig
