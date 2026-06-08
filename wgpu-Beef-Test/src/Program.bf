using System;
using SDL2;
using wgpu_Beef;

namespace wgpu_Beef_Test;

class Program
{
	// wgpu-native fires the adapter/device request callbacks synchronously,
	// so we can just capture the results into these fields.
	static WGPUAdapter sAdapter = null;
	static WGPUDevice sDevice = null;

	const int32 WIDTH = 800;
	const int32 HEIGHT = 600;

	// Minimal triangle shader. We pass an explicit length to WGPUStringView,
	// so the source does not need to be null-terminated.
	const String SHADER_WGSL = """
		@vertex fn vs_main(@builtin(vertex_index) idx: u32) -> @builtin(position) vec4<f32> {
			var p = array<vec2<f32>, 3>(vec2<f32>(0.0, 0.5), vec2<f32>(-0.5, -0.5), vec2<f32>(0.5, -0.5));
			return vec4<f32>(p[idx], 0.0, 1.0);
		}
		@fragment fn fs_main() -> @location(0) vec4<f32> {
			return vec4<f32>(1.0, 0.6, 0.1, 1.0);
		}
		""";

	static WGPUStringView SV(StringView s)
	{
		return .() { data = s.Ptr, length = (uint)s.Length };
	}

	static void OnAdapter(WGPURequestAdapterStatus status, WGPUAdapter adapter, WGPUStringView message, void* u1, void* u2)
	{
		if (status == .WGPURequestAdapterStatus_Success)
			sAdapter = adapter;
		else
			Console.WriteLine("RequestAdapter failed: {0}", status);
	}

	static void OnDevice(WGPURequestDeviceStatus status, WGPUDevice device, WGPUStringView message, void* u1, void* u2)
	{
		if (status == .WGPURequestDeviceStatus_Success)
			sDevice = device;
		else
			Console.WriteLine("RequestDevice failed: {0}", status);
	}

