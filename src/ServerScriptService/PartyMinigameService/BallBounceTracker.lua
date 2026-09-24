--!strict
-- BallBounceTracker.lua: floor contacts of the ball from the authoritative simulation, with a contact state so one
-- physical bounce is one event no matter how many ticks the ball stays in contact.
--
--   GROUND_CONTACT_ENTER -> "enter" event (counts one bounce)
--   still touching       -> nothing
--   leaves the floor     -> contact state resets (hysteresis: must rise RELEASE uu above the contact height)
--   rolling on the floor -> after DEAD_ROLL seconds of continuous contact, one "dead" event (ball is dead)
-- Units: UU, sim axes (z up). The floor is the arena plane z = 0; the ball touches it at z = radius.
local BallBounceTracker = {}
BallBounceTracker.__index = BallBounceTracker

local CONTACT_EPS = 4 -- uu: within this of the floor counts as touching (Bullet contact margin is ~1.8)
local RELEASE = 18 -- uu above contact height before a new contact can count
local DEAD_ROLL = 0.4 -- s of continuous contact = dead ball

function BallBounceTracker.new(radius: number)
	return setmetatable({ radius = radius, touching = false, contactTime = 0, deadSent = false }, BallBounceTracker)
end

function BallBounceTracker.Reset(self: any)
	self.touching = false
	self.contactTime = 0
	self.deadSent = false
end

-- returns "enter", "dead" or nil
function BallBounceTracker.Update(self: any, posUU: Vector3, velUU: Vector3, dt: number): string?
	local h = posUU.Z - self.radius
	if not self.touching then
		if h <= CONTACT_EPS and velUU.Z <= 60 then
			self.touching = true
			self.contactTime = 0
			self.deadSent = false
			return "enter"
		end
		return nil
	end
	if h > RELEASE then
		self.touching = false
		self.contactTime = 0
		return nil
	end
	self.contactTime += dt
	if self.contactTime >= DEAD_ROLL and not self.deadSent then
		self.deadSent = true
		return "dead"
	end
	return nil
end

return BallBounceTracker
