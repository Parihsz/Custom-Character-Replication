local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Config = require(ReplicatedStorage.Shared.config)
local Snapshots = require(ReplicatedStorage.Shared.snapshots)
local Grid = require(ReplicatedStorage.Shared.grid)
local Events = require(ReplicatedStorage.Events.server)
local Rig = require(ReplicatedStorage.Shared.rigs.createCharacter)

local Networkables = require(ReplicatedStorage.Shared.makeNetworkable)

local Replication = {}

local playerIdMap = {} :: { [Player]: number }
local idMap = {} :: { [number]: {
	player: Player,
	snapshot: Snapshots.SnapshotInstance,
	clientLastTick: number?,
} }
local lastReplicatedTimes = {} :: { [number]: number }
local replicators = {} :: { [number]: Model }

local MAX_ID = 255
local IncrementalFactoryUID = 0

local function GetNextID(): number
	--for reference, we are using u8s for now.
	if IncrementalFactoryUID + 1 == MAX_ID then
		error("Max ID reached, please investigate.")
	end
	IncrementalFactoryUID += 1

	return IncrementalFactoryUID
end

local function OnCharacterAdded(player: Player, character: Model, id: number)
	local humanoidRootPart = character:FindFirstChild("HumanoidRootPart") :: BasePart

	if Config.ENABLE_CUSTOM_CHARACTERS or Config.DISABLE_DEFAULT_REPLICATION then
		if humanoidRootPart then
			humanoidRootPart:SetNetworkOwner(player)
			humanoidRootPart.Anchored = true
		end
	end

	if Config.DISABLE_DEFAULT_REPLICATION then
		local clone = Rig(player)
		clone.Model.Parent = workspace.CurrentCamera

		replicators[id] = clone.Model
	end

	if Config.ENABLE_CUSTOM_CHARACTERS then
		character.Parent = workspace.CurrentCamera
	end

	Grid.AddEntity(character, "player")
	Events.InitializePlayer.FireAll({
		id = id,
		player = player.Name,
	})
end

local function OnCharacterRemoving(character: Model)
	Grid.RemoveEntity(character)
end

local function InitExistingPlayers(player: Player)
	local playerData = {}

	for existingPlayer, _ in playerIdMap do
		if existingPlayer == player then
			continue
		end

		table.insert(playerData, {
			id = playerIdMap[existingPlayer],
			player = existingPlayer.Name,
		})
	end

	if #playerData == 0 then
		warn("No existing players found to initialize for player", player)
		return
	end

	Events.InitializeExistingPlayers.Fire(player, playerData)
end

Players.PlayerAdded:Connect(function(player: Player)
	local id = GetNextID()
	playerIdMap[player] = id
	idMap[id] = {
		player = player,
		snapshot = Snapshots.RegisterPlayer(player),
		clientLastTick = nil,
	}
	lastReplicatedTimes[id] = 0

	InitExistingPlayers(player)

	player.CharacterAdded:Connect(function(character)
		OnCharacterAdded(player, character, id)
	end)
	player.CharacterRemoving:Connect(OnCharacterRemoving)
end)

Players.PlayerRemoving:Connect(function(player)
	local id = playerIdMap[player]
	if id then
		idMap[id] = nil
		lastReplicatedTimes[id] = nil
		playerIdMap[player] = nil
	end
end)

Events.ClientReplicateCFrame.On(function(player, clientData)
	local newCFrame = Networkables.DecodeCFrame(clientData.cframe)

	local id = playerIdMap[player]
	local data = idMap[id]
	if not data then
		return
	end

	data.clientLastTick = clientData.timeStamp
	data.snapshot:PushAt(clientData.timeStamp, newCFrame)
end)

local function UpdateTick(id: number, tickRate: number)
	Events.TickRateChanged.FireAll({
		id = id,
		tickRate = tickRate,
	})
end

local function GetTickInterval(character: Model, id: number): number
	local baseTick = Config.TICK_RATE
	if not character then
		return baseTick
	end

	local nearbyPlayers = Grid.GetNearbyEntities(character, Config.PROXIMITY, { "player" })

	local newTickRate = if #nearbyPlayers > 1 then baseTick else baseTick * 2

	if lastReplicatedTimes[id] ~= newTickRate then
		UpdateTick(id, newTickRate)
	end

	return newTickRate
end

RunService.PostSimulation:Connect(function(deltaTime)
	local currentTime = Networkables.EncodeTime(workspace:GetServerTimeNow())
	Grid.UpdateGrid()

	local cframes = {}
	local lastTicks = {}

	for id, data in idMap do
		local character = data.player.Character
		if not character then
			continue
		end
		local tickInterval = GetTickInterval(character, id)
		if currentTime - lastReplicatedTimes[id] < tickInterval then
			continue
		end
		lastReplicatedTimes[id] = currentTime

		local latestSnapshot = data.snapshot:GetLatest()
		if latestSnapshot then
			cframes[id] = latestSnapshot.cFrame
		else
			cframes[id] = (character.PrimaryPart :: any).CFrame --yeah... getpivot is just way too slow
		end

		lastTicks[id] = if idMap[id].clientLastTick
			then idMap[id].clientLastTick :: any
			else Networkables.EncodeTime(workspace:GetServerTimeNow())
	end

	if next(cframes) then
		Events.ServerReplicateCFrame.FireAll({
			--using helper function that converts an entire table of cframes to networkable form
			cframes = Networkables.NetworkableCFrameTable(cframes),
			timeStamps = lastTicks,
		})
	end

	if not Config.DISABLE_DEFAULT_REPLICATION then
		return
	end

	--Since we disabled roblox replication, we won't be able to easily do collision detections on the server
	--This module has each player be represented as a dummy parented to the camera (will not replicate)
	--and i simply bulkmoveto them to the latest character cframe
	local staged = {}
	local targets = {}
	for id, clone in replicators do
		local data = idMap[id]
		if data and data.snapshot and clone.PrimaryPart then
			local latestSnapshot = data.snapshot:GetLatest()

			if latestSnapshot then
				table.insert(staged, clone.PrimaryPart)
				table.insert(targets, latestSnapshot.cFrame)
			end
		end
	end

	if #staged > 0 then
		workspace:BulkMoveTo(staged, targets)
	end
end)

--Exposes a function for other scripts to get the most up to date cframe of a player
--for my personal usecase, I am using it to bypass the physics buffer for hitbox calculation
function Replication.GetLatestCFrame(player: Player): CFrame?
	local id = playerIdMap[player]
	if not id then
		return nil
	end

	local data = idMap[id]
	if not data then
		return nil
	end

	local latestSnapshot = data.snapshot:GetLatest()
	if latestSnapshot then
		return latestSnapshot.cFrame
	end

	return nil
end

return Replication
