//
//  GaussianSplatRenderer.swift
//  HumanoidRenderer
//
//  Created by Voltline on 2026/3/4.
//
//  基于 CompositorServices 的 3D Gaussian Splatting 背景渲染器。
//  参考 MetalSplatter SampleApp 的 VisionSceneRenderer 编写。
//  负责：
//    1. 加载并渲染 .ply/.splat/.spz 格式的 3DGS 场景作为沉浸式背景
//    2. 在前景绘制视频串流 quad (复用 TrackTextureBridge 的纹理)
//    3. 头部追踪 → 云台跟随
//

import CompositorServices
import Metal
import MetalSplatter
import SplatIO
import ARKit
import simd
import os
import LiveKit
import AVFoundation
import CoreVideo

// MARK: - 渲染器视口描述 (与 MetalSplatter 的 ViewportDescriptor 对应)
struct SplatViewportDescriptor {
    var viewport: MTLViewport
    var projectionMatrix: simd_float4x4
    var viewMatrix: simd_float4x4
    var screenSize: SIMD2<Int>
}

// MARK: - VideoQuad Uniforms (与 Metal shader 对齐)
struct VideoQuadUniforms {
    var modelViewProjection: (simd_float4x4, simd_float4x4) = (matrix_identity_float4x4, matrix_identity_float4x4)
}

// MARK: - GaussianSplatRenderer
final class GaussianSplatRenderer: @unchecked Sendable {
    private static let log = Logger(
        subsystem: Bundle.main.bundleIdentifier!,
        category: "GaussianSplatRenderer"
    )
    
    private static let maxSimultaneousRenders = 3
    
    // MARK: Metal 核心对象
    let layerRenderer: LayerRenderer
    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    
    // MARK: 3DGS 渲染
    private var splatRenderer: SplatRenderer?
    
    // MARK: 视频 Quad 渲染管线
    private var videoQuadPipelineState: MTLRenderPipelineState?
    
    // MARK: 视频纹理桥接 (复用 TrackTextureBridge 的 YUV→RGB 逻辑)
    private let videoBridge: GaussianSplatVideoBridge
    
    // MARK: ARKit
    let arSession: ARKitSession
    let worldTracking: WorldTrackingProvider
    
    // MARK: 头部追踪 → 云台跟随
    private var gimbalClient: GimbalClient?
    private var lastYaw: Float = 0.0
    private var lastPitch: Float = 0.0
    private var hasBaseline: Bool = false
    
    // MARK: 并发控制
    let inFlightSemaphore: DispatchSemaphore
    
    // MARK: 对外 flag: 是否有视频轨道
    private var boundTrack: VideoTrack?
    
    // MARK: AppModel 引用
    private var appModel: AppModel?
    
    // MARK: 服务器 IP
    private let serverIP: String
    
    init(_ layerRenderer: LayerRenderer, serverIP: String) {
        self.layerRenderer = layerRenderer
        self.device = layerRenderer.device
        self.commandQueue = device.makeCommandQueue()!
        self.serverIP = serverIP
        
        self.worldTracking = WorldTrackingProvider()
        self.arSession = ARKitSession()
        
        self.inFlightSemaphore = DispatchSemaphore(value: Self.maxSimultaneousRenders)
        
        self.videoBridge = GaussianSplatVideoBridge(device: device)
        
        // 构建视频 Quad 渲染管线
        buildVideoQuadPipeline()
    }
    
    // MARK: - 静态入口
    nonisolated static func startRendering(
        _ layerRenderer: LayerRenderer,
        splatURL: URL?,
        appModel: AppModel?,
        serverIP: String
    ) {
        let renderer = GaussianSplatRenderer(layerRenderer, serverIP: serverIP)
        renderer.appModel = appModel
        
        Task {
            // 加载 3DGS 场景
            if let url = splatURL {
                do {
                    try await renderer.loadSplatScene(url: url)
                } catch {
                    log.error("加载 3DGS 场景失败: \(error.localizedDescription)")
                }
            }
            
            // 启动渲染循环
            renderer.startRenderLoop()
        }
    }
    
