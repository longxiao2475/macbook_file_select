// DiskArbitrationMonitor.swift — Detects external drive mount/unmount via DiskArbitration.
//
// PRD §7.3: trigger incremental update on DiskArbitration mount events.
//
// Design:
//   - Uses DASession scheduled on a private DispatchQueue.
//   - Fires handler with `appeared` (mount) or `disappeared` (unmount) events.
//   - Only reports volumes with a valid mount path (filters system pseudo-disks).

import Foundation
import DiskArbitration

public final class DiskArbitrationMonitor: @unchecked Sendable {

    public typealias Handler = @Sendable (DiskEvent) -> Void

    public enum DiskEvent: Sendable {
        case appeared(mountPath: String, bsdName: String, fsType: String)
        case disappeared(bsdName: String, lastMountPath: String)
    }

    private var session: DASession?
    private let queue: DispatchQueue
    private let handler: Handler
    private let lock = NSLock()

    // Track mount paths for disappeared events (DADisk doesn't carry path on disappear).
    private var mountPaths: [String: String] = [:]   // bsdName → mountPath
    private var box: DACallbackBox?

    public init(handler: @escaping Handler) {
        self.queue = DispatchQueue(label: "QuickSearch.DiskArbitration", qos: .utility)
        self.handler = handler
    }

    deinit { stop() }

    // MARK: - Public

    /// Begin listening for disk events. Safe to call multiple times.
    public func start() {
        lock.lock()
        defer { lock.unlock() }
        guard session == nil else { return }

        guard let s = DASessionCreate(kCFAllocatorDefault) else { return }

        let callbackBox = DACallbackBox(monitor: self)
        self.box = callbackBox
        session = s

        let info = Unmanaged.passUnretained(callbackBox).toOpaque()

        // Appeared callback.
        DARegisterDiskAppearedCallback(
            s, nil,
            { disk, ctx in
                guard let ctx = ctx else { return }
                let box = Unmanaged<DACallbackBox>.fromOpaque(ctx).takeUnretainedValue()
                box.diskAppeared(disk)
            },
            info
        )

        // Disappeared callback.
        DARegisterDiskDisappearedCallback(
            s, nil,
            { disk, ctx in
                guard let ctx = ctx else { return }
                let box = Unmanaged<DACallbackBox>.fromOpaque(ctx).takeUnretainedValue()
                box.diskDisappeared(disk)
            },
            info
        )

        DASessionSetDispatchQueue(s, queue)
    }

    /// Stop listening and release the DA session.
    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        guard let s = session else { return }
        DASessionSetDispatchQueue(s, nil)
        session = nil
        box = nil
    }

    // MARK: - Internal (called from DACallbackBox on the DA queue)

    fileprivate func handleAppeared(_ disk: DADisk) {
        guard let desc = DADiskCopyDescription(disk) as? [String: AnyObject],
              let mountURL = desc[kDADiskDescriptionVolumePathKey as String] as? URL,
              let fsType = desc[kDADiskDescriptionVolumeKindKey as String] as? String else {
            return  // System pseudo-disk or not yet mounted
        }

        let mountPath = mountURL.path
        guard !mountPath.isEmpty else { return }

        let bsdName: String
        if let name = DADiskGetBSDName(disk) {
            bsdName = String(cString: name)
        } else {
            bsdName = "unknown"
        }

        lock.lock()
        mountPaths[bsdName] = mountPath
        lock.unlock()

        handler(.appeared(mountPath: mountPath, bsdName: bsdName, fsType: fsType))
    }

    fileprivate func handleDisappeared(_ disk: DADisk) {
        let bsdName: String
        if let name = DADiskGetBSDName(disk) {
            bsdName = String(cString: name)
        } else {
            bsdName = "unknown"
        }

        lock.lock()
        let lastMount = mountPaths.removeValue(forKey: bsdName) ?? ""
        lock.unlock()

        handler(.disappeared(bsdName: bsdName, lastMountPath: lastMount))
    }
}

// MARK: - Internal callback box

private final class DACallbackBox: @unchecked Sendable {
    weak var monitor: DiskArbitrationMonitor?
    init(monitor: DiskArbitrationMonitor) { self.monitor = monitor }

    func diskAppeared(_ disk: DADisk) { monitor?.handleAppeared(disk) }
    func diskDisappeared(_ disk: DADisk) { monitor?.handleDisappeared(disk) }
}
