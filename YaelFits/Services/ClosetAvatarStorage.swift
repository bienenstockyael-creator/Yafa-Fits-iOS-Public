import Foundation
import UIKit

/// Persists the user's standardised Virtual Closet avatar to local disk so
/// onboarding only runs once per device. Stored as PNG (preserves the
/// transparent background produced by Bria) under the user's UUID. A future
/// pass can sync this up to Supabase Storage for cross-device parity.
enum ClosetAvatarStorage {
    private static let directoryName = "ClosetAvatars"

    static func load(userId: UUID) -> UIImage? {
        let url = fileURL(for: userId)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
    }

    static func save(_ image: UIImage, userId: UUID) {
        guard let data = image.pngData() else { return }
        let url = fileURL(for: userId)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: url, options: .atomic)
    }

    static func clear(userId: UUID) {
        try? FileManager.default.removeItem(at: fileURL(for: userId))
    }

    private static func fileURL(for userId: UUID) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base
            .appendingPathComponent(directoryName, isDirectory: true)
            .appendingPathComponent("\(userId.uuidString).png")
    }
}
