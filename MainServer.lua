-- SERVICES
local RunService = game:GetService("RunService")      
local Players = game:GetService("Players")             
local PathfindingService = game:GetService("PathfindingService") 

-- CONFIGURATION
local Config = {}  

-- Sound types and their properties baseRadius is the minimum range at zero velocity,
-- velocityMultiplier scales how much faster movement extends that range and duration
-- controls how long the sound event stays alive for NPCs to detect.
Config.SOUND_EVENTS = {
	WALK = {
		baseRadius = 15,
		velocityMultiplier = 0.5,  -- kept low so walking stays nearly silent even at full speed
		duration = 0.6
	},
	RUN = {
		baseRadius = 30,
		velocityMultiplier = 1.2,
		duration = 0.9
	},
	SPRINT = {
		baseRadius = 50,
		velocityMultiplier = 1.8,  -- high enough that a fast sprint can add 30+ studs of extra range
		duration = 1.2
	},
	JUMP = {
		baseRadius = 25,
		velocityMultiplier = 0.8,  -- slight scaling so a running jump is louder than a standing one
		duration = 0.7
	},
	LAND = {
		baseRadius = 28,
		velocityMultiplier = 1.0,  -- 1:1 so impact force maps directly to sound radius
		duration = 0.5             -- short because a landing is a single thud, not a continuous noise
	},
}

-- Wall occlusion settings. When a sound raycast hits geometry between the emitter and the NPC,
-- we estimate wall thickness and look up the material's absorption value to reduce intensity.
Config.OCCLUSION = {
	ENABLED = true,
	CACHE_DURATION = 0.5,          -- occlusion results are cached per grid cell so we don't raycast every frame
	MIN_THICKNESS = 1,             -- fallback if the back-face raycast misses
	MAX_THICKNESS = 20,            -- cap so absurdly thick geometry doesn't completely silence everything
	THICKNESS_FACTOR = 0.15,       -- controls how steeply thickness increases muffling, lower = more lenient
	MIN_PASSTHROUGH = 0.05,        -- 5% always bleeds through so sound never goes completely dead

	-- How much each material absorbs sound. Higher = more muffled through that material.
	MATERIAL_ABSORPTION = {
		[Enum.Material.Concrete] = 0.85,
		[Enum.Material.Brick] = 0.80,
		[Enum.Material.Granite] = 0.82,
		[Enum.Material.Marble] = 0.75,
		[Enum.Material.Slate] = 0.78,
		[Enum.Material.Metal] = 0.70,
		[Enum.Material.CorrodedMetal] = 0.68,
		[Enum.Material.Wood] = 0.60,
		[Enum.Material.WoodPlanks] = 0.62,
		[Enum.Material.Plastic] = 0.55,
		[Enum.Material.SmoothPlastic] = 0.50,
		[Enum.Material.Glass] = 0.40,
		[Enum.Material.Ice] = 0.35,
		[Enum.Material.Sand] = 0.45,
		[Enum.Material.Grass] = 0.30,
		[Enum.Material.Ground] = 0.40,
		[Enum.Material.Fabric] = 0.35,
		[Enum.Material.Foil] = 0.25,
		[Enum.Material.Neon] = 0.20,
		[Enum.Material.ForceField] = 0.10,
		Default = 0.65,
	}
}

-- Speed thresholds used to classify player movement into WALK/RUN/SPRINT sound types.
Config.MOVEMENT = {
	WALK_SPEED = 16,
	RUN_SPEED = 20,
	SPRINT_SPEED = 24,
	JUMP_POWER = 50,
}

Config.NPC = {
	HEARING_RANGE = 100,             -- sounds beyond this stud radius are never evaluated against this NPC
	ROTATION_SPEED = 5,
	INVESTIGATION_SPEED = 18,
	PATROL_SPEED = 10,
	ALERT_SPEED = 28,                -- faster than a sprinting player so the NPC can actually close distance
	SOUND_MEMORY_DURATION = 5.0,     -- how long a heard sound stays in memory before being evicted
	INVESTIGATION_TIMEOUT = 10.0,    -- gives up navigating to the sound source after this many seconds
	ALERT_DURATION = 8.0,            -- how long the NPC scans the area before returning to idle
	CHASE_TIMEOUT = 15.0,            -- absolute cap so no NPC chases a hiding player indefinitely
	CHASE_LOST_TIMEOUT = 5.0,        -- seconds without a LOS hit before switching from chase to investigate
	LOS_CHECK_DISTANCE = 150,        -- only raycast against players within this range to save CPU
	LOS_CHECK_INTERVAL = 0.15,       -- throttled to ~7 checks per second, casting every frame would be expensive
	LOS_HEIGHT_OFFSET = 2,           -- raises the ray origin to approximate eye level
	LOS_FOV = 120,                   -- full cone angle, so the half-angle used in the dot product check is 60deg
	CHASE_UPDATE_INTERVAL = 0.1,
	MIN_CHASE_DISTANCE = 3,          -- NPC halts when this close so it doesn't clip into the player
	LOSE_SIGHT_GRACE = 2.0,
}

Config.PERFORMANCE = {
	UPDATE_INTERVAL = 0.05,          -- AI runs at 20hz instead of 60fps to keep CPU overhead low
	MAX_NPCS_PER_UPDATE = 10,        -- round-robin so we update at most N NPCs per tick instead of all at once
	SOUND_CLEANUP_INTERVAL = 0.5,
	SPATIAL_GRID_SIZE = 50,          -- world is divided into 50-stud cells for fast proximity lookups
	MAX_SOUNDS_PER_PLAYER = 3,       -- burst cap within a 100ms window to prevent sound spam
}

Config.DEBUG = {
	ENABLED = true,
	SHOW_SOUND_RADIUS = false,        -- spawns a sphere at each sound origin sized to its detection radius
	SHOW_NPC_HEARING_RANGE = false,
	SHOW_INVESTIGATION_PATHS = true,  -- renders waypoint dots and lines for computed paths
	PRINT_EVENTS = false,
	PRINT_OCCLUSION = true,           -- logs material name, thickness, and % blocked each time a wall is hit
}


-- SOUND EVENT CLASS
-- Represents a single sound emission in the world. Stores position, radius, lifetime,
-- and handles intensity falloff + wall occlusion calculations.
local SoundEvent = {}
SoundEvent.__index = SoundEvent

