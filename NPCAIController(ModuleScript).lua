local RunService = game:GetService("RunService")
local PathfindingService = game:GetService("PathfindingService")

local Config = require(game.ReplicatedStorage.SoundAI.Config)

-- ENUMS
local NPCState = {
	IDLE = "Idle",
	PATROL = "Patrol",
	INVESTIGATING = "Investigating",
	ALERT = "Alert",
	CHASING = "Chasing"
}

local NPCAIController = {}
NPCAIController.__index = NPCAIController

-- CONSTRUCTOR
function NPCAIController.new(npcModel: Model, soundManager: any)
	assert(npcModel:IsA("Model"), "NPC must be a Model")
	assert(npcModel.PrimaryPart, "NPC must have a PrimaryPart")

	local self = setmetatable({}, NPCAIController)

	-- References
	self.model = npcModel
	self.humanoid = npcModel:FindFirstChildOfClass("Humanoid")
	self.rootPart = npcModel.PrimaryPart
	self.soundManager = soundManager

	-- State
	self.state = NPCState.IDLE
	self.currentTarget = nil -- Vector3 or Instance
	self.lastHeardSound = nil
	self.lastSeenTarget = nil

	-- Memory
	self.soundMemory = {} -- Stores recent sounds with timestamps
	self.alertStartTime = 0
	self.investigationStartTime = 0
	self.chaseStartTime = 0
	self.lastSawTargetTime = 0

	-- Pathfinding with obstacle detection (FIXED PARAMETERS)
	self.pathfindingAgent = PathfindingService:CreatePath({
		AgentRadius = 2,                    -- NPC collision radius
		AgentHeight = 5,                    -- NPC height
		AgentCanJump = true,                -- Enable jumping
		AgentCanClimb = false,              -- No climbing
		WaypointSpacing = 4,                -- Spacing between waypoints
		Costs = {
			Water = 20,                     -- Avoid water
			Danger = math.huge,             -- Never go through danger
		}
	})
	self.currentPath = nil
	self.currentWaypointIndex = 1
	self._pathfindingConnection = nil
	self._lastPathUpdate = 0
	self._pathComputeInProgress = false

	-- Movement tracking
	self._lastPosition = npcModel.PrimaryPart.Position
	self._stuckTime = 0
	self._stuckThreshold = 1.5 -- seconds before considering stuck
	self._minMovementThreshold = 0.5 -- minimum distance to move per second

	-- Raycast setup
	self.raycastParams = RaycastParams.new()
	self.raycastParams.FilterDescendantsInstances = {npcModel}
	self.raycastParams.FilterType = Enum.RaycastFilterType.Exclude

	-- Timing
	self._lastLOSCheck = 0
	self._lastStateUpdate = 0
	self._lastChaseUpdate = 0
	self._lastMoveCommand = 0
	self._lastStuckCheck = 0

	-- Connections for a proper cleanup
	self._connections = {}

	if not self.humanoid then
		warn("NPC missing Humanoid:", npcModel.Name)
		return nil
	end

	self.humanoid.AutoRotate = true 

	-- Listen for path blocked
	if self.pathfindingAgent then
		table.insert(self._connections, self.pathfindingAgent.Blocked:Connect(function(waypointIndex)
			self:_onPathBlocked(waypointIndex)
		end))
	end

	-- Listen for when humanoid reaches destination
	table.insert(self._connections, self.humanoid.MoveToFinished:Connect(function(reached)
		self:_onMoveToFinished(reached)
	end))

	-- Visual indicator for NPC state
	self:_createStateIndicator()

	return self
end

-- MAIN UPDATE LOOP
function NPCAIController:update(deltaTime: number)
	if not self.humanoid or self.humanoid.Health <= 0 then
		return
	end

	local currentTime = os.clock()

	-- Check if stuck
	if currentTime - self._lastStuckCheck > 0.5 then
		self:_checkIfStuck(currentTime)
		self._lastStuckCheck = currentTime
	end

	-- Update sound memory get rid of old sounds
	self:_updateSoundMemory(currentTime)

	-- Check for new sounds
	self:_checkForSounds()

	-- Perform line-of-sight checks periodically
	if currentTime - self._lastLOSCheck >= Config.NPC.LOS_CHECK_INTERVAL then
		self:_performLOSCheck()
		self._lastLOSCheck = currentTime
	end

	-- Update state indicator color
	self:_updateStateIndicator()

	-- State machine
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

