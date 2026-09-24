--!strict
-- DateUtil.lua: UTC day / week indices and a deterministic hash + PRNG, shared by the server and the client.
-- Everything that rotates by date (challenges, shop, featured item) goes through here, so every server - and the
-- tests - build exactly the same lists whatever the engine version (Roblox's Random is not used on purpose).
--   * day   = floor(unix / 86400)                 (changes at 00:00 UTC)
--   * week  = floor((day + 3) / 7)                (1970-01-01 was a Thursday: weeks start on Monday 00:00 UTC)
--   * Hash(...) folds numbers / strings into a uint32 (murmur3 finalizer); Rng(seed) is splitmix32 on top of it.
local DateUtil = {}

local DAY = 86400
local U32 = 4294967296
DateUtil.DAY = DAY

function DateUtil.DayIndex(t: number): number
	return math.floor(t / DAY)
end

function DateUtil.WeekIndex(t: number): number
	return math.floor((DateUtil.DayIndex(t) + 3) / 7)
end

-- first unix second of a week
function DateUtil.WeekStart(week: number): number
	return (week * 7 - 3) * DAY
end

function DateUtil.SecondsToNextDay(t: number): number
	return (DateUtil.DayIndex(t) + 1) * DAY - t
end

function DateUtil.SecondsToNextWeek(t: number): number
	return DateUtil.WeekStart(DateUtil.WeekIndex(t) + 1) - t
end

-- "5 H 12 MIN" / "3 D 4 H" / "12 MIN" (UI countdowns)
function DateUtil.FormatLeft(sec: number): string
	sec = math.max(0, math.floor(sec))
	local d, h, m = sec // DAY, (sec % DAY) // 3600, (sec % 3600) // 60
	if d > 0 then
		return string.format("%d D %d H", d, h)
	elseif h > 0 then
		return string.format("%d H %d MIN", h, m)
	end
	return string.format("%d MIN", math.max(1, m))
end

-- exact a*b mod 2^32 (a double can't hold the full 64-bit product, so multiply in 16-bit halves)
local function mul32(a: number, b: number): number
	local alo, ahi = bit32.band(a, 0xFFFF), bit32.rshift(a, 16)
	local blo, bhi = bit32.band(b, 0xFFFF), bit32.rshift(b, 16)
	local mid = (ahi * blo + alo * bhi) % 65536
	return (alo * blo + mid * 65536) % U32
end

local function mix(x: number): number
	x = bit32.bxor(x, bit32.rshift(x, 16))
	x = mul32(x, 0x85EBCA6B)
	x = bit32.bxor(x, bit32.rshift(x, 13))
	x = mul32(x, 0xC2B2AE35)
	return bit32.bxor(x, bit32.rshift(x, 16))
end
DateUtil.Mix = mix

-- uint32 hash of any list of numbers (integers) and strings
function DateUtil.Hash(...: any): number
	local h = 0x9E3779B9
	for i = 1, select("#", ...) do
		local v = select(i, ...)
		if type(v) == "number" then
			local n = math.floor(v)
			h = mix(bit32.bxor(h, n % U32))
			h = mix(bit32.bxor(h, math.floor(n / U32) % U32))
		else
			local s = tostring(v)
			for j = 1, #s do
				h = mix(bit32.bxor(h, string.byte(s, j) + j * 256))
			end
			h = mix(bit32.bxor(h, #s))
		end
	end
	return h
end

export type Rng = {
	Next: (self: Rng) -> number,
	NextInteger: (self: Rng, lo: number, hi: number) -> number,
	NextNumber: (self: Rng) -> number,
	state: number,
}

local RngMethods = {}
RngMethods.__index = RngMethods

-- uint32
function RngMethods.Next(self: any): number
	self.state = (self.state + 0x9E3779B9) % U32
	return mix(self.state)
end

-- [0, 1)
function RngMethods.NextNumber(self: any): number
	return self:Next() / U32
end

-- integer in [lo, hi]
function RngMethods.NextInteger(self: any, lo: number, hi: number): number
	return lo + math.floor(self:NextNumber() * (hi - lo + 1))
end

function DateUtil.Rng(seed: number): Rng
	return (setmetatable({ state = seed % U32 }, RngMethods) :: any) :: Rng
end

-- Fisher-Yates on a copy
function DateUtil.Shuffled<T>(list: { T }, rng: Rng): { T }
	local out = table.clone(list)
	for i = #out, 2, -1 do
		local j = rng:NextInteger(1, i)
		out[i], out[j] = out[j], out[i]
	end
	return out
end

return DateUtil
