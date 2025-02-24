return table.freeze({
	MIN_BUFFER = 0.02,
	MAX_BUFFER = 0.06,
	TICK_RATE = 1 / 20,

	PROXIMITY = 100,
	INTERPOLATION_SPEED = 1,
	ERROR_SNAP_THRESHOLD = 5,

	DEBUG_MODE = true,

	PING_MULTIPLIER = 1.0,
	RENDER_LERP_FACTOR = 15,
	SMOOTHING_CONSTANT = 10,
	TIME_SYNC_INTERVAL = 10,

	ENABLE_CUSTOM_CHARACTERS = false, -- this will disable default roblox replication as well.
	DISABLE_DEFAULT_REPLICATION = false, -- this is if you want to disable the default roblox replication, but still use their controller
})