function SoundEvent.new(position: Vector3, soundType: string, velocity: number, emitter: Instance?)
	local config = Config.SOUND_EVENTS[soundType]
	if not config then
		warn("Invalid sound type:", soundType)
		return nil
	end

	local self = setmetatable({}, SoundEvent)

	self.position = position
	self.soundType = soundType
	self.emitter = emitter
	-- Faster movement produces a louder sound with a bigger radius
	self.radius = config.baseRadius + (velocity * config.velocityMultiplier)
	self.createdAt = os.clock()
	self.lifetime = config.duration
	self.expiresAt = self.createdAt + self.lifetime
	-- Precompute squared radius so distance checks can skip the sqrt call
	self._radiusSquared = self.radius * self.radius
	self._isExpired = false
	self._occlusionCache = {}
	self._lastCacheCleanup = os.clock()

	return self
end

function SoundEvent:isExpired(currentTime: number?): boolean
	if self._isExpired then return true end
	local time = currentTime or os.clock()
	-- Write result back to the flag so subsequent calls short-circuit immediately
	self._isExpired = time >= self.expiresAt
	return self._isExpired
end

function SoundEvent:getIntensity(listenerPos: Vector3, raycastParams: RaycastParams?): number
	if self._isExpired then return 0 end

	local offset = listenerPos - self.position
	-- Dot of a vector with itself equals its squared magnitude, avoiding a sqrt
	local distanceSquared = offset:Dot(offset)

	if distanceSquared > self._radiusSquared then return 0 end

	local distance = math.sqrt(distanceSquared)
	local normalizedDist = distance / self.radius
	local falloff = 1 - normalizedDist
	-- Squaring the falloff steepens the curve so distant sounds feel much quieter
	local baseIntensity = falloff * falloff

	if raycastParams then
		local occlusionMultiplier = self:_calculateOcclusion(listenerPos, raycastParams)
		return baseIntensity * occlusionMultiplier
	end

	return baseIntensity
end

-- Fires a raycast from the sound source toward the listener and reduces intensity
-- based on what material is in the way and how thick it is.
function SoundEvent:_calculateOcclusion(listenerPos: Vector3, raycastParams: RaycastParams): number
	local cacheKey = self:_getCacheKey(listenerPos)
	local cached = self._occlusionCache[cacheKey]

	-- Reuse cached result if it's still fresh enough
	if cached and os.clock() - cached.timestamp < Config.OCCLUSION.CACHE_DURATION then
		return cached.multiplier
	end

	local direction = listenerPos - self.position
	local distance = direction.Magnitude

	if distance < 0.1 then return 1.0 end

	local result = workspace:Raycast(self.position, direction, raycastParams)
	local occlusionMultiplier = 1.0

	if result then
		local hitDistance = (result.Position - self.position).Magnitude

		-- 1 stud tolerance prevents the listener's own body from registering as a wall
		if hitDistance < distance - 1 then
			local material = result.Material
			local thickness = self:_estimateThickness(result, direction, raycastParams)
			occlusionMultiplier = self:_getMaterialOcclusion(material, thickness)

			if Config.DEBUG.PRINT_OCCLUSION then
				print(string.format(
					"[Occlusion] %s blocks sound: %.0f%% (material: %s, thickness: %.1f)",
					result.Instance.Name,
					(1 - occlusionMultiplier) * 100,
					tostring(material),
					thickness
					))
			end
		end
	end

	self._occlusionCache[cacheKey] = { multiplier = occlusionMultiplier, timestamp = os.clock() }

	-- Run cache eviction roughly every second so the table doesn't grow unbounded
	if os.clock() - self._lastCacheCleanup > 1.0 then
		self:_cleanupCache()
	end

	return occlusionMultiplier
end

-- Estimates wall thickness by firing a second ray from inside the hit part back toward
-- the sound source. If it hits the same instance, the distance between both hit points
-- is the thickness.
function SoundEvent:_estimateThickness(firstHit: RaycastResult, direction: Vector3, raycastParams: RaycastParams): number
	-- Nudge 0.5 studs inside so the reverse ray doesn't immediately re-hit the front face
	local reverseStart = firstHit.Position + (direction.Unit * 0.5)
	local reverseDirection = -direction.Unit * 20

	local reverseResult = workspace:Raycast(reverseStart, reverseDirection, raycastParams)

	if reverseResult and reverseResult.Instance == firstHit.Instance then
		local thickness = (firstHit.Position - reverseResult.Position).Magnitude
		return math.clamp(thickness, 0, Config.OCCLUSION.MAX_THICKNESS)
	end

	-- Back face wasn't found, assume minimum thickness
	return Config.OCCLUSION.MIN_THICKNESS
end

-- Combines material absorption and wall thickness into a single 0-1 multiplier.
-- Uses exponential decay so doubling the thickness more than doubles the muffling.
function SoundEvent:_getMaterialOcclusion(material: Enum.Material, thickness: number): number
	local absorption = Config.OCCLUSION.MATERIAL_ABSORPTION[material]
		or Config.OCCLUSION.MATERIAL_ABSORPTION.Default

	local thicknessMultiplier = math.exp(-thickness * absorption * Config.OCCLUSION.THICKNESS_FACTOR)
	return math.max(thicknessMultiplier, Config.OCCLUSION.MIN_PASSTHROUGH)
end

-- Snaps a world position to a 5-stud grid so nearby NPCs share cached occlusion results
-- rather than each running their own raycast.
function SoundEvent:_getCacheKey(position: Vector3): string
	local gridSize = 5
	local x = math.floor(position.X / gridSize) * gridSize
	local y = math.floor(position.Y / gridSize) * gridSize
	local z = math.floor(position.Z / gridSize) * gridSize
	return string.format("%d,%d,%d", x, y, z)
end

function SoundEvent:_cleanupCache()
	local currentTime = os.clock()
	local newCache = {}

	-- Build a replacement table instead of deleting in-place so iteration stays safe
	for key, data in pairs(self._occlusionCache) do
		if currentTime - data.timestamp < Config.OCCLUSION.CACHE_DURATION then
			newCache[key] = data
		end
	end

	self._occlusionCache = newCache
	self._lastCacheCleanup = currentTime
end

function SoundEvent:getRemainingLife(): number
	return math.max(0, self.expiresAt - os.clock())
end

function SoundEvent:getAge(): number
	return os.clock() - self.createdAt
end

function SoundEvent:isInRange(position: Vector3): boolean
	if self._isExpired then return false end
	local offset = position - self.position
	return offset:Dot(offset) <= self._radiusSquared
