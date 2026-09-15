import CryptoKit
import Foundation
import Darwin

/// Content-addressed audio cache (P-10, F-9, C-4).
///
/// Key: SHA-256(normalized chunk text · provider · voice · model · voice
/// settings). Filenames are hashes — never text. Lives in
/// `~/Library/Application Support/sr/cache/`. LRU eviction over a size cap
/// (default 500 MB) plus a TTL (default 30 days). At-rest encryption is
/// FileVault's job (documented assumption).
public final class AudioCache: @unchecked Sendable {
    public static let shared = AudioCache()

    // Settings are read from pipeline tasks and the eviction queue while the
    // main thread writes them — lock rather than racing plain vars.
    private let stateLock = NSLock()
    private var _sizeCapBytes: Int
    private var _ttl: TimeInterval
    private var _enabled = true
    private struct PendingWrite {
        let id: UUID
        let data: Data
    }
    private var pendingWrites: [String: PendingWrite] = [:]

    public var sizeCapBytes: Int {
        get { stateLock.withLock { _sizeCapBytes } }
        set { stateLock.withLock { _sizeCapBytes = newValue } }
    }
    public var ttl: TimeInterval {
        get { stateLock.withLock { _ttl } }
        set { stateLock.withLock { _ttl = newValue } }
    }
    /// "No-cache" toggle for sensitive sessions (P-10).
    public var enabled: Bool {
        get { stateLock.withLock { _enabled } }
        set {
            stateLock.withLock {
                _enabled = newValue && privateDirectoryReady
                if !newValue { pendingWrites.removeAll() }
            }
            // A writer may already have copied its payload out of
            // `pendingWrites`. Wait for the serial queue to finish its
            // post-write policy check before returning from a disable.
            if !newValue, DispatchQueue.getSpecific(key: queueKey) == nil {
                queue.sync {}
            }
        }
    }

    private var privateDirectoryReady = false
    private let directory: URL
    private let queue = DispatchQueue(label: "com.patrickellis.sr.cache", qos: .utility)
    private let queueKey = DispatchSpecificKey<UInt8>()
    private let evictionDebounce: TimeInterval
    private let beforeDiskWrite: (@Sendable () -> Void)?
    /// Accessed only on `queue`.
    private var evictionWorkItem: DispatchWorkItem?
    private var evictionPasses = 0

    public convenience init(directory: URL? = nil,
                            sizeCapBytes: Int = 500_000_000,
                            ttl: TimeInterval = 30 * 24 * 3600,
                            evictionDebounce: TimeInterval = 0.25) {
        self.init(
            directory: directory,
            sizeCapBytes: sizeCapBytes,
            ttl: ttl,
            evictionDebounce: evictionDebounce,
            beforeDiskWrite: nil)
    }

    /// Internal deterministic seam for exercising the no-cache transition
    /// while a disk write is already in progress.
    init(directory: URL?,
         sizeCapBytes: Int,
         ttl: TimeInterval,
         evictionDebounce: TimeInterval,
         beforeDiskWrite: (@Sendable () -> Void)?) {
        self.directory = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("sr/cache", isDirectory: true)
        self._sizeCapBytes = sizeCapBytes
        self._ttl = ttl
        self.evictionDebounce = evictionDebounce
        self.beforeDiskWrite = beforeDiskWrite
        queue.setSpecific(key: queueKey, value: 1)
        do {
            let fm = FileManager.default
            try fm.createDirectory(at: self.directory, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
            // createDirectory leaves existing permissions unchanged: repair
            // older installations before any sensitive audio can be read/written.
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: self.directory.path)
            try Self.removeExtendedACL(at: self.directory)
            privateDirectoryReady = true
        } catch {
            // Caching is optional. Fail closed if its privacy boundary cannot
            // be established, while allowing synthesis/playback to continue.
            _enabled = false
            SRLog.error("cache.private_directory_failed", [:])
        }
    }

    /// POSIX mode bits do not override macOS extended ACL grants.
    private static func removeExtendedACL(at url: URL) throws {
        guard let emptyACL = acl_init(0) else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        defer { acl_free(UnsafeMutableRawPointer(emptyACL)) }
        guard acl_set_file(url.path, ACL_TYPE_EXTENDED, emptyACL) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }

    // MARK: - Keying