-- STUCK DETECTION
function NPCAIController:_checkIfStuck(currentTime: number)
	if not self.rootPart then return end

	local currentPos = self.rootPart.Position
	local distanceMoved = (currentPos - self._lastPosition).Magnitude

	-- If we're supposed to be moving but aren't
	if self.state == NPCState.CHASING or self.state == NPCState.INVESTIGATING then
		if distanceMoved < self._minMovementThreshold then
			self._stuckTime = self._stuckTime + (currentTime - self._lastStuckCheck)

			if self._stuckTime > self._stuckThreshold then
				-- Stuck recaclulte path
				if Config.DEBUG.PRINT_EVENTS then
					print(string.format("[NPC %s] STUCK! Recomputing path...", self.model.Name))
				end

				-- Force path recomputation
				if self.currentTarget then
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
			-- Moving fine, reset stuck timer
			self._stuckTime = 0
		end
	else
		self._stuckTime = 0
	end

	self._lastPosition = currentPos
end

-- SOUND DETECTION
function NPCAIController:_checkForSounds()
	local closestSound, intensity = self.soundManager:getClosestSound(
		self.rootPart.Position,
		Config.NPC.HEARING_RANGE
	)

	if closestSound and intensity > 0.15 then
		-- Add to sound memory
		self:_addSoundMemory(closestSound, intensity)

		-- React based on current state
		if self.state == NPCState.IDLE or self.state == NPCState.PATROL then
			self:_setState(NPCState.INVESTIGATING)
			self.currentTarget = closestSound.position
			self.investigationStartTime = os.clock()

		elseif self.state == NPCState.ALERT and intensity > 0.5 then
			-- Very loud sound while alert -> investigate
			self:_setState(NPCState.INVESTIGATING)
			self.currentTarget = closestSound.position
			self.investigationStartTime = os.clock()
		end
	end
end

function NPCAIController:_addSoundMemory(sound: any, intensity: number)
	table.insert(self.soundMemory, {
		position = sound.position,
		intensity = intensity,
		timestamp = os.clock(),
		soundType = sound.soundType
	})

	-- Limit memory size
	if #self.soundMemory > 10 then
		table.remove(self.soundMemory, 1)
	end

	self.lastHeardSound = sound
end

function NPCAIController:_updateSoundMemory(currentTime: number)
	-- Remove old memories
	for i = #self.soundMemory, 1, -1 do
		local memory = self.soundMemory[i]
		if currentTime - memory.timestamp > Config.NPC.SOUND_MEMORY_DURATION then
			table.remove(self.soundMemory, i)
		end
	end
end

-- LINE OF SIGHT
function NPCAIController:_performLOSCheck()
	if not self.rootPart then return end

	-- Get players in range
	local players = game.Players:GetPlayers()
	local origin = self.rootPart.Position + Vector3.new(0, Config.NPC.LOS_HEIGHT_OFFSET, 0)
	local npcLookDir = self.rootPart.CFrame.LookVector

	for _, player in ipairs(players) do
		local character = player.Character
		if character and character:FindFirstChild("HumanoidRootPart") then
			local targetRoot = character.HumanoidRootPart
			local targetPos = targetRoot.Position + Vector3.new(0, 1.5, 0)
			local direction = targetPos - origin
			local distance = direction.Magnitude

			if distance <= Config.NPC.LOS_CHECK_DISTANCE then
				-- Check field of view
				local dirNormalized = direction.Unit
				local dotProduct = npcLookDir:Dot(dirNormalized)
				local angleToTarget = math.deg(math.acos(math.clamp(dotProduct, -1, 1)))

				if angleToTarget <= Config.NPC.LOS_FOV / 2 then
					-- Within FOV, check for obstacles
					local result = workspace:Raycast(origin, direction, self.raycastParams)

					if result and result.Instance:IsDescendantOf(character) then
						-- Clear line of sight
						self:_onTargetSpotted(character, player)
						return
					end
				end
			end
		end
	end

	-- Lost sight of target
	if self.state == NPCState.CHASING then
		local currentTime = os.clock()
		if currentTime - self.lastSawTargetTime > Config.NPC.LOSE_SIGHT_GRACE then
			self:_onLostTarget()
		end
	end
end

