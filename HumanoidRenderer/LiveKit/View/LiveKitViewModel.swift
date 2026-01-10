//
//  LiveKitViewModel.swift
//  HumanoidRenderer
//
//  Created by Voltline on 2026/1/9.
//

import SwiftUI
import LiveKit
internal import Combine

private let LIVEKIT_WS_URL = "ws://192.168.31.134:7880"
private let API_KEY = "devkey"
private let API_SECRET = "secret"
private let ROOM = "my-room"

@MainActor
final class LiveKitViewModel: ObservableObject {
    @Published var statusText: String = "Idle"
    @Published var remoteVideoTrack: VideoTrack?

    let room = Room()
    let appModel: AppModel
    
    init(appModel: AppModel) {
        self.appModel = appModel
    }

    func connect() {
        statusText = "Connecting…"
        room.add(delegate: self)

        Task {
            do {
                // 生成此次访问用到的JWT
                let token = try LiveKitToken.make(apiKey: API_KEY, apiSecret: API_SECRET, room: ROOM, identity: "vision-pro-viewer", name: "vision-pro-viewer", ttlSeconds: 24 * 60 * 60)
                try await room.connect(url: LIVEKIT_WS_URL, token: token)
                statusText = "Connected. Waiting for remote video…"
            } catch {
                statusText = "Connect failed: \(error)"
            }
        }
    }

    func disconnect() {
        Task { await room.disconnect() }
        remoteVideoTrack = nil
        statusText = "Disconnected"
    }
}

extension LiveKitViewModel: RoomDelegate {

    // v2 常见的发布回调也是 publication 形态
    func room(_ room: Room, participant: RemoteParticipant, didPublishTrack publication: RemoteTrackPublication) {
        statusText = "Remote published: \(publication.name) (\(publication.kind))"
    }

    // 关键：订阅回调用 publication，然后从 publication.track 取真正 Track
    func room(_ room: Room, participant: RemoteParticipant, didSubscribeTrack publication: RemoteTrackPublication) {
        if let video = publication.track as? VideoTrack {
            remoteVideoTrack = video
            statusText = "Subscribed video: \(publication.name)"
            appModel.remoteVideoTrack = video
        }
    }

    func room(_ room: Room, participant: RemoteParticipant, didUnsubscribeTrack publication: RemoteTrackPublication) {
        if let current = remoteVideoTrack,
           let video = publication.track as? VideoTrack,
           video === current {
            remoteVideoTrack = nil
            statusText = "Video unsubscribed"
            appModel.remoteVideoTrack = video
        }
    }

    func room(_ room: Room) {
        remoteVideoTrack = nil
        statusText = "Disconnected"
    }
}
