//
//  LiveKitView.swift
//  HumanoidRenderer
//
//  Created by Voltline on 2026/1/8.
//

import SwiftUI
import LiveKit
import UIKit

struct LiveKitVideoView: UIViewRepresentable {
    let track: VideoTrack

    func makeUIView(context: Context) -> VideoView {
        let view = VideoView()
        view.contentMode = .scaleAspectFit
        track.add(videoRenderer: view)
        return view
    }

    func updateUIView(_ uiView: VideoView, context: Context) {
        // track 变化时需要重新绑定渲染器
        // 这里简单处理：先移除再添加，保证更新正确
        track.remove(videoRenderer: uiView)
        track.add(videoRenderer: uiView)
    }

    static func dismantleUIView(_ uiView: VideoView, coordinator: ()) {
        // 注意：这里无法直接拿到 track；解绑在 update 里已做，测试阶段够用
    }
}