end

function SoundEvent:destroy()
	self._isExpired = true
	self.emitter = nil
	self.position = nil
	table.clear(self._occlusionCache)
end


-- SOUND MANAGER CLASS
-- Owns all active SoundEvent objects. Handles emission, rate limiting, spatial
-- grid lookups, and periodic cleanup of expired sounds.
local SoundManager = {}
SoundManager.__index = SoundManager

function SoundManager.new()
	local self = setmetatable({}, SoundManager)

	self._sounds = {}
	self._soundCount = 0
	self._playerSoundCounts = {}     -- per-player emission count within the current 100ms window
	self._playerLastSound = {}       -- timestamp of each player's last emission, used to detect window resets
	self._lastCleanup = os.clock()
	self._spatialGrid = {}           -- divides the world into cells so range queries only check nearby sounds
	self._gridSize = Config.PERFORMANCE.SPATIAL_GRID_SIZE

	return self
end

function SoundManager:emitSound(position: Vector3, soundType: string, velocity: number, emitter: Instance?)
	local soundConfig = Config.SOUND_EVENTS[soundType]
	if not soundConfig or soundConfig.baseRadius == 0 then return nil end

	-- Rate limiting only applies to players, not scripted or world emitters
	if emitter and emitter:IsA("Player") then
		local now = os.clock()
		local lastTime = self._playerLastSound[emitter] or 0

		if now - lastTime < 0.1 then
			-- Still inside the burst window, check against the cap
			local count = self._playerSoundCounts[emitter] or 0
			if count >= Config.PERFORMANCE.MAX_SOUNDS_PER_PLAYER then
				return nil
			end
		else
			-- Window expired, start a fresh count
			self._playerSoundCounts[emitter] = 0
		end

		self._playerLastSound[emitter] = now
		self._playerSoundCounts[emitter] = (self._playerSoundCounts[emitter] or 0) + 1
	end

	local sound = SoundEvent.new(position, soundType, velocity, emitter)
	if not sound then return nil end

	table.insert(self._sounds, sound)
	self._soundCount = self._soundCount + 1
	self:_addToGrid(sound)

	if Config.DEBUG.ENABLED and Config.DEBUG.SHOW_SOUND_RADIUS then
		self:_visualizeSound(sound)
	end

	if Config.DEBUG.PRINT_EVENTS then
		print(string.format("Sound %s at %s, radius: %.1f", soundType, tostring(position), sound.radius))
	end

	return sound
end

-- Returns the loudest non-expired sound within maxRange of listenerPos.
-- Intensity is based on distance falloff only (no occlusion) for performance.
function SoundManager:getClosestSound(listenerPos: Vector3, maxRange: number)
	local currentTime = os.clock()
	local bestSound = nil
	local maxIntensity = 0

	for _, sound in ipairs(self:_getNearbySounds(listenerPos, maxRange)) do
		if not sound:isExpired(currentTime) then
			local intensity = sound:getIntensity(listenerPos)
			if intensity > maxIntensity then
				maxIntensity = intensity
				bestSound = sound
			end
		end
	end

	return bestSound, maxIntensity
end

function SoundManager:getSoundsInRange(position: Vector3, range: number)
	local currentTime = os.clock()
	local soundsInRange = {}

	for _, sound in ipairs(self:_getNearbySounds(position, range)) do
		if not sound:isExpired(currentTime) and sound:isInRange(position) then
			table.insert(soundsInRange, sound)
		end
	end

	return soundsInRange
end

function SoundManager:update()
	local currentTime = os.clock()
	if currentTime - self._lastCleanup >= Config.PERFORMANCE.SOUND_CLEANUP_INTERVAL then
		self:_cleanup(currentTime)
		self._lastCleanup = currentTime
	end
end

function SoundManager:_cleanup(currentTime: number)
	-- Iterate backward so removing an index doesn't skip the next element
	for i = #self._sounds, 1, -1 do
		local sound = self._sounds[i]
		if sound:isExpired(currentTime) then
			self:_removeFromGrid(sound)
			sound:destroy()
			table.remove(self._sounds, i)
			self._soundCount = self._soundCount - 1
		end
	end

	-- Reset burst counters roughly every 2 seconds
	if currentTime % 2 < 0.1 then
		table.clear(self._playerSoundCounts)
	end
end

function SoundManager:_getGridKey(position: Vector3): string
	local gx = math.floor(position.X / self._gridSize)
	local gz = math.floor(position.Z / self._gridSize)
	-- Y axis intentionally ignored so sounds at different heights share a cell
	return string.format("%d,%d", gx, gz)
end

function SoundManager:_addToGrid(sound: any)
	local key = self:_getGridKey(sound.position)
	if not self._spatialGrid[key] then
		self._spatialGrid[key] = {}
	end
	table.insert(self._spatialGrid[key], sound)
end

function SoundManager:_removeFromGrid(sound: any)
	local key = self:_getGridKey(sound.position)
	local cell = self._spatialGrid[key]
	if not cell then return end

	for i = #cell, 1, -1 do
		if cell[i] == sound then
			table.remove(cell, i)
			break
		end
	end
end

-- Collects all sounds from the grid cells that overlap the search radius.
-- Checks a square neighborhood which slightly overestimates at corners but avoids missed hits.
function SoundManager:_getNearbySounds(position: Vector3, range: number)
	local cellsToCheck = math.ceil(range / self._gridSize)
	local gx = math.floor(position.X / self._gridSize)
	local gz = math.floor(position.Z / self._gridSize)
	local nearbySounds = {}

	for dx = -cellsToCheck, cellsToCheck do
		for dz = -cellsToCheck, cellsToCheck do
			local key = string.format("%d,%d", gx + dx, gz + dz)
			local cell = self._spatialGrid[key]
			if cell then
				for _, sound in ipairs(cell) do
					table.insert(nearbySounds, sound)
				end
			end
		end
	end

	-- Fall back to the full list if the grid has no populated cells yet
	return #nearbySounds > 0 and nearbySounds or self._sounds
end

function SoundManager:_visualizeSound(sound: any)
	local part = Instance.new("Part")
	part.Anchored = true
	part.CanCollide = false
	part.Shape = Enum.PartType.Ball
	part.Size = Vector3.new(sound.radius * 2, sound.radius * 2, sound.radius * 2)
	part.Position = sound.position
	part.Transparency = 0.7
	part.Color = Color3.fromRGB(255, 100, 100)
	part.Material = Enum.Material.Neon
	part.Parent = workspace

	task.delay(sound.lifetime, function()
		part:Destroy()
	end)