    // MARK: - 加载 3DGS 场景
    func loadSplatScene(url: URL) async throws {
        Self.log.info("开始加载 3DGS 场景: \(url.lastPathComponent)")
        
        let splat = try SplatRenderer(
            device: device,
            colorFormat: layerRenderer.configuration.colorFormat,
            depthFormat: layerRenderer.configuration.depthFormat,
            sampleCount: 1,
            maxViewCount: layerRenderer.properties.viewCount,
            maxSimultaneousRenders: Self.maxSimultaneousRenders
        )
        
        let reader = try AutodetectSceneReader(url)
        let points = try await reader.readAll()
        let chunk = try SplatChunk(device: device, from: points)
        await splat.addChunk(chunk)
        
        self.splatRenderer = splat
        Self.log.info("3DGS 场景加载完成，共 \(points.count) 个 splat")
    }
    
    // MARK: - 构建视频 Quad 管线
    private func buildVideoQuadPipeline() {
        guard let library = device.makeDefaultLibrary() else {
            Self.log.error("无法获取默认 Metal 库")
            return
        }
        
        guard let vertexFunc = library.makeFunction(name: "videoQuadVertexShader"),
              let fragmentFunc = library.makeFunction(name: "videoQuadFragmentShader") else {
            Self.log.error("无法找到视频 Quad 着色器")
            return
        }
        
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = vertexFunc
        desc.fragmentFunction = fragmentFunc
        desc.colorAttachments[0].pixelFormat = layerRenderer.configuration.colorFormat
        desc.depthAttachmentPixelFormat = layerRenderer.configuration.depthFormat
        
        // 启用 Alpha 混合，让视频 quad 可以正确叠加在 splat 上
        desc.colorAttachments[0].isBlendingEnabled = true
        desc.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        desc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        desc.colorAttachments[0].sourceAlphaBlendFactor = .one
        desc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        
        // 支持 layered 渲染 (立体双目)
        if layerRenderer.configuration.layout == .layered {
            desc.inputPrimitiveTopology = .triangle
            desc.maxVertexAmplificationCount = layerRenderer.properties.viewCount
        }
        desc.rasterSampleCount = 1
        
        do {
            videoQuadPipelineState = try device.makeRenderPipelineState(descriptor: desc)
        } catch {
            Self.log.error("构建视频 Quad 管线失败: \(error)")
        }
    }
    
    // MARK: - 绑定视频轨道
    func bindVideoTrack(_ track: VideoTrack?) {
        if let old = boundTrack {
            old.remove(videoRenderer: videoBridge)
        }
        if let t = track {
            t.add(videoRenderer: videoBridge)
        }
        boundTrack = track
    }
    
    // MARK: - 渲染循环
    func startRenderLoop() {
        Task(executorPreference: GaussianSplatTaskExecutor.shared) { [self] in
            do {
                try await self.arSession.run([self.worldTracking])
            } catch {
                Self.log.error("ARKit 会话启动失败: \(error)")
                return
            }
            
            // 初始化云台
            let client = GimbalClient(serverIP: self.serverIP)
            self.gimbalClient = client
            
            self.renderLoop()
        }
    }
    
    private func renderLoop() {
        while true {
            autoreleasepool {
                if layerRenderer.state == .invalidated {
                    Self.log.warning("LayerRenderer 已失效")
                    return
                } else if layerRenderer.state == .paused {
                    layerRenderer.waitUntilRunning()
                    return
                } else {
                    renderFrame()
                }
            }
            if layerRenderer.state == .invalidated {
                return
            }
        }
    }
    
