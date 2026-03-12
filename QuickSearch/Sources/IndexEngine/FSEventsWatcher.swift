// FSEventsWatcher.swift — FSEventStream wrapper for APFS/HFS+ real-time monitoring.
//
// PRD §7.2: FSEvents monitor for incremental updates on APFS/HFS+.
//
// Design:
//   - Uses FSEventStreamSetDispatchQueue (macOS 10.6+) — no RunLoop thread needed.
//   - `latency` seconds aggregate window (default 1.0s) per PRD §7.2.
//   - Handler receives the list of changed paths after each quiet window.
//   - Thread-safe: start/stop are safe to call from any thread.

import Foundation
import CoreServices

public final class FSEventsWatcher: @unchecked Sendable {

    public typealias Handler = @Sendable ([String]) -> Void

    private let paths: [String]
    private let latency: TimeInterval
    private let handler: Handler
    private let dispatchQueue: DispatchQueue

    // Protected by `lock`.
    private let lock = NSLock()
    private var stream: FSEventStreamRef?
    private var box: FSCallbackBox?

    public init(paths: [String], latency: TimeInterval = 1.0, handler: @escaping Handler) {
        self.paths = paths
        self.latency = latency
        self.handler = handler
        self.dispatchQueue = DispatchQueue(label: "QuickSearch.FSEvents", qos: .utility)
    }

    deinit { _stop() }

    // MARK: - Public

    /// Start watching. Safe to call multiple times (idempotent).
    public func start() {
        lock.lock()
        defer { lock.unlock() }
        _start()
    }

    /// Stop watching and release resources. Safe to call multiple times.
    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        _stop()
    }

    // MARK: - Private (caller must hold `lock`)

    private func _start() {
        guard stream == nil else { return }

        let capturedHandler = self.handler
        let callbackBox = FSCallbackBox(capturedHandler)
        self.box = callbackBox

        // Pass the box as an unretained pointer; self.box keeps it alive.
        let info = Unmanaged.passUnretained(callbackBox).toOpaque()

        var ctx = FSEventStreamContext(
            version: 0, info: info,
            retain: nil, release: nil, copyDescription: nil
        )

        let cfPaths = paths as CFArray
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents |
            kFSEventStreamCreateFlagNoDefer    |
            kFSEventStreamCreateFlagUseCFTypes
        )

        guard let s = FSEventStreamCreate(
            nil,
            { _, info, _, eventPaths, _, _ in
                guard let info = info else { return }
                let box = Unmanaged<FSCallbackBox>.fromOpaque(info).takeUnretainedValue()
                // kFSEventStreamCreateFlagUseCFTypes → eventPaths is CFArray of CFString.
                let nsArray = Unmanaged<NSArray>.fromOpaque(eventPaths).takeUnretainedValue()
                if let pathList = nsArray as? [String] {
                    box.handler(pathList)
                }
            },
            &ctx,
            cfPaths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            flags
        ) else {
            self.box = nil
            return
        }

        FSEventStreamSetDispatchQueue(s, dispatchQueue)
        FSEventStreamStart(s)
        stream = s
    }

    private func _stop() {
        guard let s = stream else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
        stream = nil
        box = nil
    }
}

// MARK: - Internal callback box

private final class FSCallbackBox: @unchecked Sendable {
    let handler: FSEventsWatcher.Handler
    init(_ handler: @escaping FSEventsWatcher.Handler) { self.handler = handler }
}
