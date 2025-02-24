local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local shared = script.Parent.Parent.shared

local Config = require(shared.config)
local Snapshots = require(shared.snapshots)
local ClientRig = require(shared.rigs.createCharacter)
local Networkables = require(shared.makeNetworkable)

local Events = require(script.Parent.events)
local InterpolationBuffer = require(script.Parent.interpolationBuffer)

local idMap = {} :: {
	[number]: {
		snapshot: Snapshots.SnapshotInstance,
		character: Model,
		lastCFrame: CFrame?,
	},
}

local player = Players.LocalPlayer
local lerp = (math :: any).lerp
local initializedPlayers = {} :: { [Player]: boolean }
local characters = {} :: { [Player]: Model }
local playerTickRates = {} :: { [number]: number }

local playerRenderTimes = {} :: { [number]: number }
local bufferTracker = InterpolationBuffer(Config.MIN_BUFFER, Config.MAX_BUFFER, 0.1)

local networkedCFrame = nil
local playerNetworkId = 300

Events.TickRateChanged.On(function(data)
	playerTickRates[data.id] = data.tickRate
end)

Events.ServerReplicateCFrame.On(function(serverData)
	local clientLastTicks = serverData.timeStamps
	for id, serverTime in clientLastTicks do
		bufferTracker.RegisterPacket(id, serverTime)
	end

	local cframes = serverData.cframes
	local snapshotTime = workspace:GetServerTimeNow()

	for id, cframe in cframes do
		local entry = idMap[id]
		if not entry then
			continue
		end
		--since CFrames are received in the networkable format, I have to decode it to be actual cframes. It is nicely done because of the roblox cframe.new overload for quaternions.
		--same applies on the server as well of course.
		entry.snapshot:PushAt(snapshotTime, Networkables.DecodeCFrame(cframe))
	end
end)

local function PlayerAdded(player: Player, id: number)
	if initializedPlayers[player] then
		warn("Player already initialized", player)
		return
	end

	if player == Players.LocalPlayer then
		playerNetworkId = id
	end

	initializedPlayers[player] = true

	local registeredSnapshots = Snapshots.RegisterPlayer(player)

	local initialRenderTime = workspace:GetServerTimeNow()
		- bufferTracker.GetBuffer(id, playerTickRates[id] or Config.TICK_RATE)

	--custom characters will be - server rig parented to camera (not physically simulated) and a client rig, that is physically simulated
	--if not, we just unanchor on the client (since it might be anchored on the server)
	if Config.ENABLE_CUSTOM_CHARACTERS then
		characters[player] = ClientRig(player).Model

		if player == Players.LocalPlayer then
			player.Character = characters[player];
			(workspace.CurrentCamera :: any).CameraSubject = characters[player]
		end
	else
		local character = player.Character or player.CharacterAdded:Wait()
		local humanoidRootPart = character:WaitForChild("HumanoidRootPart") :: BasePart
		humanoidRootPart.Anchored = false
		characters[player] = character
	end

	local initialCFrame = CFrame.new(0, 4, 0)

	if characters[player] and characters[player].PrimaryPart then
		initialCFrame = (characters[player] :: any).PrimaryPart.CFrame
	end

	registeredSnapshots:PushAt(initialRenderTime, initialCFrame)

	idMap[id] = {
		snapshot = registeredSnapshots,
		character = characters[player],
		lastCFrame = initialCFrame,
	}
	playerRenderTimes[id] = initialRenderTime

	networkedCFrame = Networkables.MakeNetworkable(initialCFrame)

	local character = characters[player]

	if not character then
		return
	end

	local humanoid = character:WaitForChild("Humanoid") :: Humanoid

	humanoid.Died:Connect(function()
		initializedPlayers[player] = nil
	end)
end

Events.InitializePlayer.On(function(data)
	local playerInstance = Players[data.player]

	if playerInstance then
		PlayerAdded(playerInstance, data.id)
	end
end)

Events.InitializeExistingPlayers.On(function(data)
	for _, playerData in data do
		local playerInstance = Players[playerData.player]

		if playerInstance then
			PlayerAdded(playerInstance, playerData.id)
		end
	end
end)

local lastSent = os.clock()
local lastSentCFrame = CFrame.new()

RunService.PreRender:Connect(function(deltaTime: number)
	--GetServerTimeNow() is really nice, because it accounts for the RTT and can serve as the game world's timestamp.
	--The target render time is what we will be aiming for - by retrieving the dynamic interpolation buffer and subtracting it, we can pretty accurately reflect the actual state at the world timestamp.
	local globalServerTime = workspace:GetServerTimeNow()

	for id, data in idMap do
		if not data.character or not data.character.PrimaryPart or data.character == player.Character then
			continue
		end

		--GetBuffer returns the interpolation buffer, which is the length of the buffer + your latency. The latency is the remote latency, but the buffer time itself accounts for the varying latency, packet loss, delayed packets - and smooths it out.
		--snapshot timestamps are attached by the server, and the interpolation actually needs to start it from where the client receives it
		--tldr, GetBuffer will by minimum return GetServerTimeNow() - latency in a perfect world scenario
		--in a game with network variations, the formula becomes GetServerTimeNow() - (latency + deviationMargin + recoveryMargin)

		local targetRenderTime = globalServerTime - bufferTracker.GetBuffer(id, playerTickRates[id] or Config.TICK_RATE)
		local renderTimeLerpFactor = math.clamp(deltaTime * Config.RENDER_LERP_FACTOR, 0, 1)

		--get the entity snapshot at the new render time - a smoothly interpolated value between the current and target render time.
		--warning: having a too high lerp factor may increase the "interpolation buffer" - experiment with lower values / directly setting the render time.
		--snapshots library internalls holds historical data to interpolate smoothly and avoid jitter.
		--further logic is an implementation detail.
		local currentRenderTime = playerRenderTimes[id] or targetRenderTime
		local newRenderTime = lerp(currentRenderTime, targetRenderTime, renderTimeLerpFactor)
		playerRenderTimes[id] = newRenderTime

		local targetCFrame = data.snapshot:GetAt(newRenderTime)
		if targetCFrame then
			if not data.lastCFrame then
				data.lastCFrame = targetCFrame
			else
				local smoothFactor = math.clamp(deltaTime * Config.SMOOTHING_CONSTANT, 0, 1)
				data.lastCFrame = data.lastCFrame:Lerp(targetCFrame, smoothFactor)
			end
			data.character.PrimaryPart.CFrame = data.lastCFrame :: any
		end
	end
end)

RunService.PostSimulation:Connect(function()
	if os.clock() - lastSent < (playerTickRates[playerNetworkId] or Config.TICK_RATE) then
		return
	end
	lastSent = os.clock()

	if player.Character and player.Character.PrimaryPart then
		local currentCFrame = player.Character.PrimaryPart.CFrame
		--if player did not move, don't network the change.
		--CFrames need to be made networkable. I am currently sending them as position: Vector3, rotation: {x, y, z} (omitting w because it can be calculated by x,y,z)
		--this allows for much nicer compression since I am using quaternions
		local networkable = Networkables.MakeNetworkable(currentCFrame)

		if vector.magnitude(networkable.Position :: any) < 0.1 then
			return
		end

		lastSentCFrame = currentCFrame
		Events.ClientReplicateCFrame.Fire({
			timeStamp = workspace:GetServerTimeNow(),
			cframe = networkable,
		})
	end
end)

return {}
