//
//  LiveKitViewModel.swift
//  HumanoidRenderer
//
//  Created by Voltline on 2026/1/9.
//

import SwiftUI
import LiveKit
internal import Combine

private let API_KEY = "devkey"
private let API_SECRET = "secret"
private let ROOM = "my-room"

@MainActor
final class LiveKitViewModel: ObservableObject {
    @Published var statusText: String = "Idle"
    @Published var remoteVideoTrack: VideoTrack?

    let room = Room()
    let appModel: AppModel
    private var latencyProbeTask: Task<Void, Never>?
    
    init(appModel: AppModel) {
        self.appModel = appModel
    }

    func connect(serverIP: String) {
        statusText = "Connecting…"
        room.add(delegate: self)
        stopLatencyProbe()

        Task {
            do {
                // 生成此次访问用到的JWT
                let token = try LiveKitToken.make(apiKey: API_KEY, apiSecret: API_SECRET, room: ROOM, identity: "vision-pro-viewer", name: "vision-pro-viewer", ttlSeconds: 24 * 60 * 60)
                try await room.connect(url: "ws://\(serverIP):7880", token: token)
                statusText = "Connected. Waiting for remote video…"
                startLatencyProbe(serverIP: serverIP)
            } catch {
                statusText = "Connect failed: \(error)"
            }
        }
    }

    func disconnect() {
        stopLatencyProbe()
        Task { await room.disconnect() }
        remoteVideoTrack = nil
        statusText = "Disconnected"
    }

    deinit {
        latencyProbeTask?.cancel()
    }

    private func startLatencyProbe(serverIP: String) {
        stopLatencyProbe()
        latencyProbeTask = Task.detached(priority: .utility) {
            guard let url = URL(string: "http://\(serverIP):30000/latency/ping") else { return }
            let session = URLSession(configuration: .ephemeral)

            while !Task.isCancelled {
                var request = URLRequest(url: url)
                request.httpMethod = "GET"
                request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
                request.timeoutInterval = 2.0

                let clientSendUnixMs = Date().timeIntervalSince1970 * 1000.0
                let reqStartNs = DispatchTime.now().uptimeNanoseconds
                do {
                    let (data, _) = try await session.data(for: request)
                    let clientRecvUnixMs = Date().timeIntervalSince1970 * 1000.0
                    let rttMs = Double(DispatchTime.now().uptimeNanoseconds - reqStartNs) / 1_000_000.0
                    if let jsonObject = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let serverUnixMs = Self.parseDouble(jsonObject["server_unix_ms"]) {
                        await LatencyMetrics.shared.updateClockSync(
                            serverUnixMs: serverUnixMs,
                            clientSendUnixMs: clientSendUnixMs,
                            clientRecvUnixMs: clientRecvUnixMs
                        )
                    }
                    await LatencyMetrics.shared.recordVideoDownEstimate(rttMs: rttMs)
                } catch {
                    // 网络短暂抖动时忽略本次采样，继续下一轮
                }

                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private func stopLatencyProbe() {
        latencyProbeTask?.cancel()
        latencyProbeTask = nil
    }

    nonisolated private static func parseDouble(_ value: Any?) -> Double? {
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        if let n = value as? NSNumber { return n.doubleValue }
        return nil
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
            Task { @MainActor in
                remoteVideoTrack = video
                statusText = "Subscribed video: \(publication.name)"
                appModel.remoteVideoTrack = video
            }
        }
    }

    func room(_ room: Room, participant: RemoteParticipant, didUnsubscribeTrack publication: RemoteTrackPublication) {
        if let current = remoteVideoTrack,
           let video = publication.track as? VideoTrack,
           video === current {
            Task { @MainActor in
                remoteVideoTrack = nil
                statusText = "Video unsubscribed"
            }
            appModel.remoteVideoTrack = video
        }
    }

    func room(_ room: Room) {
        stopLatencyProbe()
        remoteVideoTrack = nil
        statusText = "Disconnected"
    }
}
