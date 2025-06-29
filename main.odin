package main

import "base:runtime"
import "core:math/linalg"
import "core:log"
import "core:fmt"
import "core:reflect"
import "core:mem"
import "core:slice"
import "core:strings"
import "core:math/bits"
import "core:container/priority_queue"
import "vendor:glfw"
import vk "vendor:vulkan"
import "graphics"

g_context: runtime.Context

error_callback :: proc "c" (error: i32, description: cstring) {
	context = g_context
	log.error("number", error, "\n", description)
}

get_layers :: proc () -> []vk.LayerProperties {
	propertyCount : u32
	if result := vk.EnumerateInstanceLayerProperties(&propertyCount, nil); result != .SUCCESS {
		log.warn("unable to query layer properties", result)
		return make([]vk.LayerProperties, 0)
	}
	layerProperties := make([]vk.LayerProperties, propertyCount)
	if result := vk.EnumerateInstanceLayerProperties(&propertyCount, raw_data(layerProperties)); result != .SUCCESS {
		log.warn("unable to query layer properties", result)
		return make([]vk.LayerProperties, 0)
	}
	return layerProperties
}

get_validation_layers :: proc() -> [dynamic]cstring {
	validation_layers: = make([dynamic]cstring, 0, 0)
	when ODIN_DEBUG {
		validation_layer_names := []cstring{"VK_LAYER_KHRONOS_validation"}
		available_layers := get_layers()
		defer delete(available_layers)

		for validation_layer_name in validation_layer_names {
			found := false
			for layer in available_layers {
				layerName := layer.layerName
				if validation_layer_name == cstring(raw_data(layerName[:])) {
					append(&validation_layers, validation_layer_name)
					found = true
					break
				}
			}

			if !found {
				log.warn(validation_layer_name, "is not available")
			}
		}
	}

	return validation_layers
}

debug_callback :: proc "c" (severity: vk.DebugUtilsMessageSeverityFlagsEXT, types: vk.DebugUtilsMessageTypeFlagsEXT, callback_data: ^vk.DebugUtilsMessengerCallbackDataEXT, user_data: rawptr) -> b32 {
	context = g_context

	level: log.Level
	if .ERROR in severity {
		level = .Error
	} else if .WARNING in severity {
		level = .Warning
	} else if .INFO in severity {
		level = .Info
	} else {
		level = .Debug
	}

	log.logf(level, "vulkan[%v]: %s", types, callback_data.pMessage)
	return false
}

get_instance_extensions :: proc() -> [dynamic]cstring {
	extensions := slice.clone_to_dynamic(glfw.GetRequiredInstanceExtensions())
	when ODIN_DEBUG {
		append(&extensions, vk.EXT_DEBUG_UTILS_EXTENSION_NAME)
	}

	return extensions
}

get_device_extensions :: proc() -> [dynamic]cstring {
	extensions := make([dynamic]cstring, 0)
	append(&extensions, vk.KHR_SWAPCHAIN_EXTENSION_NAME)
	return extensions
}

create_instance :: proc (window: glfw.WindowHandle, validation_layers: []cstring) -> (instance: vk.Instance, result: vk.Result) {
	app_info: vk.ApplicationInfo = vk.ApplicationInfo{
		sType = .APPLICATION_INFO,
		pApplicationName = "Vulkan Triangle",
		applicationVersion = vk.MAKE_VERSION(1, 0, 0),
		pEngineName = "No Engine",
		engineVersion = vk.MAKE_VERSION(1, 0, 0),
		apiVersion = vk.API_VERSION_1_0
	}

	extensions := get_instance_extensions()
	defer delete(extensions)

	create_info: vk.InstanceCreateInfo = vk.InstanceCreateInfo{
		sType = .INSTANCE_CREATE_INFO,
		pApplicationInfo = &app_info,
		enabledExtensionCount = u32(len(extensions)),
		ppEnabledExtensionNames = raw_data(extensions),
		ppEnabledLayerNames = raw_data(validation_layers),
		enabledLayerCount = u32(len(validation_layers)),
	}

	when ODIN_DEBUG {
		debug_create_info: vk.DebugUtilsMessengerCreateInfoEXT = vk.DebugUtilsMessengerCreateInfoEXT{
			sType = .DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT,
			pNext = nil,
			pfnUserCallback = debug_callback,
			messageSeverity = {.VERBOSE, .INFO, .WARNING, .ERROR},
			messageType = {.GENERAL, .VALIDATION, .PERFORMANCE}
		}
		create_info.pNext = &debug_create_info
	}

	vk.CreateInstance(&create_info, nil, &instance) or_return

	return instance, .SUCCESS
}

create_debug_messenger :: proc(instance: vk.Instance) -> (messenger: vk.DebugUtilsMessengerEXT, result: vk.Result) {
	debug_create_info: vk.DebugUtilsMessengerCreateInfoEXT = vk.DebugUtilsMessengerCreateInfoEXT{
		sType = .DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT,
		pNext = nil,
		pfnUserCallback = debug_callback,
		messageSeverity = {.VERBOSE, .INFO, .WARNING, .ERROR},
		messageType = {.GENERAL, .VALIDATION, .PERFORMANCE}
	}

	vk.CreateDebugUtilsMessengerEXT(instance, &debug_create_info, nil, &messenger) or_return

	return messenger, .SUCCESS
}

supports_queue_families :: proc(physical_device: vk.PhysicalDevice, surface: vk.SurfaceKHR) -> (graphics_queue_family: u32, surface_queue_family: u32, ok: bool) {
	property_count: u32
	vk.GetPhysicalDeviceQueueFamilyProperties(physical_device, &property_count, nil)
	properties_slice := make([]vk.QueueFamilyProperties, property_count)
	defer delete(properties_slice)
	vk.GetPhysicalDeviceQueueFamilyProperties(physical_device, &property_count, raw_data(properties_slice))

	graphics_queue_family = 0
	surface_queue_family = 0

	graphics_family_found := false
	for !graphics_family_found {
		properties := properties_slice[graphics_queue_family]
		if .GRAPHICS in properties.queueFlags {
			graphics_family_found = true
		} else {
			graphics_queue_family += 1
		}
	}

	surface_family_found := false
	for !surface_family_found {
		properties := properties_slice[surface_queue_family]

		supported: b32
		if result := vk.GetPhysicalDeviceSurfaceSupportKHR(physical_device, surface_queue_family, surface, &supported); result != .SUCCESS {
			log.warn("physical device support check failed on queue family", surface_queue_family, "got result", result)
			continue
		}
		if supported {
			surface_family_found = true
		} else {
			surface_queue_family += 1
		}
	}

	return graphics_queue_family, surface_queue_family, graphics_family_found && surface_family_found
}

