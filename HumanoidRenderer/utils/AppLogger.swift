//
//  AppLogger.swift
//  HumanoidRenderer
//
//  Created by Voltline on 2026/3/5.
//
//  应用内日志系统，支持在 UI 面板中实时查看日志。
//  线程安全，可从任意线程调用。
//

import Foundation

final class AppLogger: @unchecked Sendable {
    static let shared = AppLogger()

    struct Entry: Identifiable {
        let id = UUID()
        let timestamp: Date
        let level: Level
        let message: String

        enum Level: String {
            case info = "ℹ️"
            case warn = "⚠️"
            case error = "❌"
            case perf = "⏱️"
        }

        var formatted: String {
            let tf = Self.formatter
            return "\(tf.string(from: timestamp)) \(level.rawValue) \(message)"
        }

        private static let formatter: DateFormatter = {
            let f = DateFormatter()
            f.dateFormat = "HH:mm:ss.SSS"
            return f
        }()
    }

    private let lock = NSLock()
    private var _entries: [Entry] = []
    private static let maxEntries = 200

    /// 回调：主线程上通知 UI 刷新（由 View 设置）
    @MainActor var onChange: (() -> Void)?

    var entries: [Entry] {
        lock.lock()
        defer { lock.unlock() }
        return _entries
    }

    func info(_ message: String) { append(.info, message) }
    func warn(_ message: String) { append(.warn, message) }
    func error(_ message: String) { append(.error, message) }
    func perf(_ message: String) { append(.perf, message) }

    func clear() {
        lock.lock()
        _entries.removeAll()
        lock.unlock()
        notifyChange()
    }

    private func append(_ level: Entry.Level, _ message: String) {
        let entry = Entry(timestamp: Date(), level: level, message: message)
        lock.lock()
        _entries.append(entry)
        if _entries.count > Self.maxEntries {
            _entries.removeFirst(_entries.count - Self.maxEntries)
        }
        lock.unlock()
        notifyChange()
    }

    private func notifyChange() {
        Task { @MainActor in
            onChange?()
        }
    }
}