end

function SoundManager:destroy()
	for _, sound in ipairs(self._sounds) do
		sound:destroy()
	end
	table.clear(self._sounds)
	table.clear(self._spatialGrid)
	table.clear(self._playerSoundCounts)
	table.clear(self._playerLastSound)
	self._soundCount = 0
end


-- NPC STATES
local NPCState = {
	IDLE          = "Idle",          -- standing still, no stimulus
	PATROL        = "Patrol",        -- walking a predetermined route
	INVESTIGATING = "Investigating", -- heard something, moving toward the source
	ALERT         = "Alert",         -- arrived at source, scanning for a target
	CHASING       = "Chasing"        -- has visual on a player, actively pursuing
}


-- NPC AI CONTROLLER CLASS
-- One instance per NPC. Drives state transitions based on sound perception and
-- line-of-sight checks, then uses PathfindingService to navigate.
local NPCAIController = {}
NPCAIController.__index = NPCAIController

function NPCAIController.new(npcModel: Model, soundManager: any)
	assert(npcModel:IsA("Model"), "NPC must be a Model")
	assert(npcModel.PrimaryPart, "NPC must have a PrimaryPart")

	local self = setmetatable({}, NPCAIController)

	self.model = npcModel
	self.humanoid = npcModel:FindFirstChildOfClass("Humanoid")
	self.rootPart = npcModel.PrimaryPart
	self.soundManager = soundManager

	self.state = NPCState.IDLE
	-- currentTarget is a Vector3 position while investigating, a character Model while chasing
	self.currentTarget = nil
	self.lastHeardSound = nil
	self.lastSeenTarget = nil  -- character model of the last player we had visual on

	self.soundMemory = {}           -- recent sound entries, used to track how suspicious this NPC is
	self.alertStartTime = 0
	self.investigationStartTime = 0
	self.chaseStartTime = 0
	self.lastSawTargetTime = 0

	self.pathfindingAgent = PathfindingService:CreatePath({
		AgentRadius = 2,
		AgentHeight = 5,
		AgentCanJump = true,
		AgentCanClimb = false,
		WaypointSpacing = 4,
		Costs = {
			Water = 20,
			Danger = math.huge,    -- zones tagged Danger are treated as completely impassable
		}
	})

	self.currentPath = nil
	self.currentWaypointIndex = 1
	self._pathfindingConnection = nil
	self._lastPathUpdate = 0
	-- Guard flag prevents a second ComputeAsync from firing while one is still running
	self._pathComputeInProgress = false

	self._lastPosition = npcModel.PrimaryPart.Position
	self._stuckTime = 0              -- accumulates seconds spent below the movement threshold
	self._stuckThreshold = 1.5       -- reroute after being stuck this long
	self._minMovementThreshold = 0.5 -- must move at least this many studs per check to not be considered stuck

	self.raycastParams = RaycastParams.new()
	self.raycastParams.FilterDescendantsInstances = {npcModel}
	self.raycastParams.FilterType = Enum.RaycastFilterType.Exclude

	self._lastLOSCheck = 0
	self._lastStateUpdate = 0
	self._lastChaseUpdate = 0
	self._lastMoveCommand = 0
	self._lastStuckCheck = 0

	self._connections = {}

	if not self.humanoid then
		warn("NPC missing Humanoid:", npcModel.Name)
		return nil
	end

	self.humanoid.AutoRotate = true

	if self.pathfindingAgent then
		table.insert(self._connections, self.pathfindingAgent.Blocked:Connect(function(waypointIndex)
			self:_onPathBlocked(waypointIndex)
		end))
	end

	table.insert(self._connections, self.humanoid.MoveToFinished:Connect(function(reached)
		self:_onMoveToFinished(reached)
	end))

	self:_createStateIndicator()

	return self
end

function NPCAIController:update(deltaTime: number)
	if not self.humanoid or self.humanoid.Health <= 0 then return end

	local currentTime = os.clock()

	-- Stuck detection runs at 2hz rather than every tick to keep it cheap
	if currentTime - self._lastStuckCheck > 0.5 then
		self:_checkIfStuck(currentTime)
		self._lastStuckCheck = currentTime
	end

	-- Decay memory before perception so checks run on a clean list
	self:_updateSoundMemory(currentTime)
	self:_checkForSounds()

	if currentTime - self._lastLOSCheck >= Config.NPC.LOS_CHECK_INTERVAL then
		self:_performLOSCheck()
		self._lastLOSCheck = currentTime
	end

	self:_updateStateIndicator()

	if self.state == NPCState.IDLE then
		self:_updateIdle(deltaTime)
	elseif self.state == NPCState.PATROL then
		self:_updatePatrol(deltaTime)
	elseif self.state == NPCState.INVESTIGATING then
		self:_updateInvestigating(deltaTime, currentTime)
	elseif self.state == NPCState.ALERT then
		self:_updateAlert(deltaTime, currentTime)
	elseif self.state == NPCState.CHASING then
		self:_updateChasing(deltaTime, currentTime)
	end
end

-- Checks whether the NPC has been failing to make progress toward its target.
-- If movement drops below the threshold for too long, we discard the current path
-- and request a fresh one from the current position.
function NPCAIController:_checkIfStuck(currentTime: number)
	if not self.rootPart then return end

	local currentPos = self.rootPart.Position
	local distanceMoved = (currentPos - self._lastPosition).Magnitude

	if self.state == NPCState.CHASING or self.state == NPCState.INVESTIGATING then
		if distanceMoved < self._minMovementThreshold then
			self._stuckTime = self._stuckTime + (currentTime - self._lastStuckCheck)

			if self._stuckTime > self._stuckThreshold then
				if Config.DEBUG.PRINT_EVENTS then
					print(string.format("NPC %s STUCK! Recomputing path...", self.model.Name))
				end

				if self.currentTarget then
					-- currentTarget type differs depending on state
					local targetPos = typeof(self.currentTarget) == "Vector3"
						and self.currentTarget
						or self.currentTarget:IsA("Model") and self.currentTarget.PrimaryPart and self.currentTarget.PrimaryPart.Position

					if targetPos then
						self.currentPath = nil
						self:_computePath(targetPos)
					end
				end

				self._stuckTime = 0
			end
		else
			self._stuckTime = 0
		end
	else
		-- Idle and Alert NPCs aren't expected to move, so never flag them as stuck
		self._stuckTime = 0
	end

	self._lastPosition = currentPos
