import Foundation

struct ContentSource {
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 20
        return URLSession(configuration: configuration)
    }()

    static func getOutfits() async -> [Outfit] {
        let bundledOutfits = filterOutfits(loadBundledOutfits())
        let primaryOutfits: [Outfit]

        if let remoteOutfits = await fetchRemoteOutfits(), !remoteOutfits.isEmpty {
            primaryOutfits = remoteOutfits
        } else {
            primaryOutfits = bundledOutfits
        }

        return mergeBundledOutfits(primary: primaryOutfits, bundled: bundledOutfits)
    }

    static func getLocalOutfits() -> [Outfit] {
        let store = LocalOutfitStore.shared
        return store.loadOutfits()
    }

    static func getAllOutfits() async -> [Outfit] {
        let bundled = filterOutfits(await getOutfits())
        let local = filterOutfits(getLocalOutfits())
        let bundledIds = Set(bundled.map(\.id))
        let uniqueLocal = local.filter { !bundledIds.contains($0.id) }
        return bundled + uniqueLocal
    }

    static func getPublicFeed() async -> [FeedPost] {
        let bundledFeed = filterFeedPosts(loadBundledFeed())
        let primaryFeed: [FeedPost]

        if let remoteFeed = await fetchRemoteFeed(), !remoteFeed.isEmpty {
            primaryFeed = filterFeedPosts(remoteFeed)
        } else {
            primaryFeed = bundledFeed
        }

        let mergedFeed = mergeBundledFeed(primary: primaryFeed, bundled: bundledFeed)
        let localFeed = filterFeedPosts(LocalOutfitStore.shared.loadFeedPosts())
        return mergeLocalFeed(primary: mergedFeed, local: localFeed)
    }

    private static func fetchRemoteOutfits() async -> [Outfit]? {
        guard let outfitData: OutfitData = await fetchDecodable(from: AppConfig.outfitsDataURL) else {
            return nil
        }
        return filterOutfits(outfitData.outfits)
    }

    private static func fetchRemoteFeed() async -> [FeedPost]? {
        guard let feedData: FeedData = await fetchDecodable(from: AppConfig.publicFeedDataURL) else {
            return nil
        }
        return feedData.posts
    }

    private static func loadBundledOutfits() -> [Outfit] {
        guard let url = Bundle.main.url(forResource: "outfits", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let outfitData = try? JSONDecoder().decode(OutfitData.self, from: data) else {
            return []
        }
        return outfitData.outfits
    }

    private static func loadBundledFeed() -> [FeedPost] {
        guard let url = Bundle.main.url(forResource: "public-feed", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let feedData = try? JSONDecoder().decode(FeedData.self, from: data) else {
            return []
        }
        return feedData.posts
    }

    private static func fetchDecodable<T: Decodable>(from url: URL) async -> T? {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData

        guard let (data, response) = try? await session.data(for: request),
              let httpResponse = response as? HTTPURLResponse,
              (200 ..< 300).contains(httpResponse.statusCode) else {
            return nil
        }

        return try? JSONDecoder().decode(T.self, from: data)
    }

    private static func filterOutfits(_ outfits: [Outfit]) -> [Outfit] {
        outfits.filter { outfit in
            !AppConfig.excludedOutfitIDs.contains(outfit.id)
                && !AppConfig.excludedOutfitNumbers.contains(outfit.outfitNumber ?? -1)
        }
    }

    private static func filterFeedPosts(_ posts: [FeedPost]) -> [FeedPost] {
        posts.filter { post in
            !AppConfig.excludedOutfitIDs.contains(post.outfitId)
        }
    }

    private static func mergeBundledOutfits(primary: [Outfit], bundled: [Outfit]) -> [Outfit] {
        let primaryIds = Set(primary.map(\.id))
        let bundledOnly = bundled.filter { !primaryIds.contains($0.id) }
        return primary + bundledOnly
    }

    private static func mergeBundledFeed(primary: [FeedPost], bundled: [FeedPost]) -> [FeedPost] {
        let primaryOutfitIds = Set(primary.map(\.outfitId))
        let primaryPostIds = Set(primary.map(\.id))
        let bundledOnly = bundled.filter { post in
            !primaryOutfitIds.contains(post.outfitId) && !primaryPostIds.contains(post.id)
        }
        return bundledOnly + primary
    }

    private static func mergeLocalFeed(primary: [FeedPost], local: [FeedPost]) -> [FeedPost] {
        let primaryOutfitIds = Set(primary.map(\.outfitId))
        let primaryPostIds = Set(primary.map(\.id))
        let localOnly = local.filter { post in
            !primaryOutfitIds.contains(post.outfitId) && !primaryPostIds.contains(post.id)
        }
        return localOnly + primary
    }
}