    /// `languageCode` is the language actually pinned on the request ("" when
    /// the provider was left to detect it). Without it, the same sentence read
    /// as Norwegian and as English would collide on one cache entry and the
    /// wrong pronunciation would be replayed.
    /// `variant` carries anything else that changes what the provider will
    /// produce for identical text — today the pronunciation-dictionary
    /// version actually sent (F-13). Empty when there is none.
    public static func key(text: String, provider: String, voiceID: String,
                           modelID: String, languageCode: String = "",
                           variant: String = "",
                           settings: VoiceSettings) -> String {
        var hasher = SHA256()
        // \u{1F} separators prevent field-boundary collisions.
        var material = [
            text, provider, voiceID, modelID, languageCode,
            String(settings.stability), String(settings.similarityBoost),
            String(settings.style), String(settings.useSpeakerBoost),
        ].joined(separator: "\u{1F}")
        // Appended rather than inserted, so keys for reads without a
        // pronunciation dictionary keep hashing exactly as they did before
        // and their cached audio survives the upgrade.
        if !variant.isEmpty {
            material += "\u{1F}" + variant
        }
        hasher.update(data: Data(material.utf8))
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func url(for key: String) -> URL {
        directory.appendingPathComponent(key).appendingPathExtension("mp3")
    }

    // MARK: - Read / write

    public func lookup(_ key: String) -> Data? {
        let state = stateLock.withLock { (_enabled, pendingWrites[key]?.data) }
        guard state.0 else { return nil }
        if let pending = state.1 {
            SRLog.event("cache.hit", ["bytes": String(pending.count), "source": "memory"])
            return pending
        }
        let file = url(for: key)
        guard let data = try? Data(contentsOf: file) else {
            SRLog.event("cache.miss", [:])
            return nil
        }
        // Touch mtime for LRU.
        try? FileManager.default.setAttributes([.modificationDate: Date()],
                                               ofItemAtPath: file.path)
        SRLog.event("cache.hit", ["bytes": String(data.count)])
        return data
    }

    public func store(_ key: String, data: Data) {
        let writeID = UUID()
        let shouldStore = stateLock.withLock { () -> Bool in
            guard _enabled else { return false }
            // Make the result visible immediately without blocking playback
            // on disk I/O or a maintenance sweep queued ahead of this write.
            pendingWrites[key] = PendingWrite(id: writeID, data: data)
            return true
        }
        guard shouldStore else { return }
        let file = url(for: key)
        queue.async { [self] in
            // Re-check: "no-cache" flipped after enqueue must stay a hard
            // boundary — a queued write landing post-toggle would put
            // sensitive audio on disk.
            let dataToWrite = stateLock.withLock { () -> Data? in
                guard _enabled else {
                    pendingWrites[key] = nil
                    return nil
                }
                guard pendingWrites[key]?.id == writeID else { return nil }
                return pendingWrites[key]?.data
            }
            guard let dataToWrite else { return }
            beforeDiskWrite?()
            do {
                try dataToWrite.write(to: file, options: .atomic)
                // Atomic temporary files are protected by the 0700 parent.
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o600], ofItemAtPath: file.path)
                try Self.removeExtendedACL(at: file)
            } catch {
                try? FileManager.default.removeItem(at: file)
                stateLock.withLock {
                    if pendingWrites[key]?.id == writeID { pendingWrites[key] = nil }
                }
                return
            }
            let keepFile = stateLock.withLock { () -> Bool in
                guard _enabled, pendingWrites[key]?.id == writeID else { return false }
                pendingWrites[key] = nil
                return true
            }
            if !keepFile {
                // Policy changed (or a newer same-key write superseded us)
                // while the atomic write was in progress. Remove the stale
                // payload before the disable transition is allowed to return.
                try? FileManager.default.removeItem(at: file)
            } else {
                scheduleEviction()
            }
        }
    }

    // MARK: - Maintenance

    /// One-click "Purge cache" (P-10).
    public func purge() {
        queue.async { [self] in
            let fm = FileManager.default
            for entry in (try? fm.contentsOfDirectory(at: directory,
                            includingPropertiesForKeys: nil)) ?? [] {
                try? fm.removeItem(at: entry)
            }
            SRLog.event("cache.purged", [:])
        }
    }

    public func currentSizeBytes() -> Int {
        let fm = FileManager.default
        return ((try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? [])
            .compactMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize }
            .reduce(0, +)
    }

    /// TTL sweep + LRU eviction down to the size cap. All maintenance runs
    /// on the cache queue so two evictions never race each other.
    public func evictIfNeeded() {
        queue.async { [self] in
            evictionWorkItem?.cancel()
            evictionWorkItem = nil
            performEviction()
        }
    }

    /// Test seam for proving that bursty stores coalesce maintenance work.
    var maintenancePassCount: Int {
        queue.sync { evictionPasses }
    }

    /// Called on `queue`. A synthesis burst can store several chunks in a few
    /// milliseconds; scanning the entire cache after each one turns writes
    /// into O(chunks × cache entries). One trailing sweep has the same size
    /// and TTL semantics with bounded delay.
    private func scheduleEviction() {
        guard evictionWorkItem == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.evictionWorkItem = nil
            self.performEviction()
        }
        evictionWorkItem = work
        queue.asyncAfter(deadline: .now() + evictionDebounce, execute: work)
    }

    private func performEviction() {
        evictionPasses += 1
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])
        else { return }

        var files: [(url: URL, size: Int, mtime: Date)] = entries.compactMap { entry in
            guard let values = try? entry.resourceValues(
                    forKeys: [.fileSizeKey, .contentModificationDateKey]),
                  let size = values.fileSize,
                  let mtime = values.contentModificationDate else { return nil }
            return (entry, size, mtime)
        }

        // TTL first.
        let cutoff = Date().addingTimeInterval(-ttl)
        for file in files where file.mtime < cutoff {
            try? fm.removeItem(at: file.url)
        }
        files.removeAll { $0.mtime < cutoff }

        // Then LRU down to cap.
        var total = files.reduce(0) { $0 + $1.size }
        guard total > sizeCapBytes else { return }
        for file in files.sorted(by: { $0.mtime < $1.mtime }) {
            try? fm.removeItem(at: file.url)
            total -= file.size
            if total <= sizeCapBytes { break }
        }
        SRLog.event("cache.evicted", ["now_bytes": String(total)])
    }
}
