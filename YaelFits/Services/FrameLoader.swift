import UIKit

// MARK: - Persistent disk frame cache

/// Saves CDN-downloaded frames to Library/Caches/YafaFrames/.
/// iOS can clear this directory under storage pressure, but it persists
/// across app sessions — so archive outfits load from disk on second view.
private final class DiskFrameCache {
    static let shared = DiskFrameCache()

    private let cacheDir: URL

    private init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        cacheDir = caches.appendingPathComponent("YafaFrames", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    }

    private func fileURL(for outfit: Outfit, index: Int) -> URL {
        cacheDir.appendingPathComponent(outfit.uniqueFrameKey(index: index))
    }

    func image(for outfit: Outfit, index: Int) -> UIImage? {
        let url = fileURL(for: outfit, index: index)
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
    }

    func save(_ data: Data, for outfit: Outfit, index: Int) {
        let url = fileURL(for: outfit, index: index)
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    func diskUsageBytes() -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: cacheDir,
            includingPropertiesForKeys: [.fileSizeKey]
        ) else { return 0 }
        return (enumerator.allObjects as? [URL] ?? []).reduce(0) { total, url in
            total + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }
}

// MARK: - Frame loader

/// Thread-safe frame image loader.
/// Load order: memory cache → local storage → disk frame cache → CDN (+ save to disk).
actor FrameLoader {
    static let shared = FrameLoader()

    private let cache = NSCache<NSString, UIImage>()
    private var pendingTasks: [String: Task<UIImage?, Never>] = [:]
    private var pendingSequenceTasks: [String: Task<Bool, Never>] = [:]
    private var fullyLoadedSequences: Set<String> = []
    private let session: URLSession

    private init() {
        cache.countLimit = AppConfig.cacheLimitCount
        cache.totalCostLimit = AppConfig.cacheLimitBytes

        let config = URLSessionConfiguration.default
        // URLCache provides a secondary HTTP-level disk cache layer
        config.urlCache = URLCache(memoryCapacity: 20_000_000, diskCapacity: 200_000_000)
        session = URLSession(configuration: config)
    }

    /// Load a frame. Checks (in order):
    /// 1. Memory cache
    /// 2. Local storage (user-uploaded outfits)
    /// 3. Disk frame cache (previously downloaded CDN frames)
    /// 4. CDN download → saved to disk cache for next time
    func frame(for outfit: Outfit, index: Int) async -> UIImage? {
        let cacheKey = outfit.uniqueFrameKey(index: index) as NSString

        if let cached = cache.object(forKey: cacheKey) { return cached }
        if let pending = pendingTasks[cacheKey as String] { return await pending.value }

        let task = Task<UIImage?, Never> {
            // Local storage — user-generated outfits saved to device Documents
            if index == 0,
               let preview = LocalOutfitStore.shared.previewImage(for: outfit) {
                cache.setObject(preview, forKey: cacheKey)
                return preview
            }

            let localURL = LocalOutfitStore.shared.frameURL(for: outfit, index: index)
            if FileManager.default.fileExists(atPath: localURL.path),
               let data = try? Data(contentsOf: localURL),
               let image = UIImage(data: data) {
                cache.setObject(image, forKey: cacheKey, cost: data.count)
                return image
            }

            // Bundled thumbnail — small webp files in app bundle (frame 0 only)
            if index == 0 {
                let name = outfit.id
                for ext in ["webp", "png"] {
                    if let url = Bundle.main.url(forResource: name, withExtension: ext),
                       let data = try? Data(contentsOf: url),
                       let image = UIImage(data: data) {
                        cache.setObject(image, forKey: cacheKey, cost: data.count)
                        return image
                    }
                }
            }

            // Disk frame cache — frames saved from previous CDN downloads
            if let diskImage = DiskFrameCache.shared.image(for: outfit, index: index) {
                cache.setObject(diskImage, forKey: cacheKey)
                return diskImage
            }

            // CDN download — save to disk cache so next load is instant
            guard let remoteBaseURL = outfit.resolvedRemoteBaseURL else { return nil }
            let remoteURL = outfit.frameURL(index: index, baseURL: remoteBaseURL)
            guard let (data, _) = try? await session.data(from: remoteURL),
                  let image = UIImage(data: data) else { return nil }

            cache.setObject(image, forKey: cacheKey, cost: data.count)
            DiskFrameCache.shared.save(data, for: outfit, index: index)
            return image
        }

        pendingTasks[cacheKey as String] = task
        let result = await task.value
        pendingTasks.removeValue(forKey: cacheKey as String)
        return result
    }

    /// Preload frames around a center index for smooth scrubbing.
    func primeFrames(for outfit: Outfit, center: Int, radius: Int = 15, stride: Int = 2) {
        let total = outfit.frameCount
        for offset in Swift.stride(from: -radius, through: radius, by: stride) {
            let idx = ((center + offset) % total + total) % total
            let key = outfit.uniqueFrameKey(index: idx) as NSString
            guard cache.object(forKey: key) == nil else { continue }
            Task { _ = await frame(for: outfit, index: idx) }
        }
    }

    func preloadFirstFrames(outfits: [Outfit]) {
        for outfit in outfits {
            Task { _ = await frame(for: outfit, index: 0) }
        }
    }

    func preloadFullSequences(for outfits: [Outfit]) async {
        await withTaskGroup(of: Void.self) { group in
            for outfit in outfits {
                group.addTask { _ = await FrameLoader.shared.preloadFullSequence(for: outfit) }
            }
        }
    }

    func hasFullSequence(for outfit: Outfit) -> Bool {
        fullyLoadedSequences.contains(outfit.id)
    }

    func preloadFullSequence(for outfit: Outfit) async -> Bool {
        if fullyLoadedSequences.contains(outfit.id) { return true }
        if let pending = pendingSequenceTasks[outfit.id] { return await pending.value }

        let task = Task<Bool, Never> { [weak self] in
            guard let self else { return false }
            for index in 0..<outfit.frameCount {
                guard await self.frame(for: outfit, index: index) != nil else { return false }
            }
            return true
        }

        pendingSequenceTasks[outfit.id] = task
        let didLoad = await task.value
        pendingSequenceTasks.removeValue(forKey: outfit.id)
        if didLoad { fullyLoadedSequences.insert(outfit.id) }
        return didLoad
    }

    func evict(outfit: Outfit) {
        for index in 0..<outfit.frameCount {
            let key = outfit.uniqueFrameKey(index: index) as NSString
            cache.removeObject(forKey: key)
            pendingTasks[key as String]?.cancel()
            pendingTasks.removeValue(forKey: key as String)
        }
        pendingSequenceTasks[outfit.id]?.cancel()
        pendingSequenceTasks.removeValue(forKey: outfit.id)
        fullyLoadedSequences.remove(outfit.id)
    }

    /// How much disk space the frame cache is using.
    func diskCacheUsageBytes() -> Int64 {
        DiskFrameCache.shared.diskUsageBytes()
    }
}