rate_device :: proc(physical_device: vk.PhysicalDevice) -> int {
	rating := 0
	device_properties: vk.PhysicalDeviceProperties
	device_features: vk.PhysicalDeviceFeatures
	vk.GetPhysicalDeviceFeatures(physical_device, &device_features)
	vk.GetPhysicalDeviceProperties(physical_device, &device_properties)
	rating += int(device_properties.deviceType == .DISCRETE_GPU)
	rating += int(device_features.geometryShader)
	rating += int(device_features.tessellationShader)
	return rating
}

is_device_suitable :: proc(physical_device: vk.PhysicalDevice, surface: vk.SurfaceKHR) -> bool {
	device_features: vk.PhysicalDeviceFeatures
	vk.GetPhysicalDeviceFeatures(physical_device, &device_features)
	supports_queue_families(physical_device, surface) or_return
	surface_details, surface_details_result := get_surface_details(physical_device, surface)
	defer destroy_surface_details(&surface_details)
	if surface_details_result != .SUCCESS {
		log.warn("failed to query surface details", surface_details_result)
		return false
	}

	return bool(device_features.geometryShader) && len(surface_details.present_modes) != 0 && len(surface_details.surface_formats) != 0
}

device_rating_less :: proc(a: vk.PhysicalDevice, b: vk.PhysicalDevice) -> bool {
	return rate_device(b) < rate_device(a)
}

InternalPhysicalDeviceResult :: enum {
	SUCCESS,
	NO_PHYSICAL_DEVICE_FOUND
}

PhysicalDeviceResult :: union #shared_nil {
	vk.Result,
	InternalPhysicalDeviceResult
}

get_physical_device :: proc(instance: vk.Instance, surface: vk.SurfaceKHR) -> (physical_device: vk.PhysicalDevice, result: PhysicalDeviceResult) {
	physical_device_count: u32
	vk.EnumeratePhysicalDevices(instance, &physical_device_count, nil) or_return
	physical_devices := make([]vk.PhysicalDevice, physical_device_count)
	defer delete(physical_devices)
	vk.EnumeratePhysicalDevices(instance, &physical_device_count, raw_data(physical_devices)) or_return
	if len(physical_devices) == 0 {
		return physical_device, .NO_PHYSICAL_DEVICE_FOUND
	}

	device_queue: priority_queue.Priority_Queue(vk.PhysicalDevice)
	priority_queue.init(&device_queue, device_rating_less, priority_queue.default_swap_proc(vk.PhysicalDevice))
	defer priority_queue.destroy(&device_queue)

	for physical_device in physical_devices {
		if is_device_suitable(physical_device, surface) {
			priority_queue.push(&device_queue, physical_device)
		}
	}

	if priority_queue.len(device_queue) == 0 {
		return physical_device, .NO_PHYSICAL_DEVICE_FOUND
	}

	physical_device = priority_queue.peek(device_queue)
	return physical_device, nil
}

get_queue_family_indices :: proc(physical_device: vk.PhysicalDevice, surface: vk.SurfaceKHR) -> (indices: [dynamic]u32, result: InternalDeviceResult) {
	graphics_family_index, surface_family_index, ok := supports_queue_families(physical_device, surface)
	if !ok {
		return indices, .INVALID_PHYSICAL_DEVICE
	}

	queue_indices := []u32{graphics_family_index, surface_family_index}
	indices_slice := slice.unique(queue_indices)
	return slice.clone_to_dynamic(indices_slice), .SUCCESS
}

InternalDeviceResult :: enum {
	SUCCESS,
	INVALID_PHYSICAL_DEVICE
}

DeviceResult :: union #shared_nil {
	vk.Result,
	InternalDeviceResult
}

create_device :: proc(physical_device: vk.PhysicalDevice, surface: vk.SurfaceKHR) -> (device: vk.Device, result: DeviceResult) {
	unique_queue_indices := get_queue_family_indices(physical_device, surface) or_return
	defer delete(unique_queue_indices)

	queue_priority: f32 = 1.0
	queue_create_infos := make([]vk.DeviceQueueCreateInfo, len(unique_queue_indices))
	defer delete(queue_create_infos)

	for i in 0..<len(unique_queue_indices) {
		queue_create_infos[i] = vk.DeviceQueueCreateInfo{
			sType = .DEVICE_QUEUE_CREATE_INFO,
			pNext = nil,
			queueCount = 1,
			queueFamilyIndex = unique_queue_indices[i],
			pQueuePriorities = &queue_priority
		}
	}

	extensions := get_device_extensions()
	defer delete(extensions)

	device_create_info := vk.DeviceCreateInfo{
		sType = .DEVICE_CREATE_INFO,
		pNext = nil,
		queueCreateInfoCount = u32(len(queue_create_infos)),
		pQueueCreateInfos = raw_data(queue_create_infos),
		enabledExtensionCount = u32(len(extensions)),
		ppEnabledExtensionNames = raw_data(extensions),
		pEnabledFeatures = &vk.PhysicalDeviceFeatures{geometryShader = b32(true)}
	}

	vk.CreateDevice(physical_device, &device_create_info, nil, &device) or_return
	return device, nil
}

create_window_surface :: proc(instance: vk.Instance, window: glfw.WindowHandle) -> (surface: vk.SurfaceKHR, result: vk.Result) {
	glfw.CreateWindowSurface(instance, window, nil, &surface) or_return
	return surface, .SUCCESS
}

