--!strict
-- PhysicsConstants.lua
-- 1:1 port of RocketSim 2.2.1 RLConst.h (plus the Bullet solver settings RocketSim uses).
--
-- UNITS
--   * Every RL value below is in Unreal Units (UU, 1 UU = 2 cm) exactly as in RLConst.h.
--   * The simulation itself runs in Bullet units (BT, 1 BT = 50 UU = 1 m), like RocketSim.
--     Convert with UU_TO_BT / BT_TO_UU. Never mix the two.
--   * Rendering uses STUDS_PER_UU (1 stud = 20 UU).
--
-- AXES (simulation space = RocketSim space): +X forward/field width, +Y field length
-- (blue goal at -Y), +Z up. The renderer maps (x, y, z) -> Roblox (x, z, y).

local C = {}

C.UU_TO_BT = 1 / 50
C.BT_TO_UU = 50
C.STUDS_PER_UU = 0.05

C.TICK_RATE = 120
C.TICK_TIME = 1 / 120

-- ===== World =====
C.GRAVITY_Z = -650.0
C.ARENA_EXTENT_X = 4096
C.ARENA_EXTENT_Y = 5120 -- Does not include inner-goal
C.ARENA_HEIGHT = 2044 -- RLBot ceiling value (RocketSim adds a backup plane at 2048)
C.ARENA_CORNER_SUM = 8064 -- corner planes: |x| + |y| = 8064 (RLBot)
C.ARENA_RAMP_RADIUS = 256 -- radius of the curved floor/ceiling/corner transitions (approximation, see ArenaCollision)
C.GOAL_HALF_WIDTH = 892.755
C.GOAL_HEIGHT = 642.775
C.GOAL_DEPTH = 880

C.ARENA_COLLISION_BASE_FRICTION = 0.6
C.ARENA_COLLISION_BASE_RESTITUTION = 0.3

C.CAR_MASS_BT = 180.0
C.BALL_MASS_BT = 180.0 / 6.0

C.CAR_COLLISION_FRICTION = 0.3
C.CAR_COLLISION_RESTITUTION = 0.1
C.CARBALL_COLLISION_FRICTION = 2.0
C.CARBALL_COLLISION_RESTITUTION = 0.0
C.CARWORLD_COLLISION_FRICTION = 0.3
C.CARWORLD_COLLISION_RESTITUTION = 0.3
C.CARCAR_COLLISION_FRICTION = 0.09
C.CARCAR_COLLISION_RESTITUTION = 0.1

C.BALL_REST_Z = 93.15 -- Greater than ball radius because of arena mesh collision margin
C.BALL_MAX_ANG_SPEED = 6.0 -- rad/s
C.BALL_DRAG = 0.03 -- Bullet linear damping: v *= (1 - drag)^dt
C.BALL_FRICTION = 0.35
C.BALL_RESTITUTION = 0.6
C.BALL_COLLISION_RADIUS_SOCCAR = 91.25
-- Bullet keeps a contact alive until the surfaces separate by the breaking threshold (0.02 * the ball's bounding
-- radius = 1.825 UU) and RocketSim never pushes separated contacts apart, so the ball settles between 91.25 and
-- ~93.1 UU. This reproduces RocketSim bit for bit in the comparison scenarios.
C.BALL_WORLD_CONTACT_RADIUS = C.BALL_COLLISION_RADIUS_SOCCAR

C.CAR_MAX_SPEED = 2300.0
C.BALL_MAX_SPEED = 6000.0

C.BOOST_MAX = 100.0
C.BOOST_USED_PER_SECOND = 100.0 / 3
C.BOOST_MIN_TIME = 0.1
C.BOOST_ACCEL_GROUND = 2975 / 3
C.BOOST_ACCEL_AIR = 3175 / 3
C.BOOST_SPAWN_AMOUNT = 100.0 / 3
C.RECHARGE_BOOST_PER_SECOND = 10
C.RECHARGE_BOOST_DELAY = 0.25

C.CAR_MAX_ANG_SPEED = 5.5

C.SUPERSONIC_START_SPEED = 2200.0
C.SUPERSONIC_MAINTAIN_MIN_SPEED = 2100.0
C.SUPERSONIC_MAINTAIN_MAX_TIME = 1.0

C.POWERSLIDE_RISE_RATE = 5
C.POWERSLIDE_FALL_RATE = 2

