import Foundation
import UIKit

/// Local-only archive for Virtual Closet remixes. Saves the dressed-avatar
/// PNG (transparent background preserved) plus a JSON index of `Remix`
/// records. Separate from `LocalOutfitStore` because remixes are their own
/// thing — the List tab will eventually expose them under a `REMIXES`
/// toggle alongside outfits.
///
/// Cross-device sync (Supabase Storage + a `remixes` table) is a follow-up.
enum RemixStorage {
    private static let directoryName = "Remixes"
    private static let indexFileName = "remixes-index.json"

    // MARK: - Save

    @discardableResult
    static func save(
        image: UIImage,
        userId: UUID?,
        topItem: RemixItem?,
        bottomItem: RemixItem?,
        shoesItem: RemixItem?
    ) throws -> Remix {
        guard let data = image.pngData() else {
            throw NSError(
                domain: "RemixStorage",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Could not encode dressed avatar."]
            )
        }
        let id = UUID()
        let fileName = "\(id.uuidString).png"
        let directory = try ensureDirectory()
        let fileURL = directory.appendingPathComponent(fileName)
        try data.write(to: fileURL, options: .atomic)

        let remix = Remix(
            id: id,
            imageFileName: fileName,
            createdAt: Date(),
            userId: userId,
            topItem: topItem,
            bottomItem: bottomItem,
            shoesItem: shoesItem
        )
        var existing = (try? loadAll()) ?? []
        existing.insert(remix, at: 0)
        try writeIndex(existing)
        return remix
    }

    // MARK: - Read

    static func loadAll() throws -> [Remix] {
        let url = try indexURL()
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([Remix].self, from: data)
    }

    static func imageURL(for remix: Remix) -> URL {
        (try? ensureDirectory().appendingPathComponent(remix.imageFileName))
            ?? URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(remix.imageFileName)
    }

    static func loadImage(for remix: Remix) -> UIImage? {
        UIImage(contentsOfFile: imageURL(for: remix).path)
    }

    // MARK: - Delete

    static func delete(_ remix: Remix) throws {
        try? FileManager.default.removeItem(at: imageURL(for: remix))
        var existing = (try? loadAll()) ?? []
        existing.removeAll { $0.id == remix.id }
        try writeIndex(existing)
    }

    // MARK: - Internals

    private static func writeIndex(_ remixes: [Remix]) throws {
        let url = try indexURL()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(remixes)
        try data.write(to: url, options: .atomic)
    }

    private static func ensureDirectory() throws -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent(directoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func indexURL() throws -> URL {
        try ensureDirectory().appendingPathComponent(indexFileName)
    }
}