SurfaceDetails :: struct {
	capabilities: vk.SurfaceCapabilitiesKHR,
	present_modes: []vk.PresentModeKHR,
	surface_formats: []vk.SurfaceFormatKHR
}

get_surface_details :: proc(physical_device: vk.PhysicalDevice, surface: vk.SurfaceKHR) -> (surface_details: SurfaceDetails, result: vk.Result) {
	vk.GetPhysicalDeviceSurfaceCapabilitiesKHR(physical_device, surface, &surface_details.capabilities) or_return

	present_modes_count: u32
	vk.GetPhysicalDeviceSurfacePresentModesKHR(physical_device, surface, &present_modes_count, nil) or_return
	surface_details.present_modes = make([]vk.PresentModeKHR, present_modes_count)
	vk.GetPhysicalDeviceSurfacePresentModesKHR(physical_device, surface, &present_modes_count, raw_data(surface_details.present_modes)) or_return

	format_count: u32
	vk.GetPhysicalDeviceSurfaceFormatsKHR(physical_device, surface, &format_count, nil) or_return
	surface_details.surface_formats = make([]vk.SurfaceFormatKHR, format_count)
	vk.GetPhysicalDeviceSurfaceFormatsKHR(physical_device, surface, &format_count, raw_data(surface_details.surface_formats)) or_return

	return surface_details, .SUCCESS
}

destroy_surface_details :: proc(surface_details: ^SurfaceDetails) {
	delete(surface_details.present_modes)
	delete(surface_details.surface_formats)
}

SurfaceFormatResult :: enum {
	SUCCESS,
	NOT_FOUND
}

get_surface_format :: proc(surface_details: SurfaceDetails) -> (surface_format: vk.SurfaceFormatKHR, result: SurfaceFormatResult) {
	for surface_format in surface_details.surface_formats {
		if surface_format.format == .B8G8R8A8_SRGB && surface_format.colorSpace == .SRGB_NONLINEAR {
			return surface_format, .SUCCESS
		}
	}

	return surface_format, .NOT_FOUND
}

SwapchainResult :: union #shared_nil {
	vk.Result,
	SurfaceFormatResult,
	InternalDeviceResult
}

get_extent :: proc(window: glfw.WindowHandle, surface_details: SurfaceDetails) -> vk.Extent2D {
	if surface_details.capabilities.currentExtent.width != bits.U32_MAX && surface_details.capabilities.currentExtent.height != bits.U32_MAX {
		return surface_details.capabilities.currentExtent
	} else {
		int_width, int_height := glfw.GetFramebufferSize(window)
		width := u32(int_width)
		height := u32(int_height)
		width = clamp(width, surface_details.capabilities.minImageExtent.width, surface_details.capabilities.maxImageExtent.height)
		height = clamp(height, surface_details.capabilities.minImageExtent.height, surface_details.capabilities.maxImageExtent.height)
		return vk.Extent2D{
			width = width,
			height = height
		}
	}
}

rate_present_mode :: proc(mode: vk.PresentModeKHR) -> int {
	#partial switch mode {
	case .MAILBOX:
		return 0
	case .IMMEDIATE:
		return 1
	case .FIFO:
		return 2
	case:
		return 3
	}
}

present_mode_less :: proc(a, b: vk.PresentModeKHR) -> bool {
	return rate_present_mode(a) < rate_present_mode(b)
}

get_present_mode :: proc(surface_details: SurfaceDetails) -> vk.PresentModeKHR {
	mode_queue: priority_queue.Priority_Queue(vk.PresentModeKHR)
	priority_queue.init(&mode_queue, present_mode_less, priority_queue.default_swap_proc(vk.PresentModeKHR))
	defer priority_queue.destroy(&mode_queue)

	for present_mode in surface_details.present_modes {
		priority_queue.push(&mode_queue, present_mode)
	}

	result_mode := priority_queue.peek(mode_queue)
	return result_mode
}

get_swapchain_image_count :: proc(surface_details: SurfaceDetails) -> u32 {
	if (surface_details.capabilities.maxImageCount == 0) {
		return surface_details.capabilities.minImageCount + 1
	} else {
		return clamp(surface_details.capabilities.minImageCount + 1, surface_details.capabilities.minImageCount, surface_details.capabilities.maxImageCount)
	}
}

create_swapchain :: proc(physical_device: vk.PhysicalDevice, device: vk.Device, surface: vk.SurfaceKHR, surface_details: SurfaceDetails, window: glfw.WindowHandle, old_swapchain: vk.SwapchainKHR = 0) -> (swapchain: vk.SwapchainKHR, result: SwapchainResult) {
	surface_format := get_surface_format(surface_details) or_return

	indices := get_queue_family_indices(physical_device, surface) or_return
	defer delete(indices)

	swapchain_create_info := vk.SwapchainCreateInfoKHR{
		sType = .SWAPCHAIN_CREATE_INFO_KHR,
		pNext = nil,
		surface = surface,
		minImageCount = get_swapchain_image_count(surface_details),
		imageFormat = surface_format.format,
		imageColorSpace = surface_format.colorSpace,
		imageExtent = get_extent(window, surface_details),
		imageArrayLayers = 1,
		imageUsage = {.COLOR_ATTACHMENT},
		imageSharingMode = .EXCLUSIVE if len(indices) == 1 else .CONCURRENT,
		queueFamilyIndexCount = 0 if len(indices) == 1 else u32(len(indices)),
		pQueueFamilyIndices = nil if len(indices) == 1 else raw_data(indices),
		preTransform = surface_details.capabilities.currentTransform,
		compositeAlpha = {.OPAQUE},
		presentMode = get_present_mode(surface_details),
		clipped = b32(true),
		oldSwapchain = old_swapchain
	}

	vk.CreateSwapchainKHR(device, &swapchain_create_info, nil, &swapchain) or_return
	return swapchain, nil
}

