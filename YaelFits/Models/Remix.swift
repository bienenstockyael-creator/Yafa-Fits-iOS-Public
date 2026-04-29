import Foundation

/// A saved Virtual Closet "remix" — a dressed-avatar generation plus the
/// closet items that produced it. Lives in its own archive separate from
/// `Outfit` because remixes are mix-and-match composites, not user-uploaded
/// outfits, and we want the List tab to surface them under a separate
/// `OUTFITS / REMIXES` toggle.
struct Remix: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    /// Filename (relative, in the remix archive directory) of the saved
    /// dressed-avatar PNG. Stored as a filename rather than a full URL so
    /// the archive remains valid across app reinstalls / data migrations.
    let imageFileName: String
    let createdAt: Date
    let userId: UUID?

    let topItem: RemixItem?
    let bottomItem: RemixItem?
    let shoesItem: RemixItem?
}

/// Lightweight snapshot of a closet item used in a remix. We keep name +
/// image URL inline so the archive can render thumbnails without re-reading
/// the user's outfit/library lists (which may have evolved since save).
struct RemixItem: Codable, Hashable, Sendable {
    let id: String
    let name: String
    let imageURL: String
}
