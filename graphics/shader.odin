package graphics

import vk "vendor:vulkan"

create_shader_module :: proc(device: vk.Device, code: []u32) -> (module: vk.ShaderModule, result: vk.Result) {
	shader_module_create_info := vk.ShaderModuleCreateInfo{
		sType = .SHADER_MODULE_CREATE_INFO,
		codeSize = size_of(u32) * len(code),
		pCode = raw_data(code)
	}

	vk.CreateShaderModule(device, &shader_module_create_info, nil, &module) or_return
	return module, .SUCCESS
}

get_shader_stage_create_info :: proc(device: vk.Device, module: vk.ShaderModule, stage: vk.ShaderStageFlag) -> vk.PipelineShaderStageCreateInfo {
	shader_stage_create_info := vk.PipelineShaderStageCreateInfo{
		sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
		stage = {stage},
		module = module,
		pName = "main"
	}

	return shader_stage_create_info
}