get_swapchain_images :: proc(device: vk.Device, swapchain: vk.SwapchainKHR) -> (images: []vk.Image, result: vk.Result) {
	image_count: u32
	vk.GetSwapchainImagesKHR(device, swapchain, &image_count, nil) or_return
	images = make([]vk.Image, image_count)
	vk.GetSwapchainImagesKHR(device, swapchain, &image_count, raw_data(images)) or_return
	return images, .SUCCESS
}

create_image_views :: proc(device: vk.Device, swapchain_images: []vk.Image, ) -> (views: []vk.ImageView, result: vk.Result) {
	image_view_create_infos := make([]vk.ImageViewCreateInfo, len(swapchain_images))
	defer delete(image_view_create_infos)
	views = make([]vk.ImageView, len(swapchain_images))
	for i in 0..<len(swapchain_images) {
		image_view_create_infos[i] = vk.ImageViewCreateInfo{
			sType = .IMAGE_VIEW_CREATE_INFO,
			image = swapchain_images[i],
			viewType = .D2,
			format = .B8G8R8A8_SRGB,
			components = vk.ComponentMapping{
				r = .R,
				g = .G,
				b = .B,
				a = .A
			},
			subresourceRange = vk.ImageSubresourceRange{
				aspectMask = {.COLOR},
				baseMipLevel = 0,
				levelCount = 1,
				baseArrayLayer = 0,
				layerCount = 1
			}
		}
	}

	for i in 0..<len(swapchain_images) {
		vk.CreateImageView(device, &image_view_create_infos[i], nil, &views[i]) or_return
	}

	return views, .SUCCESS
}

destroy_image_views :: proc(device: vk.Device, views: []vk.ImageView) {
	for view in views {
		vk.DestroyImageView(device, view, nil)
	}
	delete(views)
}

CommandPoolResult :: union #shared_nil {
	InternalDeviceResult,
	vk.Result
}

create_command_pool :: proc(device: vk.Device, physical_device: vk.PhysicalDevice, surface: vk.SurfaceKHR) -> (command_pool: vk.CommandPool, result: CommandPoolResult) {
	indices := get_queue_family_indices(physical_device, surface) or_return
	defer delete(indices)

	command_pool_create_info := vk.CommandPoolCreateInfo{
		sType = .COMMAND_POOL_CREATE_INFO,
		flags = {.RESET_COMMAND_BUFFER},
		queueFamilyIndex = indices[0],
	}

	vk.CreateCommandPool(device, &command_pool_create_info, nil, &command_pool) or_return
	return command_pool, vk.Result.SUCCESS
}

create_framebuffers :: proc(device: vk.Device, views: []vk.ImageView, render_pass: vk.RenderPass, surface_details: SurfaceDetails, window: glfw.WindowHandle) -> (framebuffers: []vk.Framebuffer, result: vk.Result) {
	extent := get_extent(window, surface_details)
	framebuffers = make([]vk.Framebuffer, len(views))
	for i in 0..<len(views) {
		framebuffer_create_info := vk.FramebufferCreateInfo{
			sType = .FRAMEBUFFER_CREATE_INFO,
			renderPass = render_pass,
			attachmentCount = 1,
			pAttachments = &views[i],
			width = extent.width,
			height = extent.height,
			layers = 1
		}

		vk.CreateFramebuffer(device, &framebuffer_create_info, nil, &framebuffers[i]) or_return
	}

	return framebuffers, .SUCCESS
}

allocate_command_buffers :: proc(device: vk.Device, command_pool: vk.CommandPool, count: u32) -> (command_buffers: []vk.CommandBuffer, result: vk.Result) {
	command_buffers = make([]vk.CommandBuffer, count)
	command_buffer_allocate_info := vk.CommandBufferAllocateInfo{
		sType = .COMMAND_BUFFER_ALLOCATE_INFO,
		commandPool = command_pool,
		level = .PRIMARY,
		commandBufferCount = count,
	}

	vk.AllocateCommandBuffers(device, &command_buffer_allocate_info, raw_data(command_buffers)) or_return
	return command_buffers, .SUCCESS
}

record_command_buffer :: proc(command_buffer: vk.CommandBuffer, render_pass: vk.RenderPass, framebuffers: []vk.Framebuffer, window: glfw.WindowHandle, surface_details: SurfaceDetails, pipeline: vk.Pipeline, index: u32, vertex_buffer: vk.Buffer, vertices: []graphics.Vertex) -> (result: vk.Result) {
	vertex_buffer := vertex_buffer
	vk.ResetCommandBuffer(command_buffer, {})
	begin_info := vk.CommandBufferBeginInfo{
		sType = .COMMAND_BUFFER_BEGIN_INFO,
	}
	vk.BeginCommandBuffer(command_buffer, &begin_info) or_return
	
	extent := get_extent(window, surface_details)

	clear_values := [?]vk.ClearValue{vk.ClearValue{color = vk.ClearColorValue{float32 = [4]f32{0., 0., 0., 0.}}}}
	render_pass_begin_info := vk.RenderPassBeginInfo{
		sType = .RENDER_PASS_BEGIN_INFO,
		renderPass = render_pass,
		framebuffer = framebuffers[index],
		clearValueCount = u32(len(clear_values)),
		pClearValues = raw_data(clear_values[:]),
		renderArea = {
			offset = {0., 0.},
			extent = extent
		}
	}

	viewport := vk.Viewport{
		x = 0,
		y = 0,
		width = f32(extent.width),
		height = f32(extent.height),
		minDepth = 0.,
		maxDepth = 1.,
	}

	scissor := vk.Rect2D{
		offset = {0., 0.},
		extent = extent,
	}

	offset: vk.DeviceSize = 0

	vk.CmdBeginRenderPass(command_buffer, &render_pass_begin_info, .INLINE)
	vk.CmdBindVertexBuffers(command_buffer, 0, 1, &vertex_buffer, &offset)
	vk.CmdBindPipeline(command_buffer, .GRAPHICS, pipeline)
	vk.CmdSetViewport(command_buffer, 0, 1, &viewport)
	vk.CmdSetScissor(command_buffer, 0, 1, &scissor)
	vk.CmdDraw(command_buffer, u32(len(vertices)), 1, 0, 0)
	vk.CmdEndRenderPass(command_buffer)

	vk.EndCommandBuffer(command_buffer) or_return
	return .SUCCESS
}

