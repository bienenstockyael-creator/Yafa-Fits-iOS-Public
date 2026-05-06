import CryptoKit
import OSLog
import SwiftUI
import UIKit

struct AvatarView: View {
    let url: String?
    let initial: String
    var size: CGFloat = 40
    var shadowRadius: CGFloat = 0
    var shadowY: CGFloat = 0

    var body: some View {
        Group {
            if let url, let parsed = URL(string: url) {
                CachedRemoteImage(
                    url: parsed,
                    // Decode at 3× for crispness on Pro Max — same image
                    // is reused across feed (size=40) and profile sheet
                    // (size=80) so we always decode at the largest
                    // expected display size on this device.
                    maxPixelSize: max(size, 80) * UIScreen.main.scale,
                    contentMode: .fill
                ) {
                    fallback
                }
            } else {
                fallback
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .appCircle(shadowRadius: shadowRadius, shadowY: shadowY)
    }

    private var fallback: some View {
        ZStack {
            Color.clear
            Text(initial)
                .font(.system(size: size * 0.35, weight: .semibold))
                .foregroundStyle(AppPalette.textPrimary)
        }
    }
}

// MARK: - Cached remote image

/// Two-tier image cache (NSCache in memory, JPEG bytes on disk in
/// Caches/) shared across the app. Loads survive view recycling: the
/// `URLSession` task is owned by `RemoteImageCache`, not the awaiting
/// view, so a `LazyVStack` cell scrolling off-screen mid-fetch can no
/// longer cancel the request.
///
/// Network + decode run on the cooperative thread pool (via
/// `Task.detached`) so the main thread isn't blocked while a multi-MB
/// avatar JPEG decodes.
@MainActor
final class RemoteImageCache {
    static let shared = RemoteImageCache()

    private let memory = NSCache<NSString, UIImage>()
    private var inFlight: [URL: Task<UIImage?, Never>] = [:]
    private static let log = Logger(subsystem: "yafa", category: "image-cache")

    /// Dedicated session with a tight 10s request timeout. Avatars are
    /// 5–50KB; the URLSession.shared default (60s) leaves users staring
    /// at placeholders for a full minute on flaky networks.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 30
        return URLSession(configuration: config)
    }()

    /// Disk cache lives under Caches/ — iOS evicts this directory
    /// automatically under low-storage conditions, so we don't need
    /// our own LRU on disk.
    private static let diskDir: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let dir = caches.appendingPathComponent("yafa-images", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private init() {
        memory.countLimit = 300
        memory.totalCostLimit = 32 * 1024 * 1024 // ~32 MB of decoded UIImage bytes
    }

    /// Synchronous memory-cache read. Used on view appear so
    /// previously-loaded images render without a placeholder flash.
    func cached(_ url: URL) -> UIImage? {
        memory.object(forKey: url.absoluteString as NSString)
    }

    /// Returns the image, hitting memory → disk → network in that
    /// order. Concurrent callers for the same URL share a single
    /// `Task` (de-dup via `inFlight`).
    func load(_ url: URL, maxPixelSize: CGFloat) async -> UIImage? {
        if let hit = cached(url) {
            return hit
        }
        if let existing = inFlight[url] {
            return await existing.value
        }
        let task = Task.detached(priority: .userInitiated) { () -> UIImage? in
            await Self.fetchAndDecode(url: url, maxPixelSize: maxPixelSize)
        }
        inFlight[url] = task
        let result = await task.value
        // Populate the memory cache BEFORE clearing inFlight, otherwise
        // a third caller arriving in the gap would see no cached entry
        // and no in-flight task, and start a redundant fetch for an
        // image we just downloaded.
        if let result {
            memory.setObject(
                result,
                forKey: url.absoluteString as NSString,
                cost: Self.byteCost(of: result)
            )
        }
        inFlight[url] = nil
        return result
    }

    /// Drops a URL from both memory and disk caches. Call this after a
    /// successful upload of a new image at `url` so the next render
    /// fetches fresh bytes instead of serving a stale cached copy.
    /// Necessary for any upload path that overwrites the same Storage
    /// object (vs. uploading to a new path each time).
    func invalidate(_ url: URL) {
        memory.removeObject(forKey: url.absoluteString as NSString)
        let path = Self.diskPath(for: url)
        try? FileManager.default.removeItem(at: path)
    }

    // MARK: - Off-main work

    nonisolated private static func fetchAndDecode(
        url: URL,
        maxPixelSize: CGFloat
    ) async -> UIImage? {
        let diskPath = diskPath(for: url)

        // 1. Disk hit — bypass the network entirely on cold launch.
        if let data = try? Data(contentsOf: diskPath),
           let image = downsample(data: data, maxPixelSize: maxPixelSize) {
            return image
        }

        // 2. Network fetch. URLSession runs on its own queue, so the
        // caller's actor isn't blocked during the await.
        do {
            let (data, response) = try await session.data(from: url)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                log.error("HTTP \(http.statusCode) for \(url.absoluteString, privacy: .public)")
                return nil
            }
            // Persist for next launch BEFORE decoding — even if
            // downsample fails for some reason, we still save the
            // bytes so a future call can retry.
            try? data.write(to: diskPath, options: .atomic)
            guard let image = downsample(data: data, maxPixelSize: maxPixelSize) else {
                log.error("decode failed for \(url.absoluteString, privacy: .public)")
                return nil
            }
            return image
        } catch {
            log.error("fetch failed for \(url.absoluteString, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// CGImageSource-based downsampling — decodes only the thumbnail
    /// at the requested pixel size instead of the full image, so a
    /// 4-megapixel JPEG turns into a ~120-pixel UIImage in one pass
    /// without ever decoding the full resolution into memory.
    nonisolated private static func downsample(
        data: Data,
        maxPixelSize: CGFloat
    ) -> UIImage? {
        let sourceOptions: CFDictionary = [
            kCGImageSourceShouldCache: false
        ] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else {
            return nil
        }
        let downsampleOptions: CFDictionary = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ] as CFDictionary
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, downsampleOptions) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }

    // MARK: - Disk paths

    nonisolated private static func diskPath(for url: URL) -> URL {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return diskDir.appendingPathComponent("\(hex).bin")
    }

    // MARK: - Costing

    nonisolated private static func byteCost(of image: UIImage) -> Int {
        let pixels = image.size.width * image.scale * image.size.height * image.scale
        return Int(pixels * 4)
    }
}

/// Drop-in AsyncImage replacement that doesn't get cancelled by view
/// recycling. Renders `placeholder` until the image arrives.
struct CachedRemoteImage<Placeholder: View>: View {
    let url: URL
    var maxPixelSize: CGFloat = 240
    var contentMode: ContentMode = .fill
    @ViewBuilder let placeholder: () -> Placeholder

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else {
                placeholder()
            }
        }
        .task(id: url) {
            // Sync cache hit on appear avoids any placeholder flash.
            if let hit = RemoteImageCache.shared.cached(url) {
                self.image = hit
                return
            }
            // Cache miss: kick off the shared load. Even if this
            // `.task` is cancelled by view recycling, the underlying
            // fetch in `RemoteImageCache.load` keeps running and
            // populates both caches for next time.
            if let loaded = await RemoteImageCache.shared.load(url, maxPixelSize: maxPixelSize) {
                self.image = loaded
            }
        }
    }
}