C.THROTTLE_TORQUE_AMOUNT = C.CAR_MASS_BT * 400.0
C.BRAKE_TORQUE_AMOUNT = C.CAR_MASS_BT * (14.25 + 1 / 3)
C.STOPPING_FORWARD_VEL = 25.0
C.COASTING_BRAKE_FACTOR = 0.15
C.BRAKING_NO_THROTTLE_SPEED_THRESH = 0.01
C.THROTTLE_DEADZONE = 0.001
C.THROTTLE_AIR_ACCEL = 200 / 3

C.JUMP_ACCEL = 4375 / 3
C.JUMP_IMMEDIATE_FORCE = 875 / 3
C.JUMP_MIN_TIME = 0.025
C.JUMP_RESET_TIME_PAD = 1 / 40
C.JUMP_MAX_TIME = 0.2
C.JUMP_PRE_MIN_ACCEL_SCALE = 0.62
C.DOUBLEJUMP_MAX_DELAY = 1.25

C.FLIP_Z_DAMP_120 = 0.35
C.FLIP_Z_DAMP_START = 0.15
C.FLIP_Z_DAMP_END = 0.21
C.FLIP_TORQUE_TIME = 0.65
C.FLIP_TORQUE_MIN_TIME = 0.41
C.FLIP_PITCHLOCK_TIME = 1.0
C.FLIP_PITCHLOCK_EXTRA_TIME = 0.3
C.FLIP_INITIAL_VEL_SCALE = 500.0
C.FLIP_TORQUE_X = 260.0 -- Left/Right (roll)
C.FLIP_TORQUE_Y = 224.0 -- Forward/backward (pitch)
C.FLIP_FORWARD_IMPULSE_MAX_SPEED_SCALE = 1.0
C.FLIP_SIDE_IMPULSE_MAX_SPEED_SCALE = 1.9
C.FLIP_BACKWARD_IMPULSE_MAX_SPEED_SCALE = 2.5
C.FLIP_BACKWARD_IMPULSE_SCALE_X = 16 / 15
C.DODGE_DEADZONE = 0.5

C.SOCCAR_GOAL_SCORE_BASE_THRESHOLD_Y = 5124.25

C.CAR_TORQUE_SCALE = 2 * math.pi / 65536 * 1000

C.CAR_AUTOFLIP_IMPULSE = 200
C.CAR_AUTOFLIP_TORQUE = 50
C.CAR_AUTOFLIP_TIME = 0.4
C.CAR_AUTOFLIP_NORMZ_THRESH = math.sqrt(0.5)
C.CAR_AUTOFLIP_ROLL_THRESH = 2.8

C.CAR_AUTOROLL_FORCE = 100
C.CAR_AUTOROLL_TORQUE = 80

C.BALL_CAR_EXTRA_IMPULSE_Z_SCALE = 0.35
C.BALL_CAR_EXTRA_IMPULSE_FORWARD_SCALE = 0.65
C.BALL_CAR_EXTRA_IMPULSE_MAXDELTAVEL_UU = 4600.0

C.CAR_SPAWN_REST_Z = 17.0
C.CAR_RESPAWN_Z = 36.0

C.BUMP_COOLDOWN_TIME = 0.25
C.BUMP_MIN_FORWARD_DIST = 64.5
C.DEMO_RESPAWN_TIME = 3.0

-- Angle order is (pitch, yaw, roll)
C.CAR_AIR_CONTROL_TORQUE = Vector3.new(130, 95, 400)
C.CAR_AIR_CONTROL_DAMPING = Vector3.new(30, 20, 50)

-- btVehicleRL settings
C.SUSPENSION_FORCE_SCALE_FRONT = 36 - 1 / 4
C.SUSPENSION_FORCE_SCALE_BACK = 54 + 1 / 4 + 1.5 / 100
C.SUSPENSION_STIFFNESS = 500
C.WHEELS_DAMPING_COMPRESSION = 25
C.WHEELS_DAMPING_RELAXATION = 40
C.MAX_SUSPENSION_TRAVEL = 12 -- UU
C.SUSPENSION_SUBTRACTION = 0.05 -- BT
C.ROLLING_FRICTION_SCALE_MAGIC = 113.73963
C.BILATERAL_CONTACT_DAMPING = 0.2