create_semaphore :: proc(device: vk.Device) -> (semaphore: vk.Semaphore, result: vk.Result) {
	semaphore_create_info := vk.SemaphoreCreateInfo{
		sType = .SEMAPHORE_CREATE_INFO,
	}

	vk.CreateSemaphore(device, &semaphore_create_info, nil, &semaphore) or_return
	return semaphore, .SUCCESS
}

create_fence :: proc(device: vk.Device) -> (fence: vk.Fence, result: vk.Result) {
	fence_create_info := vk.FenceCreateInfo{
		sType = .FENCE_CREATE_INFO,
		flags = {.SIGNALED},
	}

	vk.CreateFence(device, &fence_create_info, nil, &fence) or_return
	return fence, .SUCCESS
}

acquire_swapchain_image :: proc(device: vk.Device, swapchain: vk.SwapchainKHR, wait_fence: ^vk.Fence, signal_semaphore: vk.Semaphore, timeout: u64 = bits.U64_MAX) -> (image_index: u32, result: vk.Result) {
	vk.WaitForFences(device, 1, wait_fence, b32(true), bits.U64_MAX) or_return
	vk.AcquireNextImageKHR(device, swapchain, timeout, signal_semaphore, 0, &image_index) or_return
	return image_index, .SUCCESS
}

InternalSubmitResult :: enum {
	QUEUE_FAMILY_NOT_SUPPORTED
}

SubmitResult :: union #shared_nil {
	vk.Result,
	InternalSubmitResult
}

submit_command_buffer :: proc(graphics_family_index: u32, device: vk.Device, command_buffer: ^vk.CommandBuffer, wait_semaphore: ^vk.Semaphore, signal_semaphore: ^vk.Semaphore, signal_fence: vk.Fence) -> (result: SubmitResult) {
	queue: vk.Queue
	vk.GetDeviceQueue(device, graphics_family_index, 0, &queue)

	mask := vk.PipelineStageFlags{.COLOR_ATTACHMENT_OUTPUT}
	submit_info := vk.SubmitInfo{
		sType = .SUBMIT_INFO,
		waitSemaphoreCount = 1,
		pWaitSemaphores = wait_semaphore,
		signalSemaphoreCount = 1,
		pSignalSemaphores = signal_semaphore,
		commandBufferCount = 1,
		pCommandBuffers = command_buffer,
		pWaitDstStageMask = &mask,
	}

	vk.QueueSubmit(queue, 1, &submit_info, signal_fence) or_return
	return vk.Result.SUCCESS
}

InternalPresentResult :: enum {
	SUCCESS,
	QUEUE_FAMILY_NOT_SUPPORTED
}

PresentResult :: union #shared_nil {
	vk.Result,
	InternalPresentResult
}

present_image :: proc(surface_family_index: u32, device: vk.Device, swapchain: ^vk.SwapchainKHR, wait_semaphore: ^vk.Semaphore, index: u32) -> (result: PresentResult) {
	index := index

	queue: vk.Queue
	vk.GetDeviceQueue(device, surface_family_index, 0, &queue)

	present_info := vk.PresentInfoKHR{
		sType = .PRESENT_INFO_KHR,
		waitSemaphoreCount = 1,
		pWaitSemaphores = wait_semaphore,
		swapchainCount = 1,
		pSwapchains = swapchain,
		pImageIndices = &index
	}

	vk.QueuePresentKHR(queue, &present_info) or_return
	return vk.Result.SUCCESS
}

log_panic :: proc(error: any = nil, expr := #caller_expression, location := #caller_location) {
	if !reflect.is_nil(error) {
		log.panic("vulkan error:", expr, error, location=location)
	}
}

framebuffer_size_callback :: proc "c" (window: glfw.WindowHandle, width: i32, height: i32) {
	context = g_context 

	state := (^FramebufferCallbackState)(glfw.GetWindowUserPointer(window))^
	vk.DeviceWaitIdle(state.device)
	state.resized^ = true
}

FramebufferCallbackState :: struct{
	resized: ^bool,
	device: vk.Device
}

frames_in_flight :: 2

recreate_swapchain :: proc(window: glfw.WindowHandle, surface: vk.SurfaceKHR, physical_device: vk.PhysicalDevice, device: vk.Device, surface_details: ^SurfaceDetails, swapchain: ^vk.SwapchainKHR, swapchain_images: ^[]vk.Image, views: ^[]vk.ImageView, framebuffers: ^[]vk.Framebuffer, render_pass: vk.RenderPass) {
	vk.DeviceWaitIdle(device)

	destroy_surface_details(surface_details)
	surface_details_result: vk.Result
	surface_details^, surface_details_result = get_surface_details(physical_device, surface)
	log_panic(surface_details_result)

	new_swapchain: vk.SwapchainKHR
	swapchain_result: SwapchainResult
	new_swapchain, swapchain_result = create_swapchain(physical_device, device, surface, surface_details^, window, swapchain^)
	vk.DestroySwapchainKHR(device, swapchain^, nil)
	swapchain^ = new_swapchain
	log_panic(swapchain_result)

	delete(swapchain_images^)
	swapchain_images_result: vk.Result
	swapchain_images^, swapchain_images_result = get_swapchain_images(device, swapchain^)
	log_panic(swapchain_images_result)

	destroy_image_views(device, views^)
	views_result: vk.Result
	views^, views_result = create_image_views(device, swapchain_images^)
	log_panic(views_result)

	for framebuffer in framebuffers^ {
		vk.DestroyFramebuffer(device, framebuffer, nil)
	}
	delete(framebuffers^)
	framebuffers_result: vk.Result
	framebuffers^, framebuffers_result = create_framebuffers(device, views^, render_pass, surface_details^, window)
	log_panic(framebuffers_result)
}

