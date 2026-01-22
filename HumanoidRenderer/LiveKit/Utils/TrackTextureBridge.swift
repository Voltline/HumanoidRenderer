//
//  TrackTextureBridge.swift
//  HumanoidRenderer
//
//  Created by Voltline on 2026/1/10.
//

import Foundation
import LiveKit
import CoreImage
import CoreVideo
import RealityKit
internal import Combine
import AVFoundation
import VideoToolbox

@MainActor
final class TrackTextureBridge: NSObject, ObservableObject, VideoRenderer {
    // MARK: - VideoRenderer required
    var isAdaptiveStreamEnabled: Bool = false
    var adaptiveStreamSize: CGSize = .zero

    // MARK: - Stereo output (REUSED textures)
    @Published private(set) var leftTexture: TextureResource?
    @Published private(set) var rightTexture: TextureResource?

    // MARK: - Internal state
    private var didLogFirstFrame = false

    // MARK: - LiveKit frame callback
    /// 渲染回调，LiveKit 会在后台线程调用此方法
    /// 使用 nonisolated 避免阻塞主线程（UI）
    /// 使用 VideoToolbox 代替 CIContext 进行更加高效的图像转换
    nonisolated func render(
        frame: VideoFrame,
        captureDevice: AVCaptureDevice?,
        captureOptions: VideoCaptureOptions?
    ) {
        // 尝试获取 PixelBuffer
        guard let pixelBuffer = frame.toCVPixelBuffer() else {
            return
        }

        // 使用 VideoToolbox 高效转换 CVPixelBuffer -> CGImage
        // 相比 CIContext，这通常更少涉及 GPU 回读，且开销更低
        var cgImage: CGImage?
        let status = VTCreateCGImageFromCVPixelBuffer(pixelBuffer, options: nil, imageOut: &cgImage)
        
        guard status == noErr, let fullImage = cgImage else {
            print("[TrackTextureBridge] Error: VTCreateCGImageFromCVPixelBuffer failed with status \(status)")
            return
        }

        // 切分画面 (CGImage 裁剪操作是轻量级的元数据操作)
        let width = fullImage.width
        let height = fullImage.height
        let halfHeight = height / 2

        // 注意：CGImage 坐标系原点在左上角 (0,0)
        // 假设输入视频是上下排列：上方是左眼，下方是右眼
        // 左眼 (Top) -> Y: 0
        // 右眼 (Bottom) -> Y: halfHeight
        guard let leftCG = fullImage.cropping(to: CGRect(x: 0, y: 0, width: width, height: halfHeight)),
              let rightCG = fullImage.cropping(to: CGRect(x: 0, y: halfHeight, width: width, height: halfHeight)) else {
            print("[TrackTextureBridge] Error: Failed to crop CGImage")
            return
        }

        // 回到主线程更新 RealityKit 纹理资源
        Task { @MainActor in
            if !self.didLogFirstFrame {
                self.didLogFirstFrame = true
                print("[TrackTextureBridge] First frame arrived and processed via VideoToolbox!")
            }
            self.updateTextures(leftCG: leftCG, rightCG: rightCG)
        }
    }
    
    private func updateTextures(leftCG: CGImage, rightCG: CGImage) {
        do {
            // 处理左眼纹理
            if self.leftTexture == nil {
                // print("[TrackTextureBridge] Initializing Left TextureResource")
                self.leftTexture = try TextureResource(
                    image: leftCG,
                    options: .init(semantic: .color)
                )
            } else {
                try self.leftTexture?.replace(
                    withImage: leftCG,
                    options: .init(semantic: .color)
                )
            }

            // 处理右眼纹理
            if self.rightTexture == nil {
                // print("[TrackTextureBridge] Initializing Right TextureResource")
                self.rightTexture = try TextureResource(
                    image: rightCG,
                    options: .init(semantic: .color)
                )
            } else {
                try self.rightTexture?.replace(
                    withImage: rightCG,
                    options: .init(semantic: .color)
                )
            }
        } catch {
            print("[TrackTextureBridge] Critical: TextureResource update failed: \(error)")
        }
    }
}
