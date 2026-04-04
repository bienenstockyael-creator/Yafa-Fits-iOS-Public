import UIKit

enum BundledOutfitResources {
    private static let bundledSequenceDirectory = "BundledOutfits"

    static func frameURL(for outfit: Outfit, index: Int) -> URL? {
        let padded = String(format: "%05d", index)
        let resourceName = "\(outfit.prefix)\(padded)"
        let subdirectory = "\(bundledSequenceDirectory)/\(outfit.folder)"
        if let nestedURL = Bundle.main.url(
            forResource: resourceName,
            withExtension: outfit.normalizedFrameExt,
            subdirectory: subdirectory
        ) {
            return nestedURL
        }

        // XcodeGen flattens these resources into the app bundle root, so keep
        // a root-level fallback for bundled full-frame sequences.
        return Bundle.main.url(
            forResource: resourceName,
            withExtension: outfit.normalizedFrameExt
        )
    }

    static func previewURL(for outfit: Outfit) -> URL? {
        Bundle.main.url(forResource: outfit.id, withExtension: "webp") ??
        Bundle.main.url(forResource: outfit.id, withExtension: "png") ??
        Bundle.main.url(forResource: outfit.id, withExtension: "webp", subdirectory: "thumbnails") ??
        Bundle.main.url(forResource: outfit.id, withExtension: "png", subdirectory: "thumbnails") ??
        frameURL(for: outfit, index: 0)
    }

    static func previewImage(for outfit: Outfit) -> UIImage? {
        guard let url = previewURL(for: outfit),
              let data = try? Data(contentsOf: url) else {
            return nil
        }

        return UIImage(data: data)
    }
}

/// Thread-safe frame image loader with NSCache and on-demand loading.
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
        config.urlCache = URLCache(memoryCapacity: 20_000_000, diskCapacity: 200_000_000)
        session = URLSession(configuration: config)
    }

    /// Load a frame, checking: memory cache → bundled thumbnail → local storage → remote.
    func frame(for outfit: Outfit, index: Int) async -> UIImage? {
        let cacheKey = outfit.framePath(index: index) as NSString

        // Check memory cache
        if let cached = cache.object(forKey: cacheKey) {
            return cached
        }

        // Check if already loading
        if let pending = pendingTasks[cacheKey as String] {
            return await pending.value
        }

        // Start loading
        let task = Task<UIImage?, Never> {
            // For frame 0: check bundled thumbnails first (instant)
            if index == 0, let bundled = loadBundledThumbnail(for: outfit) {
                cache.setObject(bundled, forKey: cacheKey)
                return bundled
            }

            if index == 0, let localPreview = LocalOutfitStore.shared.previewImage(for: outfit) {
                cache.setObject(localPreview, forKey: cacheKey)
                return localPreview
            }

            // Try bundled full-sequence frames
            if let bundledURL = BundledOutfitResources.frameURL(for: outfit, index: index),
               let data = try? Data(contentsOf: bundledURL),
               let image = UIImage(data: data) {
                cache.setObject(image, forKey: cacheKey, cost: data.count)
                return image
            }

            // Try local storage (for user-created outfits)
            let localURL = LocalOutfitStore.shared.frameURL(for: outfit, index: index)
            if FileManager.default.fileExists(atPath: localURL.path),
               let data = try? Data(contentsOf: localURL),
               let image = UIImage(data: data) {
                cache.setObject(image, forKey: cacheKey, cost: data.count)
                return image
            }

            // Try remote
            let remoteURL = outfit.frameURL(index: index, baseURL: AppConfig.remoteBaseURL)
            guard let (data, _) = try? await session.data(from: remoteURL),
                  let image = UIImage(data: data) else {
                return nil
            }

            cache.setObject(image, forKey: cacheKey, cost: data.count)
            return image
        }

        pendingTasks[cacheKey as String] = task
        let result = await task.value
        pendingTasks.removeValue(forKey: cacheKey as String)
        return result
    }

    /// Load bundled thumbnail from app resources (e.g., "outfit-1.webp")
    private func loadBundledThumbnail(for outfit: Outfit) -> UIImage? {
        BundledOutfitResources.previewImage(for: outfit)
    }

    /// Preload frames around a center index for smooth scrubbing.
    func primeFrames(for outfit: Outfit, center: Int, radius: Int = 15, stride: Int = 2) {
        let total = outfit.frameCount
        for offset in Swift.stride(from: -radius, through: radius, by: stride) {
            let idx = ((center + offset) % total + total) % total
            let key = outfit.framePath(index: idx) as NSString
            guard cache.object(forKey: key) == nil else { continue }

            Task {
                _ = await frame(for: outfit, index: idx)
            }
        }
    }

    /// Preload first frame for grid thumbnails.
    func preloadFirstFrames(outfits: [Outfit]) {
        for outfit in outfits {
            Task {
                _ = await frame(for: outfit, index: 0)
            }
        }
    }

    func preloadFullSequences(for outfits: [Outfit]) async {
        await withTaskGroup(of: Void.self) { group in
            for outfit in outfits {
                group.addTask {
                    _ = await FrameLoader.shared.preloadFullSequence(for: outfit)
                }
            }
        }
    }

    func hasFullSequence(for outfit: Outfit) -> Bool {
        fullyLoadedSequences.contains(outfit.id)
    }

    func preloadFullSequence(for outfit: Outfit) async -> Bool {
        if fullyLoadedSequences.contains(outfit.id) {
            return true
        }

        if let pending = pendingSequenceTasks[outfit.id] {
            return await pending.value
        }

        let task = Task<Bool, Never> { [weak self] in
            guard let self else { return false }

            for index in 0 ..< outfit.frameCount {
                guard await self.frame(for: outfit, index: index) != nil else {
                    return false
                }
            }

            return true
        }

        pendingSequenceTasks[outfit.id] = task
        let didLoad = await task.value
        pendingSequenceTasks.removeValue(forKey: outfit.id)

        if didLoad {
            fullyLoadedSequences.insert(outfit.id)
        }

        return didLoad
    }

    func evict(outfit: Outfit) {
        for index in 0 ..< outfit.frameCount {
            let key = outfit.framePath(index: index) as NSString
            cache.removeObject(forKey: key)
            pendingTasks[key as String]?.cancel()
            pendingTasks.removeValue(forKey: key as String)
        }

        pendingSequenceTasks[outfit.id]?.cancel()
        pendingSequenceTasks.removeValue(forKey: outfit.id)
        fullyLoadedSequences.remove(outfit.id)
    }
}
