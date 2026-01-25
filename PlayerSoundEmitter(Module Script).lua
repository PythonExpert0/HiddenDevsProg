local Config = require(game.ReplicatedStorage.SoundAI.Config)

local PlayerSoundEmitter = {}
PlayerSoundEmitter.__index = PlayerSoundEmitter

-- CONSTRUCTOR
function PlayerSoundEmitter.new(player: Player, soundManager: any)
	local self = setmetatable({}, PlayerSoundEmitter)

	self.player = player
	self.soundManager = soundManager
	self.character = nil
	self.humanoid = nil
	self.rootPart = nil

	-- State tracking
	self._lastPosition = nil
	self._lastVelocity = Vector3.zero
	self._isInAir = false
	self._lastJumpTime = 0

	-- Connections
	self._connections = {}

	-- Setup character
	if player.Character then
		self:_setupCharacter(player.Character)
	end

	table.insert(self._connections, player.CharacterAdded:Connect(function(char)
		self:_setupCharacter(char)
	end))

	return self
end

-- CHARACTER SETUP
function PlayerSoundEmitter:_setupCharacter(character: Model)
	-- Clean up old connections
	for i = #self._connections, 1, -1 do
		if i > 1 then -- Keep the CharacterAdded connection
			self._connections[i]:Disconnect()
			table.remove(self._connections, i)
		end
	end

	self.character = character
	self.humanoid = character:WaitForChild("Humanoid", 5)
	self.rootPart = character:WaitForChild("HumanoidRootPart", 5)

	if not self.humanoid or not self.rootPart then
		warn("PlayerSoundEmitter: Failed to setup character for", self.player.Name)
		return
	end

	self._lastPosition = self.rootPart.Position
	self._isInAir = false

	-- Listen for jumps
	table.insert(self._connections, self.humanoid.StateChanged:Connect(function(oldState, newState)
		self:_onStateChanged(oldState, newState)
	end))
end

-- UPDATE LOOP
function PlayerSoundEmitter:update(deltaTime: number)
	if not self.rootPart or not self.humanoid or self.humanoid.Health <= 0 then
		return
	end

	local currentPos = self.rootPart.Position
	local velocity = self.rootPart.AssemblyLinearVelocity
	local speed = velocity.Magnitude

	-- Determine movement type based on speed
	local movementType = self:_getMovementType(speed)

	-- Only emit sound if moving significantly
	if speed > 1 and movementType then
		-- Calculate time-based emission
		local horizontalSpeed = (velocity * Vector3.new(1, 0, 1)).Magnitude

		if horizontalSpeed > 5 then -- Threshold to prevent idle jitter
			self.soundManager:emitSound(
				currentPos,
				movementType,
				speed,
				self.player
			)
		end
	end

	self._lastPosition = currentPos
	self._lastVelocity = velocity
end

-- STATE DETECTION
function PlayerSoundEmitter:_getMovementType(speed: number): string?
	if not self.humanoid then return nil end

	-- Determine movement type based on WalkSpeed and actual speed
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

	-- Jump detection
	if newState == Enum.HumanoidStateType.Jumping or newState == Enum.HumanoidStateType.Freefall then
		if not self._isInAir and currentTime - self._lastJumpTime > 0.5 then
			self._isInAir = true
			self._lastJumpTime = currentTime

			-- Emit jump sound
			local velocity = self.rootPart.AssemblyLinearVelocity
			self.soundManager:emitSound(
				self.rootPart.Position,
				"JUMP",
				velocity.Magnitude,
				self.player
			)
		end
	end

	-- Landing detection
	if oldState == Enum.HumanoidStateType.Freefall and 
		(newState == Enum.HumanoidStateType.Landed or newState == Enum.HumanoidStateType.Running) then

		if self._isInAir then
			self._isInAir = false

			-- Emit landing sound
			local velocity = self._lastVelocity
			self.soundManager:emitSound(
				self.rootPart.Position,
				"LAND",
				math.abs(velocity.Y),
				self.player
			)
		end
	end
end

-- CLEANUP
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

return PlayerSoundEmitter