create_buffer :: proc(device: vk.Device, size: vk.DeviceSize, usage: vk.BufferUsageFlags) -> (buffer: vk.Buffer, result: vk.Result) {
	buffer_create_info := vk.BufferCreateInfo{
		sType = .BUFFER_CREATE_INFO,
		size = size,
		usage = usage,
		sharingMode = .EXCLUSIVE
	}

	vk.CreateBuffer(device, &buffer_create_info, nil, &buffer) or_return
	return buffer, .SUCCESS
}

MemoryTypeResult :: enum {
	SUCCESS,
	NOT_FOUND
}

find_memory_type :: proc(physical_device: vk.PhysicalDevice, requirements: vk.MemoryRequirements, property_flags: vk.MemoryPropertyFlags) -> (index: u32, result: MemoryTypeResult) {
	properties: vk.PhysicalDeviceMemoryProperties
	vk.GetPhysicalDeviceMemoryProperties(physical_device, &properties)

	for i in 0..<properties.memoryTypeCount {
		memory_type := properties.memoryTypes[i]
		if ((1 << i) & requirements.memoryTypeBits) != 0 && property_flags <= memory_type.propertyFlags {
			index = i
			return index, .SUCCESS
		}
	}

	return index, .NOT_FOUND
}

allocate_buffer :: proc(device: vk.Device, memory_requirements: vk.MemoryRequirements, memory_type_index: u32) -> (memory: vk.DeviceMemory, result: vk.Result) {
	allocate_info := vk.MemoryAllocateInfo{
		sType = .MEMORY_ALLOCATE_INFO,
		allocationSize = memory_requirements.size,
		memoryTypeIndex = memory_type_index,
	}

	vk.AllocateMemory(device, &allocate_info, nil, &memory) or_return
	return memory, .SUCCESS
}

get_memory_info :: proc(physical_device: vk.PhysicalDevice, device: vk.Device, buffer: vk.Buffer, property_flags: vk.MemoryPropertyFlags) -> (memory_requirements: vk.MemoryRequirements, memory_type_index: u32, result: MemoryTypeResult) {
	vk.GetBufferMemoryRequirements(device, buffer, &memory_requirements)
	memory_type_index, result = find_memory_type(physical_device, memory_requirements, property_flags)
	return memory_requirements, memory_type_index, result
}

create_transient_command_pool :: proc(physical_device: vk.PhysicalDevice, device: vk.Device, surface: vk.SurfaceKHR) -> (command_pool: vk.CommandPool, result: CommandPoolResult) {
	indices := get_queue_family_indices(physical_device, surface) or_return
	defer delete(indices)

	command_pool_create_info := vk.CommandPoolCreateInfo{
		sType = .COMMAND_POOL_CREATE_INFO,
		flags = {.TRANSIENT},
		queueFamilyIndex = indices[0],
	}

	vk.CreateCommandPool(device, &command_pool_create_info, nil, &command_pool) or_return
	return command_pool, vk.Result.SUCCESS
}

allocate_transfer_command_buffer :: proc(device: vk.Device, command_pool: vk.CommandPool) -> (command_buffer: vk.CommandBuffer, result: vk.Result) {
	command_buffer_allocate_info := vk.CommandBufferAllocateInfo{
		sType = .COMMAND_BUFFER_ALLOCATE_INFO,
		commandPool = command_pool,
		level = .PRIMARY,
		commandBufferCount = 1,
	}

	vk.AllocateCommandBuffers(device, &command_buffer_allocate_info, &command_buffer) or_return
	return command_buffer, .SUCCESS
}

record_transfer_command_buffer :: proc(device: vk.Device, command_buffer: vk.CommandBuffer, src: vk.Buffer, dst: vk.Buffer, size: vk.DeviceSize) -> (result: vk.Result) {
	begin_info := vk.CommandBufferBeginInfo{
		sType = .COMMAND_BUFFER_BEGIN_INFO
	}
	vk.BeginCommandBuffer(command_buffer, &begin_info) or_return
	region := vk.BufferCopy{
		srcOffset = 0,
		dstOffset = 0,
		size = size
	}
	vk.CmdCopyBuffer(command_buffer, src, dst, 1, &region)
	vk.EndCommandBuffer(command_buffer) or_return

	return .SUCCESS
}

submit_transfer_command_buffer :: proc(transfer_family_index: u32, device: vk.Device, command_buffer: vk.CommandBuffer) -> (result: SubmitResult) {
	command_buffer := command_buffer

	queue: vk.Queue
	vk.GetDeviceQueue(device, transfer_family_index, 0, &queue)

	submit_info := vk.SubmitInfo{
		sType = .SUBMIT_INFO,
		commandBufferCount = 1,
		pCommandBuffers = &command_buffer,
	}

	fence := create_fence(device) or_return
	vk.ResetFences(device, 1, &fence) or_return
	vk.QueueSubmit(queue, 1, &submit_info, fence) or_return
	vk.WaitForFences(device, 1, &fence, b32(true), bits.U64_MAX)
	vk.DestroyFence(device, fence, nil)
	return result
}