function NPCAIController:_onTargetSpotted(target: Model, player: Player)
	self.lastSeenTarget = target
	self.currentTarget = target
	self.lastSawTargetTime = os.clock()

	if self.state ~= NPCState.CHASING then
		self:_setState(NPCState.CHASING)
		self.chaseStartTime = os.clock()

		if Config.DEBUG.PRINT_EVENTS then
			print(string.format("[NPC %s] SPOTTED %s!", self.model.Name, player.Name))
		end
	end
end

function NPCAIController:_onLostTarget()
	if Config.DEBUG.PRINT_EVENTS then
		print(string.format("[NPC %s] Lost target, searching...", self.model.Name))
	end

	-- Go to last known position
	if self.currentTarget and self.currentTarget:IsA("Model") then
		local lastPos = self.currentTarget.PrimaryPart and self.currentTarget.PrimaryPart.Position
		if lastPos then
			self.currentTarget = lastPos
		end
	end

	self:_setState(NPCState.INVESTIGATING)
	self.investigationStartTime = os.clock()
end

-- STATE BEHAVIORS
function NPCAIController:_updateIdle(deltaTime: number)
	self.humanoid.WalkSpeed = 0
	-- NPCs will just stand and listen for sounds
end

function NPCAIController:_updatePatrol(deltaTime: number)
	self.humanoid.WalkSpeed = Config.NPC.PATROL_SPEED
end

function NPCAIController:_updateInvestigating(deltaTime: number, currentTime: number)
	if not self.currentTarget then
		self:_setState(NPCState.IDLE)
		return
	end

	-- Timeout check
	if currentTime - self.investigationStartTime > Config.NPC.INVESTIGATION_TIMEOUT then
		self:_setState(NPCState.ALERT)
		self.alertStartTime = currentTime
		return
	end

	self.humanoid.WalkSpeed = Config.NPC.INVESTIGATION_SPEED

	-- Move to investigation point
	local targetPos = if typeof(self.currentTarget) == "Vector3" 
		then self.currentTarget 
		else self.currentTarget.Position

	-- Use pathfinding for investigation
	if not self.currentPath or currentTime - self._lastPathUpdate > 2 then
		self:_computePath(targetPos)
		self._lastPathUpdate = currentTime
	end

	if self.currentPath then
		self:_followPath()
	end

	-- Check if reached
	local distance = (self.rootPart.Position - targetPos).Magnitude
	if distance < 5 then
		-- Arrived, look around
		self:_setState(NPCState.ALERT)
		self.alertStartTime = currentTime
	end
end

function NPCAIController:_updateAlert(deltaTime: number, currentTime: number)
	self.humanoid.WalkSpeed = 0

	-- Stay alert for a duration
	if currentTime - self.alertStartTime > Config.NPC.ALERT_DURATION then
		self:_setState(NPCState.IDLE)
		self.currentTarget = nil
	end
end

function NPCAIController:_updateChasing(deltaTime: number, currentTime: number)
	-- Check if target is still valid
	if not self.currentTarget or not self.currentTarget:FindFirstChild("HumanoidRootPart") then
		self:_onLostTarget()
		return
	end

	-- Chase timeout
	if currentTime - self.chaseStartTime > Config.NPC.CHASE_TIMEOUT then
		if Config.DEBUG.PRINT_EVENTS then
			print(string.format("[NPC %s] Chase timeout, giving up", self.model.Name))
		end
		self:_setState(NPCState.ALERT)
		self.alertStartTime = currentTime
		return
	end

	-- Set chase speed
	self.humanoid.WalkSpeed = Config.NPC.ALERT_SPEED

	-- Get target position
	local targetRoot = self.currentTarget.HumanoidRootPart
	local targetPos = targetRoot.Position
	local distance = (self.rootPart.Position - targetPos).Magnitude

	-- Check if caught the target
	if distance < Config.NPC.MIN_CHASE_DISTANCE then
		if Config.DEBUG.PRINT_EVENTS then
			print(string.format("[NPC %s] CAUGHT TARGET!", self.model.Name))
		end
		self:_setState(NPCState.ALERT)
		self.alertStartTime = currentTime
		return
	end

	-- Update path more frequently during chase (every 0.3 seconds)
	if currentTime - self._lastPathUpdate > 0.3 and not self._pathComputeInProgress then
		self:_computePath(targetPos)
		self._lastPathUpdate = currentTime
	end

	-- Follow current path
	if self.currentPath then
		self:_followPath()
	end
end