end

-- Queries the sound manager for the loudest nearby sound and decides whether it's
-- worth reacting to. Intensity threshold of 0.15 filters out faint background noise.
function NPCAIController:_checkForSounds()
	local closestSound, intensity = self.soundManager:getClosestSound(
		self.rootPart.Position,
		Config.NPC.HEARING_RANGE
	)

	if not closestSound or intensity <= 0.15 then return end

	self:_addSoundMemory(closestSound, intensity)

	if self.state == NPCState.IDLE or self.state == NPCState.PATROL then
		self:_setState(NPCState.INVESTIGATING)
		self.currentTarget = closestSound.position
		self.investigationStartTime = os.clock()
	elseif self.state == NPCState.ALERT and intensity > 0.5 then
		-- Only loud sounds can redirect an already-alert NPC, otherwise it keeps scanning
		self:_setState(NPCState.INVESTIGATING)
		self.currentTarget = closestSound.position
		self.investigationStartTime = os.clock()
	end
end

function NPCAIController:_addSoundMemory(sound: any, intensity: number)
	table.insert(self.soundMemory, {
		position = sound.position,
		intensity = intensity,
		timestamp = os.clock(),
		soundType = sound.soundType
	})

	-- Cap at 10 entries, drop the oldest when exceeded
	if #self.soundMemory > 10 then
		table.remove(self.soundMemory, 1)
	end

	self.lastHeardSound = sound
end

function NPCAIController:_updateSoundMemory(currentTime: number)
	for i = #self.soundMemory, 1, -1 do
		local memory = self.soundMemory[i]
		if currentTime - memory.timestamp > Config.NPC.SOUND_MEMORY_DURATION then
			table.remove(self.soundMemory, i)
		end
	end
end

-- Casts a ray from each player's torso to check if they're in front of the NPC
-- and visible through geometry. We throttle this to LOS_CHECK_INTERVAL because
-- raycasting every frame for every player adds up fast.
function NPCAIController:_performLOSCheck()
	if not self.rootPart then return end

	local players = Players:GetPlayers()
	local origin = self.rootPart.Position + Vector3.new(0, Config.NPC.LOS_HEIGHT_OFFSET, 0)
	local npcLookDir = self.rootPart.CFrame.LookVector

	for _, player in ipairs(players) do
		local character = player.Character
		if not character or not character:FindFirstChild("HumanoidRootPart") then continue end

		local targetRoot = character.HumanoidRootPart
		local targetPos = targetRoot.Position + Vector3.new(0, 1.5, 0)
		local direction = targetPos - origin
		local distance = direction.Magnitude

		if distance > Config.NPC.LOS_CHECK_DISTANCE then continue end

		-- Dot product of two unit vectors gives the cosine of the angle between them.
		-- Clamping before acos prevents NaN if float drift pushes the value slightly past ±1.
		local dotProduct = npcLookDir:Dot(direction.Unit)
		local angle = math.deg(math.acos(math.clamp(dotProduct, -1, 1)))

		if angle > Config.NPC.LOS_FOV / 2 then continue end

		local result = workspace:Raycast(origin, direction, self.raycastParams)

		-- No hit means clear line of sight. Hitting the character itself also counts as visible.
		if not result or result.Instance:IsDescendantOf(character) then
			self.lastSeenTarget = character
			self.lastSawTargetTime = os.clock()

			if self.state ~= NPCState.CHASING then
				self:_setState(NPCState.CHASING)
				self.currentTarget = character
				self.chaseStartTime = os.clock()
			end
			return -- stop after spotting one player
		end
	end
end

function NPCAIController:_updateIdle(deltaTime: number)
	-- placeholder
end

function NPCAIController:_updatePatrol(deltaTime: number)
	-- TODO
end

function NPCAIController:_updateInvestigating(deltaTime: number, currentTime: number)
	if typeof(self.currentTarget) ~= "Vector3" then return end

	local targetPos = self.currentTarget
	self:_moveToTarget(targetPos, Config.NPC.INVESTIGATION_SPEED, currentTime)

	-- Switch to Alert when we've arrived at the sound source
	if (self.rootPart.Position - targetPos).Magnitude < 3 then
		self:_setState(NPCState.ALERT)
		self.alertStartTime = currentTime
	end

	if currentTime - self.investigationStartTime > Config.NPC.INVESTIGATION_TIMEOUT then
		self:_setState(NPCState.IDLE)
	end
end

function NPCAIController:_updateAlert(deltaTime: number, currentTime: number)
	if currentTime - self.alertStartTime > Config.NPC.ALERT_DURATION then
		self:_setState(NPCState.IDLE)
	end
	-- Note: the LOS check in update() can interrupt this state at any time by transitioning to Chasing
end

function NPCAIController:_updateChasing(deltaTime: number, currentTime: number)
	if self.lastSeenTarget and self.lastSeenTarget.Parent then
		local targetRoot = self.lastSeenTarget:FindFirstChild("HumanoidRootPart")
		if targetRoot then
			self.currentTarget = self.lastSeenTarget
			local targetPos = targetRoot.Position

			self:_moveToTarget(targetPos, Config.NPC.ALERT_SPEED, currentTime)

			-- Halt when close enough so we don't clip into the player
			if (self.rootPart.Position - targetPos).Magnitude < Config.NPC.MIN_CHASE_DISTANCE then
				self.humanoid:MoveTo(self.rootPart.Position)
			end
		end
	end

	-- If we haven't had a LOS hit in a while, fall back to investigating the last known position
	if currentTime - self.lastSawTargetTime > Config.NPC.CHASE_LOST_TIMEOUT then
		if self.lastSeenTarget and self.lastSeenTarget:FindFirstChild("HumanoidRootPart") then
			self:_setState(NPCState.INVESTIGATING)
			self.currentTarget = self.lastSeenTarget.HumanoidRootPart.Position
			self.investigationStartTime = currentTime
		else
			self:_setState(NPCState.IDLE)
		end
	end

	if currentTime - self.chaseStartTime > Config.NPC.CHASE_TIMEOUT then
		self:_setState(NPCState.IDLE)
	end
end

