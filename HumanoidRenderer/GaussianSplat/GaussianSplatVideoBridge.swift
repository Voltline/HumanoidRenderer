//
//  GaussianSplatVideoBridge.swift
//  HumanoidRenderer
//
//  Created by Voltline on 2026/3/4.
//
//  简化版视频桥接，用于 CompositorServices 渲染管线。
//  接收 LiveKit VideoTrack 的帧数据，通过 Metal Compute Shader
//  将 NV12 (YUV) 转换为 RGBA 纹理，供 GaussianSplatRenderer 使用。
//

import Foundation
import Metal
import MetalKit
import LiveKit
import CoreVideo
import AVFoundation

final class GaussianSplatVideoBridge: NSObject, @unchecked Sendable, VideoRenderer {
    // MARK: - VideoRenderer 协议要求
    var isAdaptiveStreamEnabled: Bool = false
    var adaptiveStreamSize: CGSize = .zero
    
    // MARK: - Metal
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipelineState: MTLComputePipelineState
    private var textureCache: CVMetalTextureCache?
    
    // MARK: - 输出纹理 (RGBA)
    private var _leftTexture: MTLTexture?
    private var _rightTexture: MTLTexture?
    private let lock = NSLock()
    
    // 是否已经收到过至少一帧
    private(set) var hasTexture: Bool = false
    
    /// 获取当前左眼 RGBA 纹理 (线程安全)
    var currentTexture: MTLTexture? {
        lock.lock()
        defer { lock.unlock() }
        return _leftTexture
    }
    
    /// 获取当前右眼 RGBA 纹理 (线程安全)
    var rightTexture: MTLTexture? {
        lock.lock()
        defer { lock.unlock() }
        return _rightTexture
    }
    
    init(device: MTLDevice) {
        self.device = device
        self.commandQueue = device.makeCommandQueue()!
        
        // 加载 YUV→RGB compute shader (复用现有的 nvl2ToRgba)
        let library = device.makeDefaultLibrary()!
        let function = library.makeFunction(name: "nvl2ToRgba")!
        self.pipelineState = try! device.makeComputePipelineState(function: function)
        
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache)
        
        super.init()
        
        // 创建初始输出纹理
        createOutputTextures(width: 1920, height: 1080)
    }
    
    private func createOutputTextures(width: Int, height: Int) {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm_srgb,
            width: width,
            height: height,
            mipmapped: false
        )
        desc.usage = [.shaderRead, .shaderWrite]
        desc.storageMode = .private
        
        lock.lock()
        _leftTexture = device.makeTexture(descriptor: desc)
        _rightTexture = device.makeTexture(descriptor: desc)
        lock.unlock()
    }
    
    // MARK: - 从 PixelBuffer 创建 Metal 纹理
    private func makeTexture(from pixelBuffer: CVPixelBuffer, planeIndex: Int, pixelFormat: MTLPixelFormat) -> MTLTexture? {
        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, planeIndex)
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, planeIndex)
        
        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache!,
            pixelBuffer,
            nil,
            pixelFormat,
            width,
            height,
            planeIndex,
            &cvTexture
        )
        
        if status == kCVReturnSuccess, let cvTexture = cvTexture {
            return CVMetalTextureGetTexture(cvTexture)
        }
        return nil
    }
    
    private func dispatch(encoder: MTLComputeCommandEncoder, targetTexture: MTLTexture) {
        let w = pipelineState.threadExecutionWidth
        let h = pipelineState.maxTotalThreadsPerThreadgroup / w
        let threadsPerGroup = MTLSize(width: w, height: h, depth: 1)
        
        let groups = MTLSize(
            width: (targetTexture.width + w - 1) / w,
            height: (targetTexture.height + h - 1) / h,
            depth: 1
        )
        encoder.dispatchThreadgroups(groups, threadsPerThreadgroup: threadsPerGroup)
    }
    
    // MARK: - LiveKit 帧回调
    func render(
        frame: VideoFrame,
        captureDevice: AVCaptureDevice?,
        captureOptions: VideoCaptureOptions?
    ) {
        guard let pixelBuffer = frame.toCVPixelBuffer() else { return }
        
        guard let yTexture = makeTexture(from: pixelBuffer, planeIndex: 0, pixelFormat: .r8Unorm),
              let uvTexture = makeTexture(from: pixelBuffer, planeIndex: 1, pixelFormat: .rg8Unorm) else {
            return
        }
        
        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return }
        
        lock.lock()
        let leftTex = _leftTexture
        let rightTex = _rightTexture
        lock.unlock()
        
        guard let leftTex, let rightTex else { return }
        
        // 处理左眼 (上半)
        if let encoder = commandBuffer.makeComputeCommandEncoder() {
            encoder.setComputePipelineState(pipelineState)
            encoder.setTexture(yTexture, index: 0)
            encoder.setTexture(uvTexture, index: 1)
            encoder.setTexture(leftTex, index: 2)
            var normOffset: Float = 0.0
            encoder.setBytes(&normOffset, length: MemoryLayout<Float>.size, index: 0)
            dispatch(encoder: encoder, targetTexture: leftTex)
            encoder.endEncoding()
        }
        
        // 处理右眼 (下半)
        if let encoder = commandBuffer.makeComputeCommandEncoder() {
            encoder.setComputePipelineState(pipelineState)
            encoder.setTexture(yTexture, index: 0)
            encoder.setTexture(uvTexture, index: 1)
            encoder.setTexture(rightTex, index: 2)
            var normOffset: Float = 0.5
            encoder.setBytes(&normOffset, length: MemoryLayout<Float>.size, index: 0)
            dispatch(encoder: encoder, targetTexture: rightTex)
            encoder.endEncoding()
        }
        
        commandBuffer.commit()
        
        hasTexture = true
    }
}