draw :: proc(physical_device: vk.PhysicalDevice, device: vk.Device, swapchain: ^vk.SwapchainKHR, acquire_semaphores: []vk.Semaphore, draw_semaphores: []vk.Semaphore, window: glfw.WindowHandle, swapchain_images: ^[]vk.Image, views: ^[]vk.ImageView, framebuffers: ^[]vk.Framebuffer, render_pass: vk.RenderPass, command_buffers: []vk.CommandBuffer, pipeline: vk.Pipeline, in_flight_fences: []vk.Fence, in_flight_index: int, surface: vk.SurfaceKHR, surface_details: ^SurfaceDetails, vertex_buffer: vk.Buffer, vertices: []graphics.Vertex, resized: ^bool, graphics_family_index: u32, surface_family_index: u32) {
	swapchain_images := swapchain_images
	views := views
	framebuffers := framebuffers

	index, acquire_result := acquire_swapchain_image(device, swapchain^, &in_flight_fences[in_flight_index], acquire_semaphores[in_flight_index])
	if acquire_result == .ERROR_OUT_OF_DATE_KHR {
		recreate_swapchain(window, surface, physical_device, device, surface_details, swapchain, swapchain_images, views, framebuffers, render_pass)
		return
	} else if acquire_result != .SUCCESS && acquire_result != .SUBOPTIMAL_KHR {
		log_panic(acquire_result)
	} else {
		vk.ResetFences(device, 1, &in_flight_fences[in_flight_index])
	}

	record_result := record_command_buffer(command_buffers[in_flight_index], render_pass, framebuffers^, window, surface_details^, pipeline, index, vertex_buffer, vertices[:])
	log_panic(record_result)

	submit_result := submit_command_buffer(graphics_family_index, device, &command_buffers[in_flight_index], &acquire_semaphores[in_flight_index], &draw_semaphores[index], in_flight_fences[in_flight_index])
	log_panic(submit_result)

	present_result := present_image(surface_family_index, device, swapchain, &draw_semaphores[index], index)
	if present_result == .ERROR_OUT_OF_DATE_KHR || present_result == .SUBOPTIMAL_KHR || resized^ {
		resized^ = false
		recreate_swapchain(window, surface, physical_device, device, surface_details, swapchain, swapchain_images, views, framebuffers, render_pass)
	}
}

SetupBufferResult :: union #shared_nil {
	vk.Result,
	MemoryTypeResult,
	SubmitResult
}

setup_buffer :: proc(physical_device: vk.PhysicalDevice, device: vk.Device, transfer_family_index: u32, usage: vk.BufferUsageFlags, size: vk.DeviceSize, data: rawptr, command_pool: vk.CommandPool) -> (buffer: vk.Buffer, memory: vk.DeviceMemory, result: SetupBufferResult) {
	staging_buffer := create_buffer(device, size, {.TRANSFER_SRC}) or_return
	staging_memory_requirements, staging_memory_type_index := get_memory_info(physical_device, device, staging_buffer, {.HOST_VISIBLE, .HOST_COHERENT}) or_return
	staging_memory := allocate_buffer(device, staging_memory_requirements, staging_memory_type_index) or_return
	vk.BindBufferMemory(device, staging_buffer, staging_memory, 0) or_return

	mapped_data: rawptr
	log_panic(vk.MapMemory(device, staging_memory, 0, size, {}, &mapped_data))
	mem.copy(mapped_data, data, int(size))
	vk.UnmapMemory(device, staging_memory)

	buffer = create_buffer(device, size, {.TRANSFER_DST} + usage) or_return
	memory_requirements, memory_type_index := get_memory_info(physical_device, device, buffer, {.DEVICE_LOCAL}) or_return
	memory = allocate_buffer(device, memory_requirements, memory_type_index) or_return
	vk.BindBufferMemory(device, buffer, memory, 0) or_return

	{
		transfer_command_buffer := allocate_transfer_command_buffer(device, command_pool) or_return
		defer vk.FreeCommandBuffers(device, command_pool, 1, &transfer_command_buffer)
		record_transfer_command_buffer(device, transfer_command_buffer, staging_buffer, buffer, size) or_return
		submit_transfer_command_buffer(transfer_family_index, device, transfer_command_buffer) or_return
		vk.DestroyBuffer(device, staging_buffer, nil)
		vk.FreeMemory(device, staging_memory, nil)
	}

	return buffer, memory, nil
}

destroy_buffer :: proc(device: vk.Device, buffer: vk.Buffer, memory: vk.DeviceMemory) {
	vk.FreeMemory(device, memory, nil)
	vk.DestroyBuffer(device, buffer, nil)
}

