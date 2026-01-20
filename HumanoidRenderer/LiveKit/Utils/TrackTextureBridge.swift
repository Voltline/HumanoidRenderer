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

@MainActor
final class TrackTextureBridge: NSObject, ObservableObject, VideoRenderer {

    // MARK: - VideoRenderer required

    var isAdaptiveStreamEnabled: Bool = false
    var adaptiveStreamSize: CGSize = .zero

    // MARK: - Stereo output (REUSED textures)

    @Published private(set) var leftTexture: TextureResource?
    @Published private(set) var rightTexture: TextureResource?

    // MARK: - Internal state

    private let ciContext = CIContext(options: [CIContextOption.useSoftwareRenderer: false])
    private let colorSpace = CGColorSpaceCreateDeviceRGB()
    private var didLogFirstFrame = false

    // MARK: - LiveKit frame callback

    func render(
        frame: VideoFrame,
        captureDevice: AVCaptureDevice?,
        captureOptions: VideoCaptureOptions?
    ) {
        if !didLogFirstFrame {
            didLogFirstFrame = true
            print("[TrackTextureBridge] First frame arrived!")
        }

        // 1. 尝试获取 PixelBuffer
        guard let pixelBuffer = frame.toCVPixelBuffer() else {
            print("[TrackTextureBridge] Error: Failed to convert VideoFrame to CVPixelBuffer")
            return
        }

        // 2. 切分画面
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let fullRect = ciImage.extent
        let halfHeight = fullRect.height / 2.0

        // Top -> Left Eye, Bottom -> Right Eye
        let topRect = CGRect(
            x: fullRect.origin.x,
            y: fullRect.origin.y + halfHeight,
            width: fullRect.width,
            height: halfHeight
        )
        let bottomRect = CGRect(
            x: fullRect.origin.x,
            y: fullRect.origin.y,
            width: fullRect.width,
            height: halfHeight
        )

        let leftCI = ciImage.cropped(to: topRect)
        let rightCI = ciImage.cropped(to: bottomRect)

        // 3. 将耗时的 CGImage 创建放在非主线程处理，避免渲染掉帧
        // 注意：ciContext 是线程安全的
        guard let leftCG = ciContext.createCGImage(leftCI, from: leftCI.extent, format: .RGBA8, colorSpace: colorSpace),
              let rightCG = ciContext.createCGImage(rightCI, from: rightCI.extent, format: .RGBA8, colorSpace: colorSpace) else {
            print("[TrackTextureBridge] Error: Failed to create CGImages from cropped CIImages")
            return
        }

        // 4. 回到主线程更新 RealityKit 纹理资源
        Task { @MainActor in
            do {
                // 处理左眼纹理
                if self.leftTexture == nil {
                    print("[TrackTextureBridge] Initializing Left TextureResource")
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
                    print("[TrackTextureBridge] Initializing Right TextureResource")
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
}
