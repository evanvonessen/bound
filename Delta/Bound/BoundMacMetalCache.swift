import Foundation
import Darwin
import os

/// RunningBoard can suspend an iOS app on Mac while Metal retains its shader-cache
/// lock. Keep that framework-owned cache inside the app container, where locks
/// are permitted during suspension, without changing the renderer or Metal APIs.
enum BoundMacMetalCache {
    enum Outcome: Equatable {
        case created
        case migrated
        case alreadyConfigured
        case preservedPreviousCache(URL)
    }

    enum CacheError: LocalizedError {
        case invalidLocation
        case unexpectedItem
        case unexpectedSymbolicLink
        case rollbackFailed

        var errorDescription: String? {
            switch self {
            case .invalidLocation: return "The Metal cache location is invalid."
            case .unexpectedItem: return "An existing Metal cache item is not a directory."
            case .unexpectedSymbolicLink: return "An existing Metal cache symbolic link has an unexpected destination."
            case .rollbackFailed: return "The original Metal cache could not be restored; its contents remain preserved at the migration destination."
            }
        }
    }

    private static let logger = Logger(subsystem: "com.evanvonessen.bound", category: "MacMetalCache")

    /// Call before UIApplicationMain: UIKit, Core Image, and game views can all
    /// initialize Metal. The runtime guard deliberately has no Simulator override.
    static func configureIfNeeded() {
        guard ProcessInfo.processInfo.isiOSAppOnMac else { return }
        do {
            guard let identifier = Bundle.main.bundleIdentifier,
                  !identifier.isEmpty, identifier != ".", identifier != "..",
                  !identifier.contains("/"),
                  let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
                throw CacheError.invalidLocation
            }
            let length = confstr(_CS_DARWIN_USER_CACHE_DIR, nil, 0)
            guard length > 1 else { throw CacheError.invalidLocation }
            var path = [CChar](repeating: 0, count: length)
            let actualLength = confstr(_CS_DARWIN_USER_CACHE_DIR, &path, path.count)
            guard actualLength > 1, actualLength <= path.count else { throw CacheError.invalidLocation }
            // The Darwin directory may already include an app sandbox suffix.
            // Metal appends the bundle ID itself; do not strip or duplicate it here.
            let cachePath = String(decoding: path.prefix(actualLength - 1).map { UInt8(bitPattern: $0) }, as: UTF8.self)
            let source = URL(fileURLWithPath: cachePath, isDirectory: true)
                .appendingPathComponent(identifier, isDirectory: true)
                .appendingPathComponent("com.apple.metal", isDirectory: true)
            let destination = try cacheDestination(in: caches)
            let outcome = try redirect(source: source, destination: destination)
            let status: String
            switch outcome {
            case .alreadyConfigured: status = "already configured"
            case .created: status = "created"
            case .migrated: status = "migrated"
            case .preservedPreviousCache: status = "redirected with previous cache preserved"
            }
            logger.notice("Mac Metal cache \(status, privacy: .public): \(source.path, privacy: .public) -> \(destination.path, privacy: .public)")
        } catch {
            logger.error("Could not redirect the Mac Metal cache: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Reject a substituted destination directory instead of following a symlink
    /// out of the container. Foundation's cache-directory URL itself may contain
    /// legitimate system links (for example /var -> /private/var).
    static func cacheDestination(in cachesDirectory: URL) throws -> URL {
        guard cachesDirectory.isFileURL else { throw CacheError.invalidLocation }
        let root = cachesDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let parent = root.appendingPathComponent("BoundMacMetal", isDirectory: true)
        let destination = parent.appendingPathComponent("com.apple.metal", isDirectory: true)
        for url in [parent, destination] {
            if try itemType(at: url) == S_IFLNK { throw CacheError.unexpectedSymbolicLink }
        }
        guard isDescendant(destination.resolvingSymlinksInPath(), of: root) else {
            throw CacheError.invalidLocation
        }
        return destination
    }

    /// Moves whole cache directories, never individual LMDB files. The injected
    /// link operation lets tests exercise rollback without changing permissions.
    @discardableResult
    static func redirect(source: URL, destination: URL,
                         createSymbolicLink: (URL, URL) throws -> Void = {
                             try FileManager.default.createSymbolicLink(at: $0, withDestinationURL: $1)
                         }) throws -> Outcome {
        guard source.isFileURL, destination.isFileURL else { throw CacheError.invalidLocation }
        let source = normalizedLeaf(source)
        let destination = normalizedLeaf(destination)
        guard source != destination, !isDescendant(source, of: destination),
              !isDescendant(destination, of: source) else { throw CacheError.invalidLocation }
        let manager = FileManager.default
        let parent = destination.deletingLastPathComponent()
        try manager.createDirectory(at: parent, withIntermediateDirectories: true)

        // This lock is itself in the allowed container cache and is closed before
        // UIKit starts. A second launch must not observe a half-moved directory.
        let lockURL = parent.appendingPathComponent(".migration.lock")
        let descriptor = open(lockURL.path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw posixError(at: lockURL) }
        defer { close(descriptor) }
        var lockInfo = stat()
        guard fstat(descriptor, &lockInfo) == 0 else { throw posixError(at: lockURL) }
        guard lockInfo.st_mode & S_IFMT == S_IFREG else { throw CacheError.unexpectedItem }
        guard flock(descriptor, LOCK_EX) == 0 else { throw posixError(at: lockURL) }
        defer { flock(descriptor, LOCK_UN) }

        let sourceType = try itemType(at: source)
        let destinationType = try itemType(at: destination)
        if destinationType == S_IFLNK { throw CacheError.unexpectedSymbolicLink }
        guard destinationType == nil || destinationType == S_IFDIR else { throw CacheError.unexpectedItem }

        if sourceType == S_IFLNK {
            let target = try manager.destinationOfSymbolicLink(atPath: source.path)
            let targetURL = target.hasPrefix("/") ? URL(fileURLWithPath: target)
                : source.deletingLastPathComponent().appendingPathComponent(target)
            guard targetURL.standardizedFileURL.resolvingSymlinksInPath() == destination else {
                throw CacheError.unexpectedSymbolicLink
            }
            try manager.createDirectory(at: destination, withIntermediateDirectories: true)
            return .alreadyConfigured
        }
        guard sourceType == nil || sourceType == S_IFDIR else { throw CacheError.unexpectedItem }
        try manager.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)

        let preserved: URL?
        let outcome: Outcome
        if sourceType == S_IFDIR {
            if destinationType == nil {
                preserved = destination
                outcome = .migrated
            } else {
                let backup = parent.appendingPathComponent("com.apple.metal.previous-\(UUID().uuidString)", isDirectory: true)
                preserved = backup
                outcome = .preservedPreviousCache(backup)
            }
            try manager.moveItem(at: source, to: preserved!)
        } else {
            preserved = nil
            outcome = .created
            try manager.createDirectory(at: destination, withIntermediateDirectories: true)
        }

        do {
            try createSymbolicLink(source, destination)
        } catch {
            if let preserved {
                do { try manager.moveItem(at: preserved, to: source) }
                catch { throw CacheError.rollbackFailed }
            }
            throw error
        }
        return outcome
    }

    private static func normalizedLeaf(_ url: URL) -> URL {
        let url = url.standardizedFileURL
        return url.deletingLastPathComponent().resolvingSymlinksInPath()
            .appendingPathComponent(url.lastPathComponent, isDirectory: true)
    }

    private static func isDescendant(_ url: URL, of parent: URL) -> Bool {
        let parts = url.standardizedFileURL.pathComponents
        let parentParts = parent.standardizedFileURL.pathComponents
        return parts.count > parentParts.count && parts.starts(with: parentParts)
    }

    private static func itemType(at url: URL) throws -> mode_t? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            if errno == ENOENT { return nil }
            throw posixError(at: url)
        }
        return info.st_mode & S_IFMT
    }

    private static func posixError(at url: URL) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: url.path])
    }
}
