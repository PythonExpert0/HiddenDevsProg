local Config = require(game.ReplicatedStorage.SoundAI.Config)
local SoundEvent = require(game.ReplicatedStorage.SoundAI.SoundEvent)

local SoundManager = {}
SoundManager.__index = SoundManager

-- CONSTRUCTOR
function SoundManager.new()
	local self = setmetatable({}, SoundManager)

	-- Active sounds storage
	self._sounds = {}
	self._soundCount = 0

	-- Player sound tracking (prevent spam)
	self._playerSoundCounts = {} -- [player] = count
	self._playerLastSound = {}   -- [player] = timestamp

	-- Timing
	self._lastCleanup = os.clock()

	-- Spatial partitioning
	self._spatialGrid = {}
	self._gridSize = Config.PERFORMANCE.SPATIAL_GRID_SIZE

	return self
end

-- SOUND EMISSION
function SoundManager:emitSound(position: Vector3, soundType: string, velocity: number, emitter: Instance?)
	-- Validate sound type
	local soundConfig = Config.SOUND_EVENTS[soundType]
	if not soundConfig or soundConfig.baseRadius == 0 then
		return nil -- Silent sound type
	end

	-- Rate limiting per player
	if emitter and emitter:IsA("Player") then
		local now = os.clock()
		local lastTime = self._playerLastSound[emitter] or 0

		if now - lastTime < 0.1 then -- 100ms minimum between sounds
			local count = self._playerSoundCounts[emitter] or 0
			if count >= Config.PERFORMANCE.MAX_SOUNDS_PER_PLAYER then
				return nil -- Too many sounds
			end
		else
			self._playerSoundCounts[emitter] = 0
		end

		self._playerLastSound[emitter] = now
		self._playerSoundCounts[emitter] = (self._playerSoundCounts[emitter] or 0) + 1
	end

	-- Create sound event
	local sound = SoundEvent.new(position, soundType, velocity, emitter)
	if not sound then return nil end

	-- Add to active sounds
	table.insert(self._sounds, sound)
	self._soundCount = self._soundCount + 1

	-- Add to spatial grid
	self:_addToGrid(sound)

	-- Debug visualization
	if Config.DEBUG.ENABLED and Config.DEBUG.SHOW_SOUND_RADIUS then
		self:_visualizeSound(sound)
	end

	if Config.DEBUG.PRINT_EVENTS then
		print(string.format("[Sound] %s at %s, radius: %.1f", soundType, tostring(position), sound.radius))
	end

	return sound
end

-- SOUND QUERIES

-- Get the closest/loudest sound to a listener position
function SoundManager:getClosestSound(listenerPos: Vector3, maxRange: number)
	local currentTime = os.clock()
	local bestSound = nil
	local maxIntensity = 0

	-- Use spatial grid for optimization if available
	local nearbySounds = self:_getNearbySounds(listenerPos, maxRange)

	for _, sound in ipairs(nearbySounds) do
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

-- Get all sounds within range of a position
function SoundManager:getSoundsInRange(position: Vector3, range: number)
	local currentTime = os.clock()
	local soundsInRange = {}

	local nearbySounds = self:_getNearbySounds(position, range)

	for _, sound in ipairs(nearbySounds) do
		if not sound:isExpired(currentTime) and sound:isInRange(position) then
			table.insert(soundsInRange, sound)
		end
	end

	return soundsInRange
end

-- UPDATE & CLEANUP
function SoundManager:update()
	local currentTime = os.clock()

	-- Periodic cleanup of expired sounds
	if currentTime - self._lastCleanup >= Config.PERFORMANCE.SOUND_CLEANUP_INTERVAL then
		self:_cleanup(currentTime)
		self._lastCleanup = currentTime
	end
end

-- Remove expired sounds
function SoundManager:_cleanup(currentTime: number)
	for i = #self._sounds, 1, -1 do
		local sound = self._sounds[i]

		if sound:isExpired(currentTime) then
			self:_removeFromGrid(sound)
			sound:destroy()
			table.remove(self._sounds, i)
			self._soundCount = self._soundCount - 1
		end
	end

	-- Clear player sound counters periodically
	if currentTime % 2 < 0.1 then
		table.clear(self._playerSoundCounts)
	end
end

-- SPATIAL GRID OPTIMIZATION
function SoundManager:_getGridKey(position: Vector3): string
	local gx = math.floor(position.X / self._gridSize)
	local gz = math.floor(position.Z / self._gridSize)
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

function SoundManager:_getNearbySounds(position: Vector3, range: number)
	-- Calculate grid cells to check
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

	-- Fallback to full list if grid is empty
	return #nearbySounds > 0 and nearbySounds or self._sounds
end

-- DEBUG VISUALIZATION
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

-- CLEANUP
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

return SoundManager