-- ===== Boost pads =====
C.BOOSTPAD_CYL_HEIGHT = 95
C.BOOSTPAD_CYL_RAD_BIG = 208
C.BOOSTPAD_CYL_RAD_SMALL = 144
C.BOOSTPAD_BOX_HEIGHT = 64
C.BOOSTPAD_BOX_RAD_BIG = 160
C.BOOSTPAD_BOX_RAD_SMALL = 120
C.BOOSTPAD_COOLDOWN_BIG = 10
C.BOOSTPAD_COOLDOWN_SMALL = 4
C.BOOSTPAD_AMOUNT_BIG = 100
C.BOOSTPAD_AMOUNT_SMALL = 12

C.BOOSTPAD_LOCS_SMALL = {
	Vector3.new(0, -4240, 70), Vector3.new(-1792, -4184, 70), Vector3.new(1792, -4184, 70),
	Vector3.new(-940, -3308, 70), Vector3.new(940, -3308, 70), Vector3.new(0, -2816, 70),
	Vector3.new(-3584, -2484, 70), Vector3.new(3584, -2484, 70), Vector3.new(-1788, -2300, 70),
	Vector3.new(1788, -2300, 70), Vector3.new(-2048, -1036, 70), Vector3.new(0, -1024, 70),
	Vector3.new(2048, -1036, 70), Vector3.new(-1024, 0, 70), Vector3.new(1024, 0, 70),
	Vector3.new(-2048, 1036, 70), Vector3.new(0, 1024, 70), Vector3.new(2048, 1036, 70),
	Vector3.new(-1788, 2300, 70), Vector3.new(1788, 2300, 70), Vector3.new(-3584, 2484, 70),
	Vector3.new(3584, 2484, 70), Vector3.new(0, 2816, 70), Vector3.new(-940, 3310, 70),
	Vector3.new(940, 3308, 70), Vector3.new(-1792, 4184, 70), Vector3.new(1792, 4184, 70),
	Vector3.new(0, 4240, 70),
}
C.BOOSTPAD_LOCS_BIG = {
	Vector3.new(-3584, 0, 73), Vector3.new(3584, 0, 73), Vector3.new(-3072, 4096, 73),
	Vector3.new(3072, 4096, 73), Vector3.new(-3072, -4096, 73), Vector3.new(3072, -4096, 73),
}

-- Kickoff spawns for blue (flip x, y and add pi to yaw for orange)
C.CAR_SPAWN_LOCATIONS = {
	{ x = -2048, y = -2560, yaw = math.pi / 4 * 1 },
	{ x = 2048, y = -2560, yaw = math.pi / 4 * 3 },
	{ x = -256, y = -3840, yaw = math.pi / 4 * 2 },
	{ x = 256, y = -3840, yaw = math.pi / 4 * 2 },
	{ x = 0, y = -4608, yaw = math.pi / 4 * 2 },
}
C.CAR_RESPAWN_LOCATIONS = {
	{ x = -2304, y = -4608, yaw = math.pi / 2 },
	{ x = -2688, y = -4608, yaw = math.pi / 2 },
	{ x = 2304, y = -4608, yaw = math.pi / 2 },
	{ x = 2688, y = -4608, yaw = math.pi / 2 },
}

-- ===== Bullet solver settings used by RocketSim =====
C.SOLVER_ITERATIONS = 10
C.SOLVER_WARMSTARTING_FACTOR = 0.85 -- persistent contacts start from 0.85x last tick's impulse
C.SOLVER_ERP = 0.2 -- m_erp (used by resolveSingleCollision)
C.SOLVER_ERP2 = 0.8 -- m_erp2, RocketSim override (split-impulse penetration recovery)
C.SOLVER_SPLIT_IMPULSE_TURN_ERP = 0.1
C.SOLVER_RESTITUTION_VEL_THRESHOLD = 0.2 -- BT/s
C.CONTACT_BREAKING_THRESHOLD_UU = 1.825 -- gContactBreakingThreshold (0.02) * ball bounding radius, in UU
C.CONTACT_BREAKING_THRESHOLD_BT = 0.02 -- per unit of a shape's angular motion disc (BT)
C.BALL_WORLD_CONTACT_THRESHOLD_UU = C.CONTACT_BREAKING_THRESHOLD_UU
C.ANGULAR_MOTION_THRESHOLD = 0.5 * math.pi / 2

return C
