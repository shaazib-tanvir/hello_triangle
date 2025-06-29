package graphics

import "core:reflect"
import vk "vendor:vulkan"

create_render_pass :: proc(device: vk.Device) -> (render_pass: vk.RenderPass, result: vk.Result) {
	attachment := vk.AttachmentDescription{
		format = .B8G8R8A8_SRGB,
		samples = {._1},
		loadOp = .CLEAR,
		storeOp = .STORE,
		stencilLoadOp = .DONT_CARE,
		stencilStoreOp = .DONT_CARE,
		initialLayout = .UNDEFINED,
		finalLayout = .PRESENT_SRC_KHR,
	}

	attachment_ref := vk.AttachmentReference{
		attachment = 0,
		layout = .COLOR_ATTACHMENT_OPTIMAL
	}

	subpass := vk.SubpassDescription{
		pipelineBindPoint = .GRAPHICS,
		colorAttachmentCount = 1,
		pColorAttachments = &attachment_ref,
	}

	subpass_dependency := vk.SubpassDependency{
		srcSubpass = vk.SUBPASS_EXTERNAL,
		dstSubpass = 0,
		srcStageMask = {.COLOR_ATTACHMENT_OUTPUT},
		srcAccessMask = {},
		dstStageMask = {.COLOR_ATTACHMENT_OUTPUT},
		dstAccessMask = {.COLOR_ATTACHMENT_WRITE}
	}

	render_pass_create_info := vk.RenderPassCreateInfo{
		sType = .RENDER_PASS_CREATE_INFO,
		attachmentCount = 1,
		pAttachments = &attachment,
		subpassCount = 1,
		pSubpasses = &subpass,
		dependencyCount = 1,
		pDependencies = &subpass_dependency
	}

	vk.CreateRenderPass(device, &render_pass_create_info, nil, &render_pass) or_return
	return render_pass, .SUCCESS
}

create_pipeline_layout :: proc(device: vk.Device) -> (layout: vk.PipelineLayout, result: vk.Result) {
	layout_create_info := vk.PipelineLayoutCreateInfo{
		sType = .PIPELINE_LAYOUT_CREATE_INFO,
	}

	vk.CreatePipelineLayout(device, &layout_create_info, nil, &layout) or_return
	return layout, .SUCCESS
}

get_vertex_attribute_descriptions :: proc(vertices: []Vertex) -> []vk.VertexInputAttributeDescription {
	attributes := make([]vk.VertexInputAttributeDescription, reflect.struct_field_count(Vertex))
	assert(reflect.struct_field_count(Vertex) != 0)
	for i in 0..<reflect.struct_field_count(Vertex) {
		attributes[i] = vk.VertexInputAttributeDescription{
			location = u32(i),
			binding = 0,
			format = .R32G32B32_SFLOAT,
			offset = u32(reflect.struct_field_at(Vertex, i).offset),
		}
	}

	return attributes
}

create_pipeline :: proc(device: vk.Device, fragment_module: vk.ShaderModule, vertex_module: vk.ShaderModule, render_pass: vk.RenderPass, layout: vk.PipelineLayout, vertices: []Vertex) -> (pipeline: vk.Pipeline, result: vk.Result) {
	defer vk.DestroyShaderModule(device, vertex_module, nil)
	defer vk.DestroyShaderModule(device, fragment_module, nil)

	fragment_info := get_shader_stage_create_info(device, fragment_module, .FRAGMENT)
	vertex_info := get_shader_stage_create_info(device, vertex_module, .VERTEX)
	stages := []vk.PipelineShaderStageCreateInfo{vertex_info, fragment_info}

	vertex_binding_description := vk.VertexInputBindingDescription{
		binding = 0,
		stride = size_of(Vertex),
		inputRate = .VERTEX
	}

	attribute_descriptions := get_vertex_attribute_descriptions(vertices[:])
	defer delete(attribute_descriptions)

	vertex_input_state_create_info := vk.PipelineVertexInputStateCreateInfo{
		sType = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
		vertexBindingDescriptionCount = 1,
		pVertexBindingDescriptions = &vertex_binding_description,
		vertexAttributeDescriptionCount = u32(len(attribute_descriptions)),
		pVertexAttributeDescriptions = raw_data(attribute_descriptions)
	}

	pipeline_input_assembly_state_create_info := vk.PipelineInputAssemblyStateCreateInfo{
		sType = .PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
		topology = .TRIANGLE_LIST
	}

	dynamic_states := []vk.DynamicState{.VIEWPORT, .SCISSOR}
	dynamic_state_create_info := vk.PipelineDynamicStateCreateInfo{
		sType = .PIPELINE_DYNAMIC_STATE_CREATE_INFO,
		dynamicStateCount = u32(len(dynamic_states)),
		pDynamicStates = raw_data(dynamic_states)
	}

	viewport_state_create_info := vk.PipelineViewportStateCreateInfo{
		sType = .PIPELINE_VIEWPORT_STATE_CREATE_INFO,
		viewportCount = 1,
		scissorCount = 1,
	}

	rasterizer_create_info := vk.PipelineRasterizationStateCreateInfo{
		sType = .PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
		depthClampEnable = b32(false),
		polygonMode = .FILL,
		cullMode = {.BACK},
		frontFace = .COUNTER_CLOCKWISE,
		depthBiasEnable = b32(false),
		lineWidth = 1.
	}

	multisample_create_info := vk.PipelineMultisampleStateCreateInfo{
		sType = .PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
		rasterizationSamples = {._1},
		sampleShadingEnable = b32(false),
		minSampleShading = 1.,
		pSampleMask = nil,
		alphaToCoverageEnable = b32(false),
		alphaToOneEnable = b32(false),
	}

	colorblend_attachment_state := vk.PipelineColorBlendAttachmentState{
		blendEnable = b32(false),
		colorWriteMask = {.R, .G, .B, .A}
	}

	colorblend_create_info := vk.PipelineColorBlendStateCreateInfo{
		sType = .PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
		logicOpEnable = b32(false),
		logicOp = .COPY,
		attachmentCount = 1,
		pAttachments = &colorblend_attachment_state
	}

	graphics_pipeline_create_info := vk.GraphicsPipelineCreateInfo{
		sType = .GRAPHICS_PIPELINE_CREATE_INFO,
		stageCount = u32(len(stages)),
		pStages = raw_data(stages),
		pVertexInputState = &vertex_input_state_create_info,
		pInputAssemblyState = &pipeline_input_assembly_state_create_info,
		pRasterizationState = &rasterizer_create_info,
		pDynamicState = &dynamic_state_create_info,
		pMultisampleState = &multisample_create_info,
		pViewportState = &viewport_state_create_info,
		pColorBlendState = &colorblend_create_info,
		layout = layout,
		renderPass = render_pass,
		subpass = 0,
		basePipelineHandle = vk.Pipeline{},
		basePipelineIndex = -1
	}

	vk.CreateGraphicsPipelines(device, 0, 1, &graphics_pipeline_create_info, nil, &pipeline) or_return
	return pipeline, .SUCCESS
}