-- Sets WalkSpeed and either follows the computed path or falls back to a direct MoveTo.
-- Path is recomputed every 0.5s so it can track a moving target.
function NPCAIController:_moveToTarget(targetPos: Vector3, speed: number, currentTime: number)
	self.humanoid.WalkSpeed = speed

	if currentTime - self._lastPathUpdate >= 0.5 or not self.currentPath then
		self:_computePath(targetPos)
		self._lastPathUpdate = currentTime
	end

	if self.currentPath then
		self:_followPath()
	else
		self.humanoid:MoveTo(targetPos)
	end
end

function NPCAIController:_computePath(targetPos: Vector3)
	if self._pathComputeInProgress or not self.rootPart then return false end

	self._pathComputeInProgress = true

	local success = pcall(function()
		self.pathfindingAgent:ComputeAsync(self.rootPart.Position, targetPos)
	end)

	if success and self.pathfindingAgent.Status == Enum.PathStatus.Success then
		self.currentPath = self.pathfindingAgent:GetWaypoints()
		self.currentWaypointIndex = 1

		if Config.DEBUG.SHOW_INVESTIGATION_PATHS then self:_visualizePath() end
		if Config.DEBUG.PRINT_EVENTS then
			print(string.format("NPC %s computed path: %d waypoints", self.model.Name, #self.currentPath))
		end

		self._pathComputeInProgress = false
		return true
	end

	-- ClosestNoPath means pathfinding found a partial route. Still useful for getting closer.
	if self.pathfindingAgent.Status == Enum.PathStatus.ClosestNoPath then
		local waypoints = self.pathfindingAgent:GetWaypoints()
		if #waypoints > 0 then
			self.currentPath = waypoints
			self.currentWaypointIndex = 1
			self._pathComputeInProgress = false
			return true
		end
	end

	if Config.DEBUG.PRINT_EVENTS then
		warn(string.format("NPC %s pathfinding failed: %s", self.model.Name, tostring(self.pathfindingAgent.Status)))
	end

	self.currentPath = nil
	self._pathComputeInProgress = false
	return false
end

function NPCAIController:_followPath()
	if not self.currentPath or not self.rootPart or not self.humanoid then return end

	local waypoints = self.currentPath

	if self.currentWaypointIndex > #waypoints then
		self.currentPath = nil
		return
	end

	local targetWaypoint = waypoints[self.currentWaypointIndex]
	-- Flatten Y so height differences on stairs don't inflate distance and skip waypoints early
	local horizontalPos = Vector3.new(targetWaypoint.Position.X, self.rootPart.Position.Y, targetWaypoint.Position.Z)

	if (self.rootPart.Position - horizontalPos).Magnitude < 4 then
		self.currentWaypointIndex = self.currentWaypointIndex + 1

		if self.currentWaypointIndex > #waypoints then
			self.currentPath = nil
			return
		end

		targetWaypoint = waypoints[self.currentWaypointIndex]
	end

	if targetWaypoint.Action == Enum.PathWaypointAction.Jump then
		self.humanoid.Jump = true
		task.wait(0.1)
	end

	self.humanoid:MoveTo(targetWaypoint.Position)

	if Config.DEBUG.SHOW_INVESTIGATION_PATHS then
		if not self._currentWaypointMarker then
			-- Create the marker once and reuse it, rather than spawning a new part every frame
			local m = Instance.new("Part")
			m.Anchored = true
			m.CanCollide = false
			m.Size = Vector3.new(2, 2, 2)
			m.Color = Color3.fromRGB(255, 0, 255)
			m.Material = Enum.Material.Neon
			m.Transparency = 0.3
			m.Shape = Enum.PartType.Ball
			m.Parent = workspace
			self._currentWaypointMarker = m
		end
		self._currentWaypointMarker.Position = targetWaypoint.Position
	end
end

function NPCAIController:_onPathBlocked(waypointIndex: number)
	if Config.DEBUG.PRINT_EVENTS then
		print(string.format("NPC %s path blocked at waypoint %d, recomputing...", self.model.Name, waypointIndex))
	end
	self.currentPath = nil
end

function NPCAIController:_visualizePath()
	if self._pathVisuals then
		for _, part in ipairs(self._pathVisuals) do part:Destroy() end
	end
	self._pathVisuals = {}

	if not self.currentPath then return end

	for i, waypoint in ipairs(self.currentPath) do
		local part = Instance.new("Part")
		part.Anchored = true
		part.CanCollide = false
		part.Size = Vector3.new(1, 1, 1)
		part.Position = waypoint.Position
		part.Material = Enum.Material.Neon
		part.Transparency = 0.5
		part.Shape = Enum.PartType.Ball
		part.Parent = workspace

		if waypoint.Action == Enum.PathWaypointAction.Jump then
			part.Color = Color3.fromRGB(255, 255, 0) -- yellow = jump waypoint
			part.Size = Vector3.new(1.5, 1.5, 1.5)
		else
			part.Color = Color3.fromRGB(0, 255, 255)
		end

		table.insert(self._pathVisuals, part)

		if i < #self.currentPath then
			local nextWaypoint = self.currentPath[i + 1]
			local midpoint = (waypoint.Position + nextWaypoint.Position) / 2
			local distance = (waypoint.Position - nextWaypoint.Position).Magnitude

			local line = Instance.new("Part")
			line.Anchored = true
			line.CanCollide = false
			-- Z dimension is the length so the part spans between the two waypoints
			line.Size = Vector3.new(0.2, 0.2, distance)
			-- CFrame.new with a second argument auto-rotates so the Z axis points at the target
			line.CFrame = CFrame.new(midpoint, nextWaypoint.Position)
			line.Color = Color3.fromRGB(0, 200, 200)
			line.Material = Enum.Material.Neon
			line.Transparency = 0.6
			line.Parent = workspace

			table.insert(self._pathVisuals, line)
		end

		task.delay(5, function()
			if part and part.Parent then part:Destroy() end
		end)
	end
end

function NPCAIController:_onMoveToFinished(reached: boolean)
	if not self.currentPath and not reached then
		if Config.DEBUG.PRINT_EVENTS then
			print(string.format("NPC %s direct MoveTo failed", self.model.Name))
		end
	end
end

function NPCAIController:_setState(newState: string)
	if self.state == newState then return end

	if Config.DEBUG.PRINT_EVENTS then
		print(string.format("NPC %s: %s -> %s", self.model.Name, self.state, newState))
	end

	-- Clear the old path so the new state starts fresh rather than continuing a stale route
	self.currentPath = nil
	self.currentWaypointIndex = 1
	self._stuckTime = 0
	self.state = newState
	self._lastStateUpdate = os.clock()
end

function NPCAIController:_createStateIndicator()
	if not Config.DEBUG.ENABLED then return end

	local indicator = Instance.new("Part")
	indicator.Name = "StateIndicator"
	indicator.Size = Vector3.new(1, 0.5, 1)
	indicator.Anchored = true
	indicator.CanCollide = false
	indicator.Material = Enum.Material.Neon
	indicator.Shape = Enum.PartType.Cylinder
	indicator.Parent = self.model

	self._stateIndicator = indicator
end

function NPCAIController:_updateStateIndicator()
	if not self._stateIndicator or not self.rootPart then return end

	-- Offset 4 studs up then rotate 90deg on Z so the cylinder lays flat like a disc
	self._stateIndicator.CFrame = self.rootPart.CFrame * CFrame.new(0, 4, 0) * CFrame.Angles(0, 0, math.rad(90))

	if self.state == NPCState.IDLE then
		self._stateIndicator.Color = Color3.fromRGB(100, 100, 255) -- blue = idle
		self._stateIndicator.Transparency = 0.3
	elseif self.state == NPCState.INVESTIGATING then
		self._stateIndicator.Color = Color3.fromRGB(255, 255, 0)   -- yellow = heard something
		self._stateIndicator.Transparency = 0.3
	elseif self.state == NPCState.ALERT then
		self._stateIndicator.Color = Color3.fromRGB(255, 165, 0)   -- orange = scanning
		self._stateIndicator.Transparency = 0.3
	elseif self.state == NPCState.CHASING then
		self._stateIndicator.Color = Color3.fromRGB(255, 0, 0)     -- red = chasing
		-- 10hz sine wave oscillates transparency so the disc pulses visibly during a chase
		local flash = math.sin(os.clock() * 10) * 0.3 + 0.7
		self._stateIndicator.Transparency = 1 - flash
	end
end

function NPCAIController:destroy()
	for _, connection in ipairs(self._connections) do
		connection:Disconnect()
	end
	table.clear(self._connections)

	if self._stateIndicator then self._stateIndicator:Destroy() end

	if self._pathVisuals then
		for _, part in ipairs(self._pathVisuals) do part:Destroy() end
	end

	if self._currentWaypointMarker then self._currentWaypointMarker:Destroy() end

	table.clear(self.soundMemory)
	self.currentPath = nil
	self.currentTarget = nil
	self.lastHeardSound = nil
	self.lastSeenTarget = nil
	self.soundManager = nil
	self.model = nil
	self.humanoid = nil
	self.rootPart = nil
end


-- PLAYER SOUND EMITTER CLASS
-- Attached to each player. Monitors movement velocity and humanoid state to decide
-- when to emit sound events into the SoundManager.
local PlayerSoundEmitter = {}
PlayerSoundEmitter.__index = PlayerSoundEmitter

function PlayerSoundEmitter.new(player: Player, soundManager: any)
	local self = setmetatable({}, PlayerSoundEmitter)

	self.player = player
	self.soundManager = soundManager
	self.character = nil
	self.humanoid = nil
	self.rootPart = nil

	self._lastPosition = nil
	self._lastVelocity = Vector3.zero  -- initialized so landing math doesn't error before first frame
	self._isInAir = false
	self._lastJumpTime = 0             -- guards against Jumping and Freefall both firing a jump sound in one frame

	self._connections = {}

	if player.Character then
		self:_setupCharacter(player.Character)
	end

	table.insert(self._connections, player.CharacterAdded:Connect(function(char)
		self:_setupCharacter(char)
	end))

	return self
end

function PlayerSoundEmitter:_setupCharacter(character: Model)
	-- Disconnect stale connections from the previous body. Keep index 1 (CharacterAdded).
	for i = #self._connections, 2, -1 do
		self._connections[i]:Disconnect()
		table.remove(self._connections, i)
	end

	self.character = character
	self.humanoid = character:WaitForChild("Humanoid", 5)
	self.rootPart = character:WaitForChild("HumanoidRootPart", 5)

	if not self.humanoid or not self.rootPart then
		warn("PlayerSoundEmitter: failed to setup character for", self.player.Name)
		return
	end

	self._lastPosition = self.rootPart.Position
	self._isInAir = false

	table.insert(self._connections, self.humanoid.StateChanged:Connect(function(oldState, newState)
		self:_onStateChanged(oldState, newState)
	end))
end

function PlayerSoundEmitter:update(deltaTime: number)
	if not self.rootPart or not self.humanoid or self.humanoid.Health <= 0 then return end

	local currentPos = self.rootPart.Position
	local velocity = self.rootPart.AssemblyLinearVelocity
	local speed = velocity.Magnitude

	local movementType = self:_getMovementType(speed)

	if speed > 1 and movementType then
		-- Strip Y component so a player falling off a ledge doesn't emit a SPRINT sound
		local horizontalSpeed = (velocity * Vector3.new(1, 0, 1)).Magnitude

		if horizontalSpeed > 5 then
			self.soundManager:emitSound(currentPos, movementType, speed, self.player)
		end
	end

	self._lastPosition = currentPos
	self._lastVelocity = velocity -- saved so _onStateChanged can read fall speed at the moment of landing
end

function PlayerSoundEmitter:_getMovementType(speed: number): string?
	if not self.humanoid then return nil end

	-- Read WalkSpeed live in case a server script changes it for sprint mechanics
	local walkSpeed = self.humanoid.WalkSpeed

	if walkSpeed >= Config.MOVEMENT.SPRINT_SPEED and speed > 20 then
		return "SPRINT"
	elseif walkSpeed >= Config.MOVEMENT.RUN_SPEED and speed > 15 then
		return "RUN"
	elseif speed > 5 then
		return "WALK"
	end

	return nil
end

function PlayerSoundEmitter:_onStateChanged(oldState: Enum.HumanoidStateType, newState: Enum.HumanoidStateType)
	if not self.rootPart then return end

	local currentTime = os.clock()

	if newState == Enum.HumanoidStateType.Jumping or newState == Enum.HumanoidStateType.Freefall then
		-- Both Jumping and Freefall can fire within the same frame. The 0.5s cooldown prevents a double-emit.
		if not self._isInAir and currentTime - self._lastJumpTime > 0.5 then
			self._isInAir = true
			self._lastJumpTime = currentTime
			self.soundManager:emitSound(self.rootPart.Position, "JUMP", self.rootPart.AssemblyLinearVelocity.Magnitude, self.player)
		end
	end

	-- Running also fires when landing into a moving state, so we catch both Landed and Running
	if oldState == Enum.HumanoidStateType.Freefall and
		(newState == Enum.HumanoidStateType.Landed or newState == Enum.HumanoidStateType.Running) then

		if self._isInAir then
			self._isInAir = false
			self.soundManager:emitSound(
				self.rootPart.Position,
				"LAND",
				math.abs(self._lastVelocity.Y), -- Y is negative while falling, abs gives positive impact magnitude
				self.player
			)
		end
	end
end

function PlayerSoundEmitter:destroy()
	for _, connection in ipairs(self._connections) do
		connection:Disconnect()
	end
	table.clear(self._connections)
	self.character = nil
	self.humanoid = nil
	self.rootPart = nil
	self.soundManager = nil
end


-- SYSTEM (ORCHESTRATOR)
-- Top-level manager that owns the SoundManager and coordinates all NPC controllers
-- and player emitters. Entry point is System:initialize().
local System = {
	soundManager = nil,
	npcControllers = {},
	playerEmitters = {},

	_lastUpdate = 0,
	_npcUpdateIndex = 1,  -- position in the round-robin cycle, persists between ticks
	_deltaAccumulator = 0,
	_frameCount = 0,
}

function System:initialize()
	print("Initializing system...")

	self.soundManager = SoundManager.new()

	for _, player in ipairs(Players:GetPlayers()) do
		self:_onPlayerAdded(player)
	end

	Players.PlayerAdded:Connect(function(player) self:_onPlayerAdded(player) end)
	Players.PlayerRemoving:Connect(function(player) self:_onPlayerRemoving(player) end)

	self:_setupNPCs()
	self:_startUpdateLoop()

	print("System initialized successfully")
	print(string.format("  - NPCs: %d", #self.npcControllers))
	print(string.format("  - Update Rate: %.3fs (%.1f fps)", Config.PERFORMANCE.UPDATE_INTERVAL, 1/Config.PERFORMANCE.UPDATE_INTERVAL))
end

function System:_setupNPCs()
	local npcFolder = workspace:FindFirstChild("NPCs")

	if not npcFolder then
		warn("No NPCs folder found in workspace")
		npcFolder = Instance.new("Folder")
		npcFolder.Name = "NPCs"
		npcFolder.Parent = workspace
		return
	end

	for _, npcModel in ipairs(npcFolder:GetChildren()) do
		if npcModel:IsA("Model") and npcModel.PrimaryPart then
			self:_registerNPC(npcModel)
		end
	end

	npcFolder.ChildAdded:Connect(function(child)
		if child:IsA("Model") then
			task.wait() -- one-frame yield so the model finishes parenting before we read PrimaryPart
			self:_registerNPC(child)
		end
	end)
end

function System:_registerNPC(npcModel: Model)
	local controller = NPCAIController.new(npcModel, self.soundManager)
	if not controller then return end

	table.insert(self.npcControllers, controller)
	print("Registered NPC:", npcModel.Name)

	npcModel.Destroying:Connect(function()
		self:_unregisterNPC(controller)
	end)
end

function System:_unregisterNPC(controller: any)
	for i, ctrl in ipairs(self.npcControllers) do
		if ctrl == controller then
			ctrl:destroy()
			table.remove(self.npcControllers, i)
			break
		end
	end
end

function System:_onPlayerAdded(player: Player)
	self.playerEmitters[player] = PlayerSoundEmitter.new(player, self.soundManager)
	print("Player added:", player.Name)
end

function System:_onPlayerRemoving(player: Player)
	local emitter = self.playerEmitters[player]
	if emitter then
		emitter:destroy()
		self.playerEmitters[player] = nil
	end
	print("Player removed:", player.Name)
end

-- Accumulates Heartbeat delta time and fires an update tick once the interval is reached.
-- This decouples AI logic from the 60fps frame rate and keeps update cost predictable.
function System:_startUpdateLoop()
	local lastUpdate = os.clock()

	RunService.Heartbeat:Connect(function()
		local currentTime = os.clock()
		self._deltaAccumulator = self._deltaAccumulator + (currentTime - lastUpdate)

		if self._deltaAccumulator >= Config.PERFORMANCE.UPDATE_INTERVAL then
			local dt = self._deltaAccumulator
			self._deltaAccumulator = 0 -- full reset so leftover time doesn't cause drift over many frames
			self:_update(dt)
			lastUpdate = currentTime
		end
	end)
end

function System:_update(deltaTime: number)
	self._frameCount = self._frameCount + 1

	self.soundManager:update()

	for player, emitter in pairs(self.playerEmitters) do
		if player.Parent then
			emitter:update(deltaTime)
		end
	end

	local npcCount = #self.npcControllers
	if npcCount == 0 then return end

	local npcsToUpdate = math.min(Config.PERFORMANCE.MAX_NPCS_PER_UPDATE, npcCount)

	-- Round-robin: each tick we update a slice of NPCs starting where we left off last tick.
	-- This spreads CPU cost evenly rather than spiking when all NPCs update at once.
	for i = 1, npcsToUpdate do
		local index = ((self._npcUpdateIndex - 1) % npcCount) + 1
		local controller = self.npcControllers[index]
		if controller then
			controller:update(deltaTime)
		end
		self._npcUpdateIndex = self._npcUpdateIndex + 1
	end

	if Config.DEBUG.ENABLED and self._frameCount % 50 == 0 then
		print(string.format(
			"Active sounds: %d | NPCs: %d | Players: %d",
			self.soundManager._soundCount,
			npcCount,
			#Players:GetPlayers()
			))
	end
end

function System:getSoundManager()
	return self.soundManager
end

function System:emitSound(position: Vector3, soundType: string, velocity: number, emitter: Instance?)
	if self.soundManager then
		return self.soundManager:emitSound(position, soundType, velocity, emitter)
	end
end

function System:getPlayerEmitter(player: Player)
	return self.playerEmitters[player]
end

function System:shutdown()
	print("Shutting down system...")

	for _, controller in ipairs(self.npcControllers) do controller:destroy() end
	for _, emitter in pairs(self.playerEmitters) do emitter:destroy() end
	if self.soundManager then self.soundManager:destroy() end

	table.clear(self.npcControllers)
	table.clear(self.playerEmitters)

	print("System shut down")
end


-- ENTRY POINT
System:initialize()
_G.SoundAISystem = System -- expose globally so other scripts can call _G.SoundAISystem:emitSound
return System