    // MARK: - 单帧渲染
    private func renderFrame() {
        guard let frame = layerRenderer.queryNextFrame() else { return }
        
        frame.startUpdate()
        // 检查视频轨道变化
        updateVideoTrackBinding()
        frame.endUpdate()
        
        guard let timing = frame.predictTiming() else { return }
        LayerRenderer.Clock().wait(until: timing.optimalInputTime)
        
        let drawables = frame.queryDrawables()
        guard !drawables.isEmpty else { return }
        
        // 如果 splat 渲染器还没准备好，仅提交空帧
        guard let splatRenderer, splatRenderer.isReadyToRender else {
            frame.startSubmission()
            for drawable in drawables {
                guard let commandBuffer = commandQueue.makeCommandBuffer() else { continue }
                drawable.encodePresent(commandBuffer: commandBuffer)
                commandBuffer.commit()
            }
            frame.endSubmission()
            return
        }
        
        _ = inFlightSemaphore.wait(timeout: .distantFuture)
        
        frame.startSubmission()
        
        let primaryDrawable = drawables[0]
        let time = LayerRenderer.Clock.Instant.epoch.duration(to: primaryDrawable.frameTiming.presentationTime).timeInterval
        let deviceAnchor = worldTracking.queryDeviceAnchor(atTimestamp: time)
        
        // 头部追踪 → 云台跟随
        performHeadTracking(deviceAnchor: deviceAnchor)
        
        let layered = layerRenderer.configuration.layout == .layered
        
        for (index, drawable) in drawables.enumerated() {
            guard let commandBuffer = commandQueue.makeCommandBuffer() else { continue }
            
            drawable.deviceAnchor = deviceAnchor
            
            if index == drawables.count - 1 {
                let semaphore = inFlightSemaphore
                commandBuffer.addCompletedHandler { _ in
                    semaphore.signal()
                }
            }
            
            let viewports = buildViewports(drawable: drawable, deviceAnchor: deviceAnchor)
            
            // 第一步：渲染 3DGS 背景
            do {
                let msViewports = viewports.map { vp in
                    SplatRenderer.ViewportDescriptor(
                        viewport: vp.viewport,
                        projectionMatrix: vp.projectionMatrix,
                        viewMatrix: vp.viewMatrix,
                        screenSize: vp.screenSize
                    )
                }
                
                try splatRenderer.render(
                    viewports: msViewports,
                    colorTexture: drawable.colorTextures[0],
                    colorStoreAction: .store,
                    depthTexture: drawable.depthTextures[0],
                    rasterizationRateMap: drawable.rasterizationRateMaps.first,
                    renderTargetArrayLength: layered ? drawable.views.count : 1,
                    to: commandBuffer
                )
            } catch {
                Self.log.error("3DGS 渲染失败: \(error.localizedDescription)")
            }
            
            // 第二步：在 splat 上叠加视频 Quad (如果有视频流)
            if videoBridge.hasTexture, let pipelineState = videoQuadPipelineState {
                renderVideoQuad(
                    commandBuffer: commandBuffer,
                    drawable: drawable,
                    viewports: viewports,
                    pipelineState: pipelineState,
                    layered: layered
                )
            }
            
            drawable.encodePresent(commandBuffer: commandBuffer)
            commandBuffer.commit()
        }
        
        frame.endSubmission()
    }
    
    // MARK: - 构建视口
    private func buildViewports(
        drawable: LayerRenderer.Drawable,
        deviceAnchor: DeviceAnchor?
    ) -> [SplatViewportDescriptor] {
        let simdDeviceAnchor = deviceAnchor?.originFromAnchorTransform ?? matrix_identity_float4x4
        
        // 将视点下移到场景内部（大约人眼高度 1.5m）
        // 如果场景原点在地面附近，用户的 ARKit 头部高度 ~1.7m 会导致视角浮在上方
        // 这个偏移量让 splat 场景整体上移，等效于把用户"放进"房间里
        let sceneOffset = simd_float4x4(
            SIMD4<Float>(1, 0, 0, 0),
            SIMD4<Float>(0, 1, 0, 0),
            SIMD4<Float>(0, 0, 1, 0),
            SIMD4<Float>(0, 1.5, 0, 1)  // Y 方向上移 1.5m
        )
        
        return drawable.views.enumerated().map { (index, view) in
            let userViewpointMatrix = (simdDeviceAnchor * view.transform).inverse
            let projectionMatrix = drawable.computeProjection(viewIndex: index)
            let screenSize = SIMD2(
                x: Int(view.textureMap.viewport.width),
                y: Int(view.textureMap.viewport.height)
            )
            
            return SplatViewportDescriptor(
                viewport: view.textureMap.viewport,
                projectionMatrix: projectionMatrix,
                viewMatrix: userViewpointMatrix * sceneOffset,
                screenSize: screenSize
            )
        }
    }
    
