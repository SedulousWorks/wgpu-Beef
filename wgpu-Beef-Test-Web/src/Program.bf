using System;
using wgpu_Beef;

namespace wgpu_Beef_Test_Web;

// WebGPU triangle for the browser (Emscripten + emdawnwebgpu).
//
// Differences from the native (SDL2/HWND) sample:
//   * The surface comes from an HTML <canvas> via the emdawnwebgpu-only
//     WGPUEmscriptenSurfaceSourceCanvasHTMLSelector (declared below, since it
//     isn't part of the native wgpu-native binding).
//   * You cannot block the browser, so init is async (callback-chained) and the
//     frame loop is driven by emscripten_set_main_loop instead of a while loop.
//   * There is no wgpuSurfacePresent on the web; the browser presents per frame.
class Program
{
	const int32 WIDTH = 800;
	const int32 HEIGHT = 600;

	// emdawnwebgpu canvas surface source. The sType value (0x00040000) and the
	// struct layout are taken verbatim from the emdawnwebgpu webgpu.h header.
	const WGPUSType WGPUSType_EmscriptenSurfaceSourceCanvasHTMLSelector = (.)0x00040000;

	[CRepr]
	struct WGPUEmscriptenSurfaceSourceCanvasHTMLSelector
	{
		public WGPUChainedStruct chain;
		public WGPUStringView selector;
	}

	// Emscripten's frame-loop driver: hands control back to the browser.
	[LinkName("emscripten_set_main_loop")]
	static extern void emscripten_set_main_loop(function void() func, int32 fps, int32 simulateInfiniteLoop);

	const String SHADER_WGSL = """
		@vertex fn vs_main(@builtin(vertex_index) idx: u32) -> @builtin(position) vec4<f32> {
			var p = array<vec2<f32>, 3>(vec2<f32>(0.0, 0.5), vec2<f32>(-0.5, -0.5), vec2<f32>(0.5, -0.5));
			return vec4<f32>(p[idx], 0.0, 1.0);
		}
		@fragment fn fs_main() -> @location(0) vec4<f32> {
			return vec4<f32>(1.0, 0.6, 0.1, 1.0);
		}
		""";

	static WGPUInstance sInstance;
	static WGPUSurface sSurface;
	static WGPUAdapter sAdapter;
	static WGPUDevice sDevice;
	static WGPUQueue sQueue;
	static WGPURenderPipeline sPipeline;
	static WGPUTextureFormat sFormat = .WGPUTextureFormat_BGRA8Unorm;
	static bool sReady = false;

	static WGPUStringView SV(StringView s)
	{
		return .() { data = s.Ptr, length = (uint)s.Length };
	}

	static void OnAdapter(WGPURequestAdapterStatus status, WGPUAdapter adapter, WGPUStringView message, void* u1, void* u2)
	{
		if (status != .WGPURequestAdapterStatus_Success)
		{
			Console.WriteLine("RequestAdapter failed: {0}", status);
			return;
		}
		sAdapter = adapter;

		// Chain straight into the (also async) device request.
		WGPURequestDeviceCallbackInfo cb = .();
		cb.mode = .WGPUCallbackMode_AllowSpontaneous;
		cb.callback = => OnDevice;
		wgpuAdapterRequestDevice(sAdapter, null, cb);
	}

	static void OnDevice(WGPURequestDeviceStatus status, WGPUDevice device, WGPUStringView message, void* u1, void* u2)
	{
		if (status != .WGPURequestDeviceStatus_Success)
		{
			Console.WriteLine("RequestDevice failed: {0}", status);
			return;
		}
		sDevice = device;
		sQueue = wgpuDeviceGetQueue(sDevice);
		ConfigureAndBuildPipeline();
		sReady = true;
	}

