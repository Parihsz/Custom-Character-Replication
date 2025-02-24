local Players = game:GetService("Players")
return function(player: Player): { Model: Model }
	local rig = {}
	local userId = 1242803262

	local humanoidDescription = Players:GetHumanoidDescriptionFromUserId(userId)
	local model = Players:CreateHumanoidModelFromDescription(humanoidDescription, Enum.HumanoidRigType.R15)
	model.Parent = workspace

	rig.Model = model

	return rig
end
