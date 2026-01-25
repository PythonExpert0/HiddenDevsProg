local Config = {}

-- SOUND EMISSION CONFIGURATION
Config.SOUND_EVENTS = {
	WALK = { 
		baseRadius = 15,     -- Increased for better detection
		velocityMultiplier = 0.5,
		duration = 0.6
	},
	RUN = { 
		baseRadius = 30,     -- Increased
		velocityMultiplier = 1.2,
		duration = 0.9
	},
	SPRINT = { 
		baseRadius = 50,     -- Increased
		velocityMultiplier = 1.8,
		duration = 1.2
	},
	JUMP = { 
		baseRadius = 25,     -- Increased
		velocityMultiplier = 0.8,
		duration = 0.7
	},
	LAND = { 
		baseRadius = 28,     -- Increased
		velocityMultiplier = 1.0,
		duration = 0.5
	},
}

-- SOUND BLOCKING CONFIGURATION
Config.OCCLUSION = {
	-- Enable/disable sound blocking through walls
	ENABLED = true,

	-- Cache settings
	CACHE_DURATION = 0.5,        -- How long to cache occlusion results

	-- Thickness estimation
	MIN_THICKNESS = 1,           -- Minimum assumed wall thickness
	MAX_THICKNESS = 20,          -- Maximum wall thickness
	THICKNESS_FACTOR = 0.15,     -- How much thickness affects sound blocking

	-- Sound passthrough limits
	MIN_PASSTHROUGH = 0.05,     

	-- Material-based sound absorption
	-- Higher values mean MORE sound is blocked
	MATERIAL_ABSORPTION = {
		-- Very absorbent
		[Enum.Material.Concrete] = 0.85,
		[Enum.Material.Brick] = 0.80,
		[Enum.Material.Granite] = 0.82,
		[Enum.Material.Marble] = 0.75,
		[Enum.Material.Slate] = 0.78,
		[Enum.Material.Metal] = 0.70,
		[Enum.Material.DiamondPlate] = 0.72,
		[Enum.Material.CorrodedMetal] = 0.68,

		-- Moderate absorption
		[Enum.Material.Wood] = 0.60,
		[Enum.Material.WoodPlanks] = 0.62,
		[Enum.Material.Plastic] = 0.55,
		[Enum.Material.SmoothPlastic] = 0.50,

		-- Low absorption
		[Enum.Material.Glass] = 0.40,
		[Enum.Material.Ice] = 0.35,
		[Enum.Material.Sand] = 0.45,
		[Enum.Material.Grass] = 0.30,
		[Enum.Material.Ground] = 0.40,
		[Enum.Material.Fabric] = 0.35,
		[Enum.Material.Foil] = 0.25,

		-- Very low absorption
		[Enum.Material.Neon] = 0.20,
		[Enum.Material.ForceField] = 0.10,

		-- Default for unknown materials
		Default = 0.65,
	}
}


-- PLAYER MOVEMENT
Config.MOVEMENT = {
	WALK_SPEED = 16,
	RUN_SPEED = 20,
	SPRINT_SPEED = 24,
	JUMP_POWER = 50,
}

-- NPC BEHAVIOR CONFIGURATION
Config.NPC = {
	-- Detection ranges
	HEARING_RANGE = 100,             -- Increased detection range

	-- Movement speeds
	ROTATION_SPEED = 5,              -- Faster turning
	INVESTIGATION_SPEED = 18,
	PATROL_SPEED = 10,
	ALERT_SPEED = 28,                -- Faster chase speed

	-- Memory & attention
	SOUND_MEMORY_DURATION = 5.0,     -- Remember sounds longer
	INVESTIGATION_TIMEOUT = 10.0,    -- Search longer before giving up
	ALERT_DURATION = 8.0,            -- Stay alert longer
	CHASE_TIMEOUT = 15.0,            -- How long to chase before giving up
	CHASE_LOST_TIMEOUT = 5.0,        -- Time before giving up when losing sight

	-- Line of sight
	LOS_CHECK_DISTANCE = 150,        -- See farther
	LOS_CHECK_INTERVAL = 0.15,       -- Check more frequently
	LOS_HEIGHT_OFFSET = 2,
	LOS_FOV = 120,                   -- FOV in degrees

	-- Chase behavior
	CHASE_UPDATE_INTERVAL = 0.1,     -- Update chase path frequently
	MIN_CHASE_DISTANCE = 3,          -- Stop chasing when this close
	LOSE_SIGHT_GRACE = 2.0,          -- Seconds of grace when losing LOS
}

-- PERFORMANCE OPTIMIZATION
Config.PERFORMANCE = {
	UPDATE_INTERVAL = 0.05,          -- Faster updates for responsive AI
	MAX_NPCS_PER_UPDATE = 10,        -- More NPCs per frame
	SOUND_CLEANUP_INTERVAL = 0.5,
	SPATIAL_GRID_SIZE = 50,
	MAX_SOUNDS_PER_PLAYER = 3,
}

-- DEBUG SETTINGS
Config.DEBUG = {
	ENABLED = true,                  -- Enable debugging
	SHOW_SOUND_RADIUS = false,       -- See sound spheres
	SHOW_NPC_HEARING_RANGE = false,
	SHOW_INVESTIGATION_PATHS = true,
	PRINT_EVENTS = false,            -- Print state changes
	PRINT_OCCLUSION = true,          -- Print when sounds are blocked by obstacles
}

return Config
