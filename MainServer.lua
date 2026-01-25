local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

-- Modules
local Config = require(game.ReplicatedStorage.SoundAI.Config)
local SoundManager = require(script.SoundManager)
local NPCAIController = require(script.NPCAIController)
local PlayerSoundEmitter = require(script.PlayerSoundEmitter)

-- SYSTEM STATE
local System = {
	soundManager = nil,
	npcControllers = {},
	playerEmitters = {},

	-- Performance tracking
	_lastUpdate = 0,
	_npcUpdateIndex = 1,
	_deltaAccumulator = 0,
	_frameCount = 0,
}

-- INITIALIZATION
function System:initialize()
	print("[SoundAI] Initializing system...")

	-- Create sound manager
	self.soundManager = SoundManager.new()

	-- Setup players
	for _, player in ipairs(Players:GetPlayers()) do
		self:_onPlayerAdded(player)
	end

	Players.PlayerAdded:Connect(function(player)
		self:_onPlayerAdded(player)
	end)

	Players.PlayerRemoving:Connect(function(player)
		self:_onPlayerRemoving(player)
	end)

	-- Setup NPCs
	self:_setupNPCs()

	-- Start main update loop
	self:_startUpdateLoop()

	print("[SoundAI] System initialized successfully")
	print(string.format("  - NPCs: %d", #self.npcControllers))
	print(string.format("  - Update Rate: %.3fs (%.1f fps)", Config.PERFORMANCE.UPDATE_INTERVAL, 1/Config.PERFORMANCE.UPDATE_INTERVAL))
end

-- NPC SETUP
function System:_setupNPCs()
	-- Find all NPCs in workspace
	local npcFolder = workspace:FindFirstChild("NPCs")

	if not npcFolder then
		warn("[SoundAI] No NPCs folder found in workspace. Create workspace.NPCs and add NPC models there.")
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

	-- Listen for new NPCs
	npcFolder.ChildAdded:Connect(function(child)
		if child:IsA("Model") then
			task.wait() -- Wait for model to fully load
			self:_registerNPC(child)
		end
	end)
end

function System:_registerNPC(npcModel: Model)
	local controller = NPCAIController.new(npcModel, self.soundManager)

	if controller then
		table.insert(self.npcControllers, controller)
		print("[SoundAI] Registered NPC:", npcModel.Name)

		-- Cleanup when NPC is destroyed
		npcModel.Destroying:Connect(function()
			self:_unregisterNPC(controller)
		end)
	end
end

function System:_unregisterNPC(controller: any)
	for i, ctrl in ipairs(self.npcControllers) do
		if ctrl == controller then
			ctrl:destroy()
			table.remove(self.npcControllers, i)
			print("[SoundAI] Unregistered NPC")
			break
		end
	end
end

-- PLAYER SETUP
function System:_onPlayerAdded(player: Player)
	local emitter = PlayerSoundEmitter.new(player, self.soundManager)
	self.playerEmitters[player] = emitter

	print("[SoundAI] Player added:", player.Name)
end

function System:_onPlayerRemoving(player: Player)
	local emitter = self.playerEmitters[player]
	if emitter then
		emitter:destroy()
		self.playerEmitters[player] = nil
	end

	print("[SoundAI] Player removed:", player.Name)
end

-- MAIN UPDATE LOOP
function System:_startUpdateLoop()
	local lastUpdate = os.clock()

	--server-side updates
	RunService.Heartbeat:Connect(function()
		local currentTime = os.clock()
		local deltaTime = currentTime - lastUpdate

		self._deltaAccumulator = self._deltaAccumulator + deltaTime

		-- Fixed timestep updates
		if self._deltaAccumulator >= Config.PERFORMANCE.UPDATE_INTERVAL then
			local dt = self._deltaAccumulator
			self._deltaAccumulator = 0

			self:_update(dt)
			lastUpdate = currentTime
		end
	end)
end

function System:_update(deltaTime: number)
	self._frameCount = self._frameCount + 1

	-- Update sound manager cleanup expired sounds
	self.soundManager:update()

	-- Update player sound emitters
	for player, emitter in pairs(self.playerEmitters) do
		if player.Parent then -- Check if player still in game
			emitter:update(deltaTime)
		end
	end

	-- Update NPCs with load balancing
	local npcsToUpdate = math.min(
		Config.PERFORMANCE.MAX_NPCS_PER_UPDATE,
		#self.npcControllers
	)

	for i = 1, npcsToUpdate do
		local index = ((self._npcUpdateIndex - 1) % #self.npcControllers) + 1
		local controller = self.npcControllers[index]

		if controller then
			controller:update(deltaTime)
		end

		self._npcUpdateIndex = self._npcUpdateIndex + 1
	end

	-- Performance logging
	if Config.DEBUG.ENABLED and self._frameCount % 50 == 0 then
		print(string.format(
			"[SoundAI] Active sounds: %d | NPCs: %d | Players: %d",
			self.soundManager._soundCount,
			#self.npcControllers,
			#Players:GetPlayers()
			))
	end
end

-- Get the sound manager instance
function System:getSoundManager()
	return self.soundManager
end

-- Manually emit a sound
function System:emitSound(position: Vector3, soundType: string, velocity: number, emitter: Instance?)
	if self.soundManager then
		return self.soundManager:emitSound(position, soundType, velocity, emitter)
	end
end

-- Get player emitter
function System:getPlayerEmitter(player: Player)
	return self.playerEmitters[player]
end

-- CLEANUP
function System:shutdown()
	print("[SoundAI] Shutting down system...")

	-- Destroy all NPCs
	for _, controller in ipairs(self.npcControllers) do
		controller:destroy()
	end

	-- Destroy all player emitters
	for _, emitter in pairs(self.playerEmitters) do
		emitter:destroy()
	end

	-- Destroy sound manager
	if self.soundManager then
		self.soundManager:destroy()
	end

	table.clear(self.npcControllers)
	table.clear(self.playerEmitters)

	print("[SoundAI] System shut down")
end

-- AUTO-START
System:initialize()

-- Make system global for access
_G.SoundAISystem = System

return System
