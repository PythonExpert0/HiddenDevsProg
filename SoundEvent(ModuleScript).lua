local Config = require(script.Parent.Config)

local SoundEvent = {}
SoundEvent.__index = SoundEvent

-- CONSTRUCTOR
function SoundEvent.new(position: Vector3, soundType: string, velocity: number, emitter: Instance?)
	local config = Config.SOUND_EVENTS[soundType]
	if not config then
		warn("Invalid sound type:", soundType)
		return nil
	end

	local self = setmetatable({}, SoundEvent)

	-- Core properties
	self.position = position
	self.soundType = soundType
	self.emitter = emitter

	-- Calculate dynamic radius based on velocity
	self.radius = config.baseRadius + (velocity * config.velocityMultiplier)

	-- Timing
	self.createdAt = os.clock()
	self.lifetime = config.duration
	self.expiresAt = self.createdAt + self.lifetime

	-- Cache for optimization
	self._radiusSquared = self.radius * self.radius
	self._isExpired = false

	-- Occlusion cache stores recent raycast results
	self._occlusionCache = {}
	self._lastCacheCleanup = os.clock()

	return self
end

-- CORE METHODS

-- Check if sound has expired (with cached result)
function SoundEvent:isExpired(currentTime: number?): boolean
	if self._isExpired then return true end

	local time = currentTime or os.clock()
	self._isExpired = time >= self.expiresAt

	return self._isExpired
end

-- Calculate sound intensity at a listener position WITH OCCLUSION
-- Returns 0-1 value based on distance falloff and obstacles
function SoundEvent:getIntensity(listenerPos: Vector3, raycastParams: RaycastParams?): number
	if self._isExpired then return 0 end

	local offset = listenerPos - self.position
	local distanceSquared = offset:Dot(offset)

	-- Early exit if out of range
	if distanceSquared > self._radiusSquared then
		return 0
	end

	-- Calculate base intensity from distance
	local distance = math.sqrt(distanceSquared)
	local normalizedDist = distance / self.radius
	local falloff = 1 - normalizedDist
	local baseIntensity = falloff * falloff

	-- Apply occlusion if raycast params provided
	if raycastParams then
		local occlusionMultiplier = self:_calculateOcclusion(listenerPos, raycastParams)
		return baseIntensity * occlusionMultiplier
	end

	return baseIntensity
end

-- OCCLUSION CALCULATION (SOUND BLOCKING)
function SoundEvent:_calculateOcclusion(listenerPos: Vector3, raycastParams: RaycastParams): number
	-- Check cache first (performance optimization)
	local cacheKey = self:_getCacheKey(listenerPos)
	local cached = self._occlusionCache[cacheKey]

	if cached and os.clock() - cached.timestamp < Config.OCCLUSION.CACHE_DURATION then
		return cached.multiplier
	end

	-- Perform raycast to detect obstacles
	local direction = listenerPos - self.position
	local distance = direction.Magnitude

	if distance < 0.1 then
		-- Listener is at sound source
		return 1.0
	end

	local result = workspace:Raycast(self.position, direction, raycastParams)

	local occlusionMultiplier = 1.0

	if result then
		-- Hit an obstacle between sound and listener
		local hitDistance = (result.Position - self.position).Magnitude

		-- Only apply occlusion if obstacle is actually between source and listener
		if hitDistance < distance - 1 then
			local material = result.Material
			local thickness = self:_estimateThickness(result, direction, raycastParams)

			-- Calculate occlusion based on material and thickness
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

	-- Cache the result
	self._occlusionCache[cacheKey] = {
		multiplier = occlusionMultiplier,
		timestamp = os.clock()
	}

	-- Periodic cache cleanup
	if os.clock() - self._lastCacheCleanup > 1.0 then
		self:_cleanupCache()
	end

	return occlusionMultiplier
end

-- Estimate obstacle thickness using a second raycast from the other side
function SoundEvent:_estimateThickness(firstHit: RaycastResult, direction: Vector3, raycastParams: RaycastParams): number
	-- Cast ray from slightly past the first hit point backwards
	local reverseStart = firstHit.Position + (direction.Unit * 0.5)
	local reverseDirection = -direction.Unit * 20 -- Check up to 20 studs back

	local reverseResult = workspace:Raycast(reverseStart, reverseDirection, raycastParams)

	if reverseResult and reverseResult.Instance == firstHit.Instance then
		-- We hit the back of the same object - calculate thickness
		local thickness = (firstHit.Position - reverseResult.Position).Magnitude
		return math.clamp(thickness, 0, Config.OCCLUSION.MAX_THICKNESS)
	end

	-- Assume minimum thickness if we can't determine it
	return Config.OCCLUSION.MIN_THICKNESS
end

-- Get occlusion multiplier based on material and thickness
function SoundEvent:_getMaterialOcclusion(material: Enum.Material, thickness: number): number
	-- Get base absorption for this material
	local absorption = Config.OCCLUSION.MATERIAL_ABSORPTION[material] 
		or Config.OCCLUSION.MATERIAL_ABSORPTION.Default

	-- Thicker walls block more sound
	local thicknessMultiplier = math.exp(-thickness * absorption * Config.OCCLUSION.THICKNESS_FACTOR)

	-- Ee always block at least some sound through solid objects
	return math.max(thicknessMultiplier, Config.OCCLUSION.MIN_PASSTHROUGH)
end

-- Generate cache key for position
function SoundEvent:_getCacheKey(position: Vector3): string
	local gridSize = 5 -- Round to 5-stud grid
	local x = math.floor(position.X / gridSize) * gridSize
	local y = math.floor(position.Y / gridSize) * gridSize
	local z = math.floor(position.Z / gridSize) * gridSize
	return string.format("%d,%d,%d", x, y, z)
end

-- Clean up old cache entries
function SoundEvent:_cleanupCache()
	local currentTime = os.clock()
	local newCache = {}

	for key, data in pairs(self._occlusionCache) do
		if currentTime - data.timestamp < Config.OCCLUSION.CACHE_DURATION then
			newCache[key] = data
		end
	end

	self._occlusionCache = newCache
	self._lastCacheCleanup = currentTime
end

-- UTILITY METHODS

-- Get remaining lifetime
function SoundEvent:getRemainingLife(): number
	return math.max(0, self.expiresAt - os.clock())
end

-- Get age of sound
function SoundEvent:getAge(): number
	return os.clock() - self.createdAt
end

-- Check if sound is within range of position (no occlusion check)
function SoundEvent:isInRange(position: Vector3): boolean
	if self._isExpired then return false end

	local offset = position - self.position
	return offset:Dot(offset) <= self._radiusSquared
end

-- CLEANUP
function SoundEvent:destroy()
	self._isExpired = true
	self.emitter = nil
	self.position = nil
	table.clear(self._occlusionCache)
end

return SoundEvent