	public static int Main()
	{
		// --- 1. Create an OS window with SDL2 ---
		if (SDL.Init(.Video) != 0)
		{
			Console.WriteLine("SDL_Init failed");
			return 1;
		}
		defer SDL.Quit();

		let window = SDL.CreateWindow("wgpu-Beef triangle", .Centered, .Centered, WIDTH, HEIGHT, .Shown | .Resizable);
		if (window == null)
		{
			Console.WriteLine("SDL_CreateWindow failed");
			return 1;
		}
		defer SDL.DestroyWindow(window);

		// --- 2. Create the wgpu instance ---
		let instance = wgpuCreateInstance(null);
		defer wgpuInstanceRelease(instance);

		// --- 3. Create a surface from the native window handle ---
		WGPUSurface surface = null;
#if BF_PLATFORM_WINDOWS
		SDL.SDL_SysWMinfo wmInfo = .();
		SDL.VERSION(out wmInfo.version);
		SDL.GetWindowWMInfo(window, ref wmInfo);

		WGPUSurfaceSourceWindowsHWND fromHwnd = .();
		fromHwnd.chain.sType = .WGPUSType_SurfaceSourceWindowsHWND;
		fromHwnd.hinstance = (void*)(int)wmInfo.info.win.hinstance;
		fromHwnd.hwnd = (void*)(int)wmInfo.info.win.window;

		WGPUSurfaceDescriptor surfaceDesc = .();
		surfaceDesc.nextInChain = (WGPUChainedStruct*)&fromHwnd;
		surface = wgpuInstanceCreateSurface(instance, &surfaceDesc);
#endif
		if (surface == null)
		{
			Console.WriteLine("CreateSurface failed");
			return 1;
		}
		defer wgpuSurfaceRelease(surface);

		// --- 4. Request an adapter (compatible with our surface) ---
		WGPURequestAdapterOptions adapterOpts = .();
		adapterOpts.compatibleSurface = surface;
		adapterOpts.powerPreference = .WGPUPowerPreference_HighPerformance;

		WGPURequestAdapterCallbackInfo adapterCb = .();
		adapterCb.mode = .WGPUCallbackMode_AllowProcessEvents;
		adapterCb.callback = => OnAdapter;
		wgpuInstanceRequestAdapter(instance, &adapterOpts, adapterCb);

		if (sAdapter == null)
			return 1;
		defer wgpuAdapterRelease(sAdapter);

		// --- 5. Request a device + grab its queue ---
		WGPURequestDeviceCallbackInfo deviceCb = .();
		deviceCb.mode = .WGPUCallbackMode_AllowProcessEvents;
		deviceCb.callback = => OnDevice;
		wgpuAdapterRequestDevice(sAdapter, null, deviceCb);

		if (sDevice == null)
			return 1;
		defer wgpuDeviceRelease(sDevice);

		let queue = wgpuDeviceGetQueue(sDevice);
		defer wgpuQueueRelease(queue);

		// --- 6. Pick a surface format/alpha mode from what the adapter supports ---
		// BGRA8Unorm is used as a fallback if the query fails for some reason.
		var surfaceFormat = WGPUTextureFormat.WGPUTextureFormat_BGRA8Unorm;
		var alphaMode = WGPUCompositeAlphaMode.WGPUCompositeAlphaMode_Auto;
		WGPUSurfaceCapabilities caps = .();
		if (wgpuSurfaceGetCapabilities(surface, sAdapter, &caps) == .WGPUStatus_Success)
		{
			// formats and alphaModes are listed in order of preference; [0] is best.
			if (caps.formatCount > 0)
				surfaceFormat = caps.formats[0];
			if (caps.alphaModeCount > 0)
				alphaMode = caps.alphaModes[0];
			wgpuSurfaceCapabilitiesFreeMembers(caps);
		}

		// --- 7. Configure the surface ---
		WGPUSurfaceConfiguration config = .();
		config.device = sDevice;
		config.format = surfaceFormat;
		config.usage = WGPUTextureUsage_RenderAttachment;
		config.width = (uint32)WIDTH;
		config.height = (uint32)HEIGHT;
		config.presentMode = .WGPUPresentMode_Fifo;
		config.alphaMode = alphaMode;
		wgpuSurfaceConfigure(surface, &config);
		defer wgpuSurfaceUnconfigure(surface);

		// --- 8. Compile the shader module ---
		WGPUShaderSourceWGSL wgslSource = .();
		wgslSource.chain.sType = .WGPUSType_ShaderSourceWGSL;
		wgslSource.code = SV(SHADER_WGSL);

		WGPUShaderModuleDescriptor shaderDesc = .();
		shaderDesc.nextInChain = (WGPUChainedStruct*)&wgslSource;
		let shader = wgpuDeviceCreateShaderModule(sDevice, &shaderDesc);
		defer wgpuShaderModuleRelease(shader);

		// --- 9. Build the render pipeline ---
		WGPUColorTargetState colorTarget = .();
		colorTarget.format = surfaceFormat;
		colorTarget.writeMask = WGPUColorWriteMask_All;

		WGPUFragmentState fragment = .();
		fragment.module = shader;
		fragment.entryPoint = SV("fs_main");
		fragment.targetCount = 1;
		fragment.targets = &colorTarget;

		WGPURenderPipelineDescriptor pipelineDesc = .();
		pipelineDesc.vertex.module = shader;
		pipelineDesc.vertex.entryPoint = SV("vs_main");
		pipelineDesc.primitive.topology = .WGPUPrimitiveTopology_TriangleList;
		pipelineDesc.multisample.count = 1;
		pipelineDesc.multisample.mask = 0xFFFFFFFF;
		pipelineDesc.fragment = &fragment;
		let pipeline = wgpuDeviceCreateRenderPipeline(sDevice, &pipelineDesc);
		defer wgpuRenderPipelineRelease(pipeline);

		// --- 10. Main loop ---
		bool running = true;
		while (running)
		{
			SDL.Event event;
			while (SDL.PollEvent(out event) != 0)
			{
				if (event.type == .Quit)
				{
					running = false;
				}
				else if ((event.type == .WindowEvent) && (event.window.windowEvent == .SizeChanged))
				{
					// Window was resized: resize the swapchain to match.
					config.width = (uint32)event.window.data1;
					config.height = (uint32)event.window.data2;
					if ((config.width > 0) && (config.height > 0))
						wgpuSurfaceConfigure(surface, &config);
				}
			}

			// Skip rendering while minimized (zero-sized surface).
			if ((config.width == 0) || (config.height == 0))
				continue;

			WGPUSurfaceTexture surfaceTex = .();
			wgpuSurfaceGetCurrentTexture(surface, &surfaceTex);
			let status = surfaceTex.status;
			if ((status == .WGPUSurfaceGetCurrentTextureStatus_Timeout) ||
				(status == .WGPUSurfaceGetCurrentTextureStatus_Outdated) ||
				(status == .WGPUSurfaceGetCurrentTextureStatus_Lost))
			{
				// Transient: reconfigure (e.g. after a resize) and try again next frame.
				if (surfaceTex.texture != null)
					wgpuTextureRelease(surfaceTex.texture);
				wgpuSurfaceConfigure(surface, &config);
				continue;
			}
			if ((status != .WGPUSurfaceGetCurrentTextureStatus_SuccessOptimal) &&
				(status != .WGPUSurfaceGetCurrentTextureStatus_SuccessSuboptimal))
			{
				if (surfaceTex.texture != null)
					wgpuTextureRelease(surfaceTex.texture);
				continue;
			}

			let view = wgpuTextureCreateView(surfaceTex.texture, null);
			let encoder = wgpuDeviceCreateCommandEncoder(sDevice, null);

			WGPURenderPassColorAttachment colorAttachment = .();
			colorAttachment.view = view;
			colorAttachment.depthSlice = WGPU_DEPTH_SLICE_UNDEFINED;
			colorAttachment.loadOp = .WGPULoadOp_Clear;
			colorAttachment.storeOp = .WGPUStoreOp_Store;
			colorAttachment.clearValue = .() { r = 0.1, g = 0.1, b = 0.12, a = 1.0 };

			WGPURenderPassDescriptor passDesc = .();
			passDesc.colorAttachmentCount = 1;
			passDesc.colorAttachments = &colorAttachment;

			let pass = wgpuCommandEncoderBeginRenderPass(encoder, &passDesc);
			wgpuRenderPassEncoderSetPipeline(pass, pipeline);
			wgpuRenderPassEncoderDraw(pass, 3, 1, 0, 0);
			wgpuRenderPassEncoderEnd(pass);
			wgpuRenderPassEncoderRelease(pass);

			var cmd = wgpuCommandEncoderFinish(encoder, null);
			wgpuQueueSubmit(queue, 1, &cmd);
			wgpuSurfacePresent(surface);

			wgpuCommandBufferRelease(cmd);
			wgpuCommandEncoderRelease(encoder);
			wgpuTextureViewRelease(view);
			wgpuTextureRelease(surfaceTex.texture);
		}

		return 0;
	}
}