main :: proc() {
	when ODIN_DEBUG {
		track: mem.Tracking_Allocator
		mem.tracking_allocator_init(&track, context.allocator)
		context.allocator = mem.tracking_allocator(&track)

		defer {
			if len(track.allocation_map) > 0 {
				fmt.eprintf("=== %v allocations not freed: ===\n", len(track.allocation_map))
				for _, entry in track.allocation_map {
					fmt.eprintf("- %v bytes @ %v\n", entry.size, entry.location)
				}
			}
			mem.tracking_allocator_destroy(&track)
		}
	}

	context.logger = log.create_console_logger()
	g_context = context
	defer log.destroy_console_logger(context.logger)
	glfw.SetErrorCallback(error_callback)

	when ODIN_OS == .Linux {
		glfw.InitHint(glfw.X11_XCB_VULKAN_SURFACE, 1)
	}
	if !glfw.Init() {
		log.panic("glfw failed to initialize")
	}
	defer glfw.Terminate()

	vk.load_proc_addresses(rawptr(glfw.GetInstanceProcAddress))
	assert(vk.CreateInstance != nil, "function pointers not loaded")

	glfw.WindowHint(glfw.MAXIMIZED, 1)
	glfw.WindowHint(glfw.RESIZABLE, 1)
	glfw.WindowHint(glfw.CLIENT_API, glfw.NO_API)
	window: glfw.WindowHandle = glfw.CreateWindow(1280, 720, "Vulkan Triangle", nil, nil)
	defer glfw.DestroyWindow(window)

	validation_layers := get_validation_layers()
	defer delete(validation_layers)
	instance, instance_result := create_instance(window, validation_layers[:])
	log_panic(instance_result)
	vk.load_proc_addresses(instance)
	assert(vk.DestroyInstance != nil, "function pointers not loaded")
	defer vk.DestroyInstance(instance, nil)

	surface, surface_result := create_window_surface(instance, window)
	log_panic(surface_result)
	defer vk.DestroySurfaceKHR(instance, surface, nil)

	when ODIN_DEBUG {
		messenger, messenger_result := create_debug_messenger(instance)
		if messenger_result != .SUCCESS {
			log.warn("failed to create debug messenger", messenger_result)
		}
		defer vk.DestroyDebugUtilsMessengerEXT(instance, messenger, nil)
	}

	physical_device, physical_device_result := get_physical_device(instance, surface)
	log_panic(physical_device_result)

	graphics_family_index, surface_family_index, ok := supports_queue_families(physical_device, surface)
	if !ok {
		log.panic("failed to get queue family indices")
	}

	device, device_result := create_device(physical_device, surface)
	log_panic(device_result)
	defer vk.DestroyDevice(device, nil)

	surface_details, surface_details_result := get_surface_details(physical_device, surface)
	defer destroy_surface_details(&surface_details)
	log_panic(surface_details_result)
	swapchain, swapchain_result := create_swapchain(physical_device, device, surface, surface_details, window)
	log_panic(swapchain_result)
	defer vk.DestroySwapchainKHR(device, swapchain, nil)

	swapchain_images, swapchain_images_result := get_swapchain_images(device, swapchain)
	log_panic(swapchain_images_result)
	defer delete(swapchain_images)

	views, views_result := create_image_views(device, swapchain_images)
	log_panic(views_result)
	defer destroy_image_views(device, views)

	triangle_fragment_shader, fragment_shader_result := graphics.create_shader_module(device, #load("shaders/triangle/frag.spv", []u32))
	triangle_vertex_shader, vertex_shader_result := graphics.create_shader_module(device, #load("shaders/triangle/vert.spv", []u32))
	log_panic(fragment_shader_result)
	log_panic(vertex_shader_result)

	render_pass, render_pass_result := graphics.create_render_pass(device)
	log_panic(render_pass_result)
	defer vk.DestroyRenderPass(device, render_pass, nil)

	pipeline_layout, pipeline_layout_result := graphics.create_pipeline_layout(device)
	log_panic(pipeline_layout_result)
	defer vk.DestroyPipelineLayout(device, pipeline_layout, nil)

	vertices := [?]graphics.Vertex{
		graphics.Vertex{linalg.Vector3f32{-.5, -.5, 0.}, linalg.Vector3f32{1., 1., 0.}},
		graphics.Vertex{linalg.Vector3f32{-.5, .5, 0}, linalg.Vector3f32{0., 1., 0.}},
		graphics.Vertex{linalg.Vector3f32{.5, .5, 0}, linalg.Vector3f32{0., 0., 1.}},
		graphics.Vertex{linalg.Vector3f32{-.5, -.5, 0.}, linalg.Vector3f32{1., 1., 0.}},
		graphics.Vertex{linalg.Vector3f32{.5, .5, 0}, linalg.Vector3f32{0., 0., 1.}},
		graphics.Vertex{linalg.Vector3f32{.5, -.5, 0}, linalg.Vector3f32{1., 0., 0.}},
	}

	transient_command_pool, transient_command_pool_result := create_transient_command_pool(physical_device, device, surface)
	log_panic(transient_command_pool_result)
	defer vk.DestroyCommandPool(device, transient_command_pool, nil)

	vertex_buffer, vertex_memory, vertex_buffer_result := setup_buffer(physical_device, device, graphics_family_index, {.VERTEX_BUFFER}, len(vertices) * size_of(vertices[0]), raw_data(vertices[:]), transient_command_pool)
	log_panic(vertex_buffer_result)
	defer destroy_buffer(device, vertex_buffer, vertex_memory)
	
	pipeline, pipeline_result := graphics.create_pipeline(device, triangle_fragment_shader, triangle_vertex_shader, render_pass, pipeline_layout, vertices[:])
	log_panic(pipeline_result)
	defer vk.DestroyPipeline(device, pipeline, nil)

	framebuffers, framebuffers_result := create_framebuffers(device, views, render_pass, surface_details, window)
	log_panic(framebuffers_result)
	defer {
		for framebuffer in framebuffers {
			vk.DestroyFramebuffer(device, framebuffer, nil)
		}
		delete(framebuffers)
	}

	reset_command_pool, reset_command_pool_result := create_command_pool(device, physical_device, surface)
	log_panic(reset_command_pool_result)
	defer vk.DestroyCommandPool(device, reset_command_pool, nil)

	graphics_command_buffers, graphics_command_buffer_result := allocate_command_buffers(device, reset_command_pool, frames_in_flight)
	defer delete(graphics_command_buffers)
	log_panic(graphics_command_buffer_result)

	acquire_semaphores := make([]vk.Semaphore, len(swapchain_images))
	draw_semaphores := make([]vk.Semaphore, len(swapchain_images))
	for i in 0..<len(swapchain_images) {
		acquire_result: vk.Result
		draw_result: vk.Result
		present_result: vk.Result

		acquire_semaphores[i], acquire_result = create_semaphore(device)
		log_panic(acquire_result)
		draw_semaphores[i], draw_result = create_semaphore(device)
		log_panic(draw_result)
	}
	defer {
		for i in 0..<len(swapchain_images) {
			vk.DestroySemaphore(device, acquire_semaphores[i], nil)
			vk.DestroySemaphore(device, draw_semaphores[i], nil)
		}

		delete(acquire_semaphores)
		delete(draw_semaphores)
	}

	in_flight_fences := make([]vk.Fence, frames_in_flight)
	for i in 0..<frames_in_flight {
		fence_result: vk.Result
		in_flight_fences[i], fence_result = create_fence(device)
		log_panic(fence_result)
	}

	defer {
		for i in 0..<frames_in_flight {
			vk.DestroyFence(device, in_flight_fences[i], nil)
		}
		delete(in_flight_fences)
	}

	resized := false
	framebuffer_callback_state := FramebufferCallbackState{
		resized = &resized,
		device = device
	}
	glfw.SetWindowUserPointer(window, &framebuffer_callback_state)
	glfw.SetFramebufferSizeCallback(window, framebuffer_size_callback)

	for in_flight_index := 0; !glfw.WindowShouldClose(window); {
		glfw.PollEvents()
		draw(physical_device, device, &swapchain, acquire_semaphores, draw_semaphores, window, &swapchain_images, &views, &framebuffers, render_pass, graphics_command_buffers, pipeline, in_flight_fences, in_flight_index, surface, &surface_details, vertex_buffer, vertices[:], &resized, graphics_family_index, surface_family_index)
		in_flight_index = (in_flight_index + 1) % frames_in_flight
	}

	vk.DeviceWaitIdle(device)
}
