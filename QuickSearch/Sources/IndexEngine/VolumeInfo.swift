// VolumeInfo.swift — Volume metadata via Foundation URL resource values + statfs.

import Foundation
import Darwin

public struct VolumeInfo: Sendable {
    public let uuid: String          // Stable identifier
    public let name: String
    public let mountPath: String
    public let fsType: String
    public let totalSize: Int64
    public let isExternal: Bool

    /// Fetch volume info for the volume that contains `url`.
    public static func forURL(_ url: URL) throws -> VolumeInfo {
        let keys: Set<URLResourceKey> = [
            .volumeUUIDStringKey,
            .volumeNameKey,
            .volumeTotalCapacityKey,
            .volumeIsLocalKey,
        ]
        let resourceValues = try url.resourceValues(forKeys: keys)

        // Resolve mount path via statfs (reliable cross-filesystem)
        let mountPath = mountPoint(for: url.path)

        // UUID — stable across reboots; fall back to mount path hash if unavailable (exFAT/FAT32)
        let uuid: String
        if let v = resourceValues.volumeUUIDString, !v.isEmpty {
            uuid = v
        } else {
            uuid = "synthetic-\(mountPath.hashValue)"
        }

        let name = resourceValues.volumeName ?? "Unknown"
        let totalSize = Int64(resourceValues.volumeTotalCapacity ?? 0)
        let isLocal = resourceValues.volumeIsLocal ?? true
        let isExternal = !isLocal
        let fsType = filesystemType(at: mountPath)

        return VolumeInfo(
            uuid: uuid,
            name: name,
            mountPath: mountPath,
            fsType: fsType,
            totalSize: totalSize,
            isExternal: isExternal
        )
    }

    /// Enumerate all currently mounted volumes.
    public static func allMounted() -> [VolumeInfo] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [
            .volumeUUIDStringKey,
            .volumeNameKey,
            .volumeTotalCapacityKey,
            .volumeIsLocalKey,
        ]
        guard let urls = fm.mountedVolumeURLs(
            includingResourceValuesForKeys: keys,
            options: [.skipHiddenVolumes]
        ) else { return [] }

        return urls.compactMap { url in try? VolumeInfo.forURL(url) }
    }
}

// MARK: - Helpers

private func mountPoint(for path: String) -> String {
    var buf = statfs()
    guard statfs(path, &buf) == 0 else { return "/" }
    return withUnsafeBytes(of: buf.f_mntonname) { raw in
        let ptr = raw.bindMemory(to: CChar.self).baseAddress!
        return String(cString: ptr)
    }
}

private func filesystemType(at path: String) -> String {
    var buf = statfs()
    guard statfs(path, &buf) == 0 else { return "unknown" }
    return withUnsafeBytes(of: buf.f_fstypename) { raw in
        let ptr = raw.bindMemory(to: CChar.self).baseAddress!
        return String(cString: ptr)
    }
}