	static void ConfigureAndBuildPipeline()
	{
		// Negotiate a supported surface format.
		WGPUSurfaceCapabilities caps = .();
		if (wgpuSurfaceGetCapabilities(sSurface, sAdapter, &caps) == .WGPUStatus_Success)
		{
			if (caps.formatCount > 0)
				sFormat = caps.formats[0];
			wgpuSurfaceCapabilitiesFreeMembers(caps);
		}

		WGPUSurfaceConfiguration config = .();
		config.device = sDevice;
		config.format = sFormat;
		config.usage = WGPUTextureUsage_RenderAttachment;
		config.width = (uint32)WIDTH;
		config.height = (uint32)HEIGHT;
		config.presentMode = .WGPUPresentMode_Fifo;
		config.alphaMode = .WGPUCompositeAlphaMode_Auto;
		wgpuSurfaceConfigure(sSurface, &config);

		// Shader module.
		WGPUShaderSourceWGSL wgslSource = .();
		wgslSource.chain.sType = .WGPUSType_ShaderSourceWGSL;
		wgslSource.code = SV(SHADER_WGSL);
		WGPUShaderModuleDescriptor shaderDesc = .();
		shaderDesc.nextInChain = (WGPUChainedStruct*)&wgslSource;
		let shader = wgpuDeviceCreateShaderModule(sDevice, &shaderDesc);

		// Pipeline.
		WGPUColorTargetState colorTarget = .();
		colorTarget.format = sFormat;
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
		sPipeline = wgpuDeviceCreateRenderPipeline(sDevice, &pipelineDesc);

		wgpuShaderModuleRelease(shader);
	}

	// Called once per browser animation frame.
	static void Frame()
	{
		if (!sReady)
			return; // still waiting on async adapter/device

		WGPUSurfaceTexture surfaceTex = .();
		wgpuSurfaceGetCurrentTexture(sSurface, &surfaceTex);
		if ((surfaceTex.status != .WGPUSurfaceGetCurrentTextureStatus_SuccessOptimal) &&
			(surfaceTex.status != .WGPUSurfaceGetCurrentTextureStatus_SuccessSuboptimal))
		{
			if (surfaceTex.texture != null)
				wgpuTextureRelease(surfaceTex.texture);
			return;
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
		wgpuRenderPassEncoderSetPipeline(pass, sPipeline);
		wgpuRenderPassEncoderDraw(pass, 3, 1, 0, 0);
		wgpuRenderPassEncoderEnd(pass);
		wgpuRenderPassEncoderRelease(pass);

		var cmd = wgpuCommandEncoderFinish(encoder, null);
		wgpuQueueSubmit(sQueue, 1, &cmd);
		// No wgpuSurfacePresent on the web — the browser presents automatically.

		wgpuCommandBufferRelease(cmd);
		wgpuCommandEncoderRelease(encoder);
		wgpuTextureViewRelease(view);
		wgpuTextureRelease(surfaceTex.texture);
	}

	public static void Main()
	{
		sInstance = wgpuCreateInstance(null);

		// Create the surface from the page's <canvas id="canvas">.
		WGPUEmscriptenSurfaceSourceCanvasHTMLSelector fromCanvas = .();
		fromCanvas.chain.sType = WGPUSType_EmscriptenSurfaceSourceCanvasHTMLSelector;
		fromCanvas.selector = .() { data = "#canvas", length = WGPU_STRLEN }; // null-terminated CSS selector

		WGPUSurfaceDescriptor surfaceDesc = .();
		surfaceDesc.nextInChain = (WGPUChainedStruct*)&fromCanvas;
		sSurface = wgpuInstanceCreateSurface(sInstance, &surfaceDesc);

		// Kick off async adapter -> device -> pipeline.
		WGPURequestAdapterOptions adapterOpts = .();
		adapterOpts.compatibleSurface = sSurface;
		adapterOpts.powerPreference = .WGPUPowerPreference_HighPerformance;

		WGPURequestAdapterCallbackInfo adapterCb = .();
		adapterCb.mode = .WGPUCallbackMode_AllowSpontaneous;
		adapterCb.callback = => OnAdapter;
		wgpuInstanceRequestAdapter(sInstance, &adapterOpts, adapterCb);

		// Hand control back to the browser; Frame() runs every animation frame.
		emscripten_set_main_loop(=> Frame, 0, 1);
	}
}
