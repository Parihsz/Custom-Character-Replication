--!nonstrict
local ServerScriptService = game:GetService("ServerScriptService")

for _, moduleScript in ServerScriptService.Services:GetDescendants() do
	if moduleScript:IsA("ModuleScript") then
		local yielded = true
		local success
		local message

		task.spawn(function()
			success, message = pcall(function()
				require(moduleScript)
			end)

			yielded = false
		end)

		if success == false then
			error(`{moduleScript:GetFullName()}: {message}`)
		end

		if yielded then
			warn("Yielded while requiring" .. moduleScript:GetFullName())
		end
	end
end

print("Server loaded.")
