--!strict
-- DebugDraw.lua: F3 world overlays - car hitbox (OBB), ball collision sphere, wheel rays, contact normals,
-- velocity vectors and the ball prediction path. Uses handle adornments so nothing collides or casts shadows.
local RenderMap = require(script.Parent.RenderMap)
local C = require(script.Parent.Parent.Physics.PhysicsConstants)
local CarPhysics = require(script.Parent.Parent.Physics.CarPhysics)

local S = RenderMap.S
local BT = C.BT_TO_UU
local DebugDraw = {}

local folder: Folder
local hitbox: BoxHandleAdornment
local ballSphere: SphereHandleAdornment
local rays: { LineHandleAdornment } = {}
local normals: { LineHandleAdornment } = {}
local carVel: LineHandleAdornment
local ballVel: LineHandleAdornment
local predDots: { SphereHandleAdornment } = {}
local PRED_DOTS = 60

local function line(color: Color3, thickness: number): LineHandleAdornment
	local l = Instance.new("LineHandleAdornment")
	l.Adornee = workspace.Terrain
	l.Color3 = color
	l.Thickness = thickness
	l.AlwaysOnTop = true
	l.ZIndex = 1
	l.Parent = folder
	return l
end

local function setLine(l: LineHandleAdornment, from: Vector3, to: Vector3)
	local d = to - from
	local len = d.Magnitude
	if len < 1e-4 then
		l.Visible = false
		return
	end
	l.Visible = true
	l.Length = len
	l.CFrame = CFrame.lookAt(from, to)
end

function DebugDraw.Init()
	folder = Instance.new("Folder")
	folder.Name = "PhysicsDebug"
	folder.Parent = workspace.Terrain
	hitbox = Instance.new("BoxHandleAdornment")
	hitbox.Adornee = workspace.Terrain
	hitbox.Color3 = Color3.fromRGB(80, 255, 170)
	hitbox.Transparency = 0.72
	hitbox.AlwaysOnTop = true
	hitbox.Parent = folder
	ballSphere = Instance.new("SphereHandleAdornment")
	ballSphere.Adornee = workspace.Terrain
	ballSphere.Radius = C.BALL_COLLISION_RADIUS_SOCCAR * S
	ballSphere.Color3 = Color3.fromRGB(255, 220, 90)
	ballSphere.Transparency = 0.8
	ballSphere.AlwaysOnTop = true
	ballSphere.Parent = folder
	for i = 1, 4 do
		rays[i] = line(Color3.fromRGB(255, 255, 255), 3)
		normals[i] = line(Color3.fromRGB(90, 170, 255), 3)
	end
	carVel = line(Color3.fromRGB(255, 90, 90), 4)
	ballVel = line(Color3.fromRGB(255, 200, 60), 4)
	for i = 1, PRED_DOTS do
		local s = Instance.new("SphereHandleAdornment")
		s.Adornee = workspace.Terrain
		s.Radius = 0.35
		s.Color3 = Color3.fromRGB(255, 225, 120)
		s.Transparency = 0.2
		s.AlwaysOnTop = true
		s.Visible = false
		s.Parent = folder
		predDots[i] = s
	end
	DebugDraw.SetVisible(false, false)
end

function DebugDraw.SetVisible(debugOn: boolean, predictionOn: boolean)
	hitbox.Visible = debugOn
	ballSphere.Visible = debugOn
	for i = 1, 4 do
		rays[i].Visible = debugOn
		normals[i].Visible = debugOn
	end
	carVel.Visible = debugOn
	ballVel.Visible = debugOn
	for _, d in predDots do
		d.Visible = predictionOn
	end
end

function DebugDraw.Update(car: any, ball: any, carCF: CFrame, ballPos: Vector3, prediction: any?, debugOn: boolean, predictionOn: boolean)
	if debugOn then
		local b = car.body
		local hcUU = CarPhysics.GetHitboxCenter(car) * BT
		hitbox.Size = Vector3.new(car.hitboxHalf.Y * 2 * BT * S, car.hitboxHalf.Z * 2 * BT * S, car.hitboxHalf.X * 2 * BT * S)
		hitbox.CFrame = carCF.Rotation + RenderMap.Pos(hcUU)
		ballSphere.CFrame = CFrame.new(ballPos)
		for i, w in car.wheels do
			local from = RenderMap.Pos(w.hardPoint * BT)
			local rayLen = w.restLen + w.travel + w.radius - C.SUSPENSION_SUBTRACTION
			local to = RenderMap.Pos((w.hardPoint + w.wheelDir * rayLen) * BT)
			rays[i].Color3 = if w.isInContact then Color3.fromRGB(90, 255, 120) else Color3.fromRGB(255, 255, 255)
			setLine(rays[i], from, to)
			if w.isInContact then
				local cp = RenderMap.Pos(w.contactPoint * BT)
				setLine(normals[i], cp, cp + RenderMap.Dir(w.contactNormal) * 3)
			else
				normals[i].Visible = false
			end
		end
		setLine(carVel, carCF.Position, carCF.Position + RenderMap.Dir(b.vel * BT) * S * 0.25)
		setLine(ballVel, ballPos, ballPos + RenderMap.Dir(ball.body.vel * BT) * S * 0.25)
	end
	if predictionOn and prediction then
		local n = #prediction.predData
		for i = 1, PRED_DOTS do
			local idx = math.min(n, i * 12)
			local st = prediction.predData[idx]
			if st then
				predDots[i].CFrame = CFrame.new(RenderMap.Pos(st.pos))
				predDots[i].Visible = true
			end
		end
	end
end

return DebugDraw