    // MARK: - 渲染视频 Quad
    private func renderVideoQuad(
        commandBuffer: MTLCommandBuffer,
        drawable: LayerRenderer.Drawable,
        viewports: [SplatViewportDescriptor],
        pipelineState: MTLRenderPipelineState,
        layered: Bool
    ) {
        let renderPassDesc = MTLRenderPassDescriptor()
        renderPassDesc.colorAttachments[0].texture = drawable.colorTextures[0]
        renderPassDesc.colorAttachments[0].loadAction = .load  // 保留 splat 渲染结果
        renderPassDesc.colorAttachments[0].storeAction = .store
        renderPassDesc.depthAttachment.texture = drawable.depthTextures[0]
        renderPassDesc.depthAttachment.loadAction = .load
        renderPassDesc.depthAttachment.storeAction = .store
        
        if layered {
            renderPassDesc.renderTargetArrayLength = drawable.views.count
        }
        
        if let rasterizationRateMap = drawable.rasterizationRateMaps.first {
            renderPassDesc.rasterizationRateMap = rasterizationRateMap
        }
        
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDesc) else { return }
        
        encoder.setRenderPipelineState(pipelineState)
        
        // 构建 MVP 矩阵 (视频面板放在头部前方)
        var uniforms = VideoQuadUniforms()
        for (i, vp) in viewports.prefix(2).enumerated() {
            // 使用设备锚点的逆矩阵作为 view matrix，面板在世界空间 z=-2 处
            let mvp = vp.projectionMatrix * vp.viewMatrix
            if i == 0 { uniforms.modelViewProjection.0 = mvp }
            else { uniforms.modelViewProjection.1 = mvp }
        }
        
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<VideoQuadUniforms>.size, index: 0)
        
        // 绑定左眼纹理 (当前简化: 左右眼使用同一画面)
        if let tex = videoBridge.currentTexture {
            encoder.setFragmentTexture(tex, index: 0)
        }
        
        if layered {
            // 使用 vertex amplification 为双眼渲染
            var viewMappings = (0..<drawable.views.count).map {
                MTLVertexAmplificationViewMapping(
                    viewportArrayIndexOffset: UInt32($0),
                    renderTargetArrayIndexOffset: UInt32($0)
                )
            }
            encoder.setVertexAmplificationCount(drawable.views.count, viewMappings: &viewMappings)
        }
        
        for vp in viewports {
            encoder.setViewport(vp.viewport)
        }
        
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        encoder.endEncoding()
    }
    
    // MARK: - 头部追踪 → 云台跟随
    private func performHeadTracking(deviceAnchor: DeviceAnchor?) {
        guard let anchor = deviceAnchor else { return }
        
        // 只在 live 阶段执行
        guard let appModel, appModel.phase == .live else { return }
        
        let quat = simd_quatf(anchor.originFromAnchorTransform)
        let euler = quat.toEulerAngles()
        
        if !hasBaseline {
            lastYaw = euler.y
            lastPitch = euler.x
            hasBaseline = true
            return
        }
        
        let deltaYaw = euler.y - lastYaw
        let deltaPitch = euler.x - lastPitch
        
        // 突变过滤
        if abs(deltaYaw) > 0.78 || abs(deltaPitch) > 0.78 {
            lastYaw = euler.y
            lastPitch = euler.x
            return
        }
        
        lastYaw = euler.y
        lastPitch = euler.x
        
        Task {
            try? await gimbalClient?.sendDelta(yaw: deltaYaw, pitch: -deltaPitch)
        }
    }
    
    // MARK: - 视频轨道绑定更新
    private func updateVideoTrackBinding() {
        guard let appModel else { return }
        let newTrack = appModel.remoteVideoTrack
        
        if boundTrack !== newTrack {
            bindVideoTrack(newTrack)
        }
    }
}

// MARK: - LayerRenderer.Clock 扩展
extension LayerRenderer.Clock.Instant.Duration {
    var timeInterval: TimeInterval {
        let nanoseconds = TimeInterval(components.attoseconds / 1_000_000_000)
        return TimeInterval(components.seconds) + (nanoseconds / TimeInterval(NSEC_PER_SEC))
    }
}

// MARK: - Collection 安全下标
extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

// MARK: - 渲染线程 Executor
final class GaussianSplatTaskExecutor: TaskExecutor {
    static let shared = GaussianSplatTaskExecutor()
    private let queue = DispatchQueue(label: "GaussianSplatRenderQueue", qos: .userInteractive)
    
    func enqueue(_ job: UnownedJob) {
        queue.async {
            job.runSynchronously(on: self.asUnownedSerialExecutor())
        }
    }
    
    nonisolated func asUnownedSerialExecutor() -> UnownedTaskExecutor {
        UnownedTaskExecutor(ordinary: self)
    }
}
