local Snapshot = {}

export type SnapshotData = {
	timeStamp: number,
	cFrame: CFrame,
}

export type SnapshotInstance = {
	cache: { SnapshotData },
	PushAt: (self: SnapshotInstance, timeStamp: number, cFrame: CFrame) -> (),
	GetBefore: (self: SnapshotInstance, timeStamp: number) -> SnapshotData?,
	GetAfter: (self: SnapshotInstance, timeStamp: number) -> SnapshotData?,
	GetAt: (self: SnapshotInstance, timeStamp: number) -> CFrame?,
	GetLatest: (self: SnapshotInstance) -> SnapshotData?,
	RemoveOld: (self: SnapshotInstance, cutoffTime: number) -> (),
	Destroy: (self: SnapshotInstance) -> (),
	Subject: Player?,
}

local MAX_LENGTH = 10
local SnapshotInstances: { [Player]: SnapshotInstance } = {}

local function BinarySearch(cache: { SnapshotData }, timeStamp: number): number
	local low, high = 1, #cache
	while low <= high do
		local mid = (low + high) // 2
		if cache[mid].timeStamp < timeStamp then
			low = mid + 1
		else
			high = mid - 1
		end
	end
	return low
end

local function PushAt(self: SnapshotInstance, timeStamp: number, cFrame: CFrame): ()
	local cache = self.cache
	local index = BinarySearch(cache, timeStamp)
	table.insert(cache, index, { timeStamp = timeStamp, cFrame = cFrame })

	if #cache > MAX_LENGTH then
		table.remove(cache, 1)
	end
end

local function GetBefore(self: SnapshotInstance, timeStamp: number): SnapshotData?
	local cache = self.cache
	local index = BinarySearch(cache, timeStamp) - 1
	if index >= 1 then
		return cache[index]
	end
	return nil
end

local function GetAfter(self: SnapshotInstance, timeStamp: number): SnapshotData?
	local cache = self.cache
	local index = BinarySearch(cache, timeStamp)
	if index <= #cache then
		return cache[index]
	end
	return nil
end

local function GetAt(self: SnapshotInstance, timeStamp: number, currentCFrame: CFrame?): CFrame?
	local cache = self.cache
	if #cache == 0 then
		return nil
	end
	if #cache == 1 then
		return cache[1].cFrame
	end

	local before = self:GetBefore(timeStamp)
	local after = self:GetAfter(timeStamp)

	if before and after then
		local alpha = (timeStamp - before.timeStamp) / (after.timeStamp - before.timeStamp)
		return before.cFrame:Lerp(after.cFrame, alpha)
	elseif before then
		return before.cFrame
	elseif after then
		if currentCFrame then
			local alpha = timeStamp / after.timeStamp
			return currentCFrame:Lerp(after.cFrame, alpha)
		end
		return after.cFrame
	end

	return nil
end

local function GetLatest(self: SnapshotInstance): SnapshotData?
	local cache = self.cache
	if #cache > 0 then
		return cache[#cache]
	end
	return nil
end

local function RemoveOld(self: SnapshotInstance, cutoffTime: number): ()
	local cache = self.cache
	while #cache > 0 and cache[1].timeStamp < cutoffTime do
		table.remove(cache, 1)
	end
end

function Snapshot.new(subject: Player): SnapshotInstance
	local cache: { SnapshotData } = {}

	local function Destroy(): ()
		table.clear(cache)
	end

	return {
		cache = cache,
		PushAt = PushAt,
		GetBefore = GetBefore,
		GetAfter = GetAfter,
		GetAt = GetAt,
		GetLatest = GetLatest,
		RemoveOld = RemoveOld,
		Destroy = Destroy,
		Subject = subject,
	}
end

function Snapshot.RegisterPlayer(player: Player): SnapshotInstance
	if not SnapshotInstances[player] then
		SnapshotInstances[player] = Snapshot.new(player)
	end
	return SnapshotInstances[player]
end

function Snapshot.DeregisterPlayer(player: Player): ()
	local snapshot = SnapshotInstances[player]
	if snapshot then
		snapshot:Destroy()
		SnapshotInstances[player] = nil
	end
end

function Snapshot.GetSnapshotInstance(player: Player): SnapshotInstance
	return SnapshotInstances[player] or Snapshot.RegisterPlayer(player)
end

return Snapshot