-- PATHFINDING
function NPCAIController:_computePath(targetPos: Vector3)
	if not self.rootPart or self._pathComputeInProgress then return end

	self._pathComputeInProgress = true

	local success, errorMessage = pcall(function()
		self.pathfindingAgent:ComputeAsync(self.rootPart.Position, targetPos)
	end)

	if success and self.pathfindingAgent.Status == Enum.PathStatus.Success then
		self.currentPath = self.pathfindingAgent:GetWaypoints()
		self.currentWaypointIndex = 1

		-- Skip first waypoint if we're already close to it
		if #self.currentPath > 1 then
			local firstWaypoint = self.currentPath[1]
			local distToFirst = (self.rootPart.Position - firstWaypoint.Position).Magnitude
			if distToFirst < 3 then
				self.currentWaypointIndex = 2
			end
		end

		-- Draw path for debugging
		if Config.DEBUG.SHOW_INVESTIGATION_PATHS then
			self:_visualizePath()
		end

		if Config.DEBUG.PRINT_EVENTS then
			print(string.format("[NPC %s] Computed path with %d waypoints", self.model.Name, #self.currentPath))
		end

		self._pathComputeInProgress = false
		return true
	else
		-- Pathfinding failed
		if Config.DEBUG.PRINT_EVENTS then
			local statusMsg = "Unknown"
			if self.pathfindingAgent.Status == Enum.PathStatus.NoPath then
				statusMsg = "No path found"
			elseif self.pathfindingAgent.Status == Enum.PathStatus.ClosestNoPath then
				statusMsg = "Partial path (using closest point)"
				-- Use partial path if available
				local waypoints = self.pathfindingAgent:GetWaypoints()
				if #waypoints > 0 then
					self.currentPath = waypoints
					self.currentWaypointIndex = 1
					self._pathComputeInProgress = false
					return true
				end
			elseif self.pathfindingAgent.Status == Enum.PathStatus.ClosestOutOfRange then
				statusMsg = "Target out of range"
			end
			warn(string.format("[NPC %s] Pathfinding failed: %s", self.model.Name, statusMsg))
		end

		-- Clear current path
		self.currentPath = nil
		self._pathComputeInProgress = false
		return false
	end
end

function NPCAIController:_followPath()
	if not self.currentPath or not self.rootPart or not self.humanoid then return end

	local waypoints = self.currentPath

	-- Check if we've completed the path
	if self.currentWaypointIndex > #waypoints then
		self.currentPath = nil
		return
	end

	local targetWaypoint = waypoints[self.currentWaypointIndex]
	local horizontalPos = Vector3.new(targetWaypoint.Position.X, self.rootPart.Position.Y, targetWaypoint.Position.Z)
	local distance = (self.rootPart.Position - horizontalPos).Magnitude

	-- Reached current waypoint, move to next
	if distance < 4 then
		self.currentWaypointIndex = self.currentWaypointIndex + 1

		if self.currentWaypointIndex > #waypoints then
			self.currentPath = nil
			return
		end

		targetWaypoint = waypoints[self.currentWaypointIndex]
	end

	-- Handle jump action BEFORE moving
	if targetWaypoint.Action == Enum.PathWaypointAction.Jump then
		self.humanoid.Jump = true
		-- Wait a moment before moving to allow jump to start
		task.wait(0.1)
	end

	-- Move to current waypoint
	self.humanoid:MoveTo(targetWaypoint.Position)

	-- Update waypoint marker
	if Config.DEBUG.SHOW_INVESTIGATION_PATHS then
		if not self._currentWaypointMarker then
			self._currentWaypointMarker = Instance.new("Part")
			self._currentWaypointMarker.Anchored = true
			self._currentWaypointMarker.CanCollide = false
			self._currentWaypointMarker.Size = Vector3.new(2, 2, 2)
			self._currentWaypointMarker.Color = Color3.fromRGB(255, 0, 255)
			self._currentWaypointMarker.Material = Enum.Material.Neon
			self._currentWaypointMarker.Transparency = 0.3
			self._currentWaypointMarker.Shape = Enum.PartType.Ball
			self._currentWaypointMarker.Parent = workspace
		end
		self._currentWaypointMarker.Position = targetWaypoint.Position
	end
end

function NPCAIController:_onPathBlocked(waypointIndex: number)
	-- Path was blocked, recalculate
	if Config.DEBUG.PRINT_EVENTS then
		print(string.format("[NPC %s] Path blocked at waypoint %d, recomputing...", self.model.Name, waypointIndex))
	end

	-- Clear current path to force recalculation
	self.currentPath = nil
end

function NPCAIController:_visualizePath()
	-- Clear old path visualization
	if self._pathVisuals then
		for _, part in ipairs(self._pathVisuals) do
			part:Destroy()
		end
	end
	self._pathVisuals = {}

	if not self.currentPath then return end

	-- Draw waypoints
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

		-- Color based on action
		if waypoint.Action == Enum.PathWaypointAction.Jump then
			part.Color = Color3.fromRGB(255, 255, 0) -- Yellow for jumps
			part.Size = Vector3.new(1.5, 1.5, 1.5) -- Larger for visibility
		else
			part.Color = Color3.fromRGB(0, 255, 255) -- Cyan for normal
		end

		table.insert(self._pathVisuals, part)

		-- Draw line to next waypoint
		if i < #self.currentPath then
			local nextWaypoint = self.currentPath[i + 1]
			local midpoint = (waypoint.Position + nextWaypoint.Position) / 2
			local distance = (waypoint.Position - nextWaypoint.Position).Magnitude

			local line = Instance.new("Part")
			line.Anchored = true
			line.CanCollide = false
			line.Size = Vector3.new(0.2, 0.2, distance)
			line.CFrame = CFrame.new(midpoint, nextWaypoint.Position)
			line.Color = Color3.fromRGB(0, 200, 200)
			line.Material = Enum.Material.Neon
			line.Transparency = 0.6
			line.Parent = workspace

			table.insert(self._pathVisuals, line)
		end

		-- Auto-cleanup after 5 seconds
		task.delay(5, function()
			if part and part.Parent then
				part:Destroy()
			end
		end)
	end
end

function NPCAIController:_onMoveToFinished(reached: boolean)
	-- If theres a path, the path following logic handles waypoint advancement
	if not self.currentPath and not reached then
		-- No path and didn't reach target - might be stuck
		if Config.DEBUG.PRINT_EVENTS then
			print(string.format("[NPC %s] MoveTo failed without path", self.model.Name))
		end
	end
end


-- STATE MANAGEMENT
function NPCAIController:_setState(newState: string)
	if self.state == newState then return end

	if Config.DEBUG.PRINT_EVENTS then
		print(string.format("[NPC %s] %s -> %s", self.model.Name, self.state, newState))
	end

	-- Clear path when changing states
	self.currentPath = nil
	self.currentWaypointIndex = 1
	self._stuckTime = 0

	self.state = newState
	self._lastStateUpdate = os.clock()
end

-- VISUAL INDICATORS (Debug)
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

	-- Position above NPC head
	self._stateIndicator.CFrame = self.rootPart.CFrame * CFrame.new(0, 4, 0) * CFrame.Angles(0, 0, math.rad(90))

	-- Color based on state
	if self.state == NPCState.IDLE then
		self._stateIndicator.Color = Color3.fromRGB(100, 100, 255) -- Blue
		self._stateIndicator.Transparency = 0.3
	elseif self.state == NPCState.INVESTIGATING then
		self._stateIndicator.Color = Color3.fromRGB(255, 255, 0) -- Yellow
		self._stateIndicator.Transparency = 0.3
	elseif self.state == NPCState.ALERT then
		self._stateIndicator.Color = Color3.fromRGB(255, 165, 0) -- Orange
		self._stateIndicator.Transparency = 0.3
	elseif self.state == NPCState.CHASING then
		self._stateIndicator.Color = Color3.fromRGB(255, 0, 0) -- Red
		-- Make it flash when chasing
		local flash = math.sin(os.clock() * 10) * 0.3 + 0.7
		self._stateIndicator.Transparency = 1 - flash
	end
end

-- CLEANUP
function NPCAIController:destroy()
	-- Disconnect all connections
	for _, connection in ipairs(self._connections) do
		connection:Disconnect()
	end
	table.clear(self._connections)

	-- Destroy visual indicator
	if self._stateIndicator then
		self._stateIndicator:Destroy()
	end

	-- Clear path visuals
	if self._pathVisuals then
		for _, part in ipairs(self._pathVisuals) do
			part:Destroy()
		end
	end

	-- Clear current waypoint marker
	if self._currentWaypointMarker then
		self._currentWaypointMarker:Destroy()
	end

	-- Clear references
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

return NPCAIController
