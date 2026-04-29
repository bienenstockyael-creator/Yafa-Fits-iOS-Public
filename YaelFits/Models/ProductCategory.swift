import Foundation

/// Coarse body-zone category for closet swiping. Inferred from the product
/// name via simple keyword matching — cheap, runs locally, right ~95% of
/// the time. Anything we can't classify is `unknown` and gets skipped from
/// the closet rows (it stays a normal product everywhere else).
enum ProductCategory: String, Sendable {
    /// Anything covering the upper body (tops, jackets, sweaters).
    case top
    /// Bottoms — jeans, skirts, pants, shorts.
    case bottom
    /// A full-body single-piece garment. Rendered in the top carousel but
    /// occupies both the top and bottom slots when "dressed" on the avatar.
    case fullBody
    /// Footwear.
    case shoes
    /// Couldn't classify — excluded from closet rows.
    case unknown

    /// True if this category should appear in the top carousel (tops + dresses).
    var belongsInTopCarousel: Bool {
        self == .top || self == .fullBody
    }
}

extension ProductCategory {
    /// Keyword-match the product name to a category. Order matters: more
    /// specific matches (shoes, dresses) win over generic ones (top).
    static func inferring(from name: String) -> ProductCategory {
        let lowered = name.lowercased()

        if Self.shoeKeywords.contains(where: lowered.containsWord) {
            return .shoes
        }
        if Self.fullBodyKeywords.contains(where: lowered.containsWord) {
            return .fullBody
        }
        if Self.bottomKeywords.contains(where: lowered.containsWord) {
            return .bottom
        }
        if Self.topKeywords.contains(where: lowered.containsWord) {
            return .top
        }
        return .unknown
    }

    private static let topKeywords: [String] = [
        "tee", "t-shirt", "tshirt", "shirt", "blouse",
        "sweater", "jumper", "knit", "cardigan", "hoodie", "sweatshirt",
        "jacket", "blazer", "coat", "vest", "puffer", "parka", "anorak",
        "top", "tank", "camisole", "bodysuit", "turtleneck", "polo",
    ]

    private static let bottomKeywords: [String] = [
        "jeans", "denim", "pants", "trousers", "slacks", "chinos",
        "skirt", "shorts", "leggings", "joggers", "sweatpants", "culottes",
        "kilt", "jorts",
    ]

    private static let fullBodyKeywords: [String] = [
        "dress", "gown", "jumpsuit", "romper", "playsuit", "overalls",
    ]

    private static let shoeKeywords: [String] = [
        "shoes", "shoe", "sneakers", "sneaker", "boots", "boot",
        "loafers", "loafer", "heels", "heel", "sandals", "sandal",
        "flats", "flat", "mules", "mule", "trainers", "trainer",
        "sliders", "slider", "pumps", "pump", "clogs", "clog",
        "moccasins", "espadrilles",
    ]

    /// Per-product length multiplier in the carousel — a mini skirt
    /// shouldn't render at the same vertical footprint as wide-leg jeans,
    /// and a maxi dress should clearly read as longer than a mini dress.
    /// Inferred from name keywords only (no image inspection), so it's
    /// instant and works without waiting for thumbnails to load.
    /// Returns ~0.4 (very short) to ~1.2 (very long); 1.0 is the default
    /// canonical length for the category.
    static func inferLengthScale(name: String, category: ProductCategory) -> CGFloat {
        let lowered = name.lowercased()

        switch category {
        case .bottom:
            if lowered.containsWord("shorts") || lowered.containsWord("jorts") { return 0.45 }
            if lowered.containsWord("mini") { return 0.55 }
            if lowered.containsWord("midi") { return 0.85 }
            if lowered.containsWord("maxi") { return 1.05 }
            if lowered.containsWord("capri") || lowered.containsWord("cropped") { return 0.7 }
            if lowered.containsWord("skirt") || lowered.containsWord("kilt") { return 0.7 }
            return 1.0  // jeans, pants, trousers, leggings — full length

        case .fullBody:
            if lowered.containsWord("mini") { return 0.65 }
            if lowered.containsWord("midi") { return 0.9 }
            if lowered.containsWord("maxi") || lowered.containsWord("gown") { return 1.15 }
            if lowered.containsWord("romper") || lowered.containsWord("playsuit") { return 0.75 }
            if lowered.containsWord("jumpsuit") || lowered.containsWord("overalls") { return 1.0 }
            return 0.95  // generic dress

        case .top:
            if lowered.containsWord("crop") || lowered.containsWord("cropped") { return 0.7 }
            if lowered.containsWord("trench") { return 1.2 }
            if lowered.containsWord("coat") || lowered.containsWord("parka") { return 1.1 }
            if lowered.containsWord("bodysuit") { return 0.85 }
            if lowered.containsWord("tank") || lowered.containsWord("camisole") { return 0.85 }
            if lowered.containsWord("polo") || lowered.containsWord("tee")
                || lowered.containsWord("t-shirt") || lowered.containsWord("tshirt")
                || lowered.containsWord("shirt") || lowered.containsWord("blouse") { return 0.9 }
            if lowered.containsWord("hoodie") || lowered.containsWord("sweatshirt")
                || lowered.containsWord("sweater") || lowered.containsWord("cardigan")
                || lowered.containsWord("jumper") || lowered.containsWord("knit") { return 0.95 }
            return 1.0  // jackets, blazers, vests, generic

        case .shoes:
            if lowered.containsWord("thigh") { return 1.6 }
            if lowered.containsWord("knee") { return 1.3 }
            if lowered.containsWord("boot") || lowered.containsWord("boots") { return 1.0 }
            if lowered.containsWord("heel") || lowered.containsWord("heels")
                || lowered.containsWord("pump") || lowered.containsWord("pumps") { return 0.85 }
            if lowered.containsWord("sandal") || lowered.containsWord("sandals")
                || lowered.containsWord("slider") || lowered.containsWord("sliders") { return 0.7 }
            if lowered.containsWord("sneaker") || lowered.containsWord("sneakers")
                || lowered.containsWord("trainer") || lowered.containsWord("trainers")
                || lowered.containsWord("loafer") || lowered.containsWord("loafers")
                || lowered.containsWord("flat") || lowered.containsWord("flats")
                || lowered.containsWord("mule") || lowered.containsWord("mules")
                || lowered.containsWord("clog") || lowered.containsWord("clogs")
                || lowered.containsWord("moccasins") || lowered.containsWord("espadrilles") { return 0.75 }
            return 0.85

        case .unknown:
            return 1.0
        }
    }
}

private extension String {
    /// True if `self` contains `keyword` as a whole word (bounded by start
    /// of string, end of string, whitespace, or common punctuation).
    func containsWord(_ keyword: String) -> Bool {
        guard let range = self.range(of: keyword) else { return false }
        let before = range.lowerBound == self.startIndex ? nil : self[self.index(before: range.lowerBound)]
        let after = range.upperBound == self.endIndex ? nil : self[range.upperBound]
        let isBoundary: (Character?) -> Bool = { ch in
            guard let ch else { return true }
            return ch.isWhitespace || "-_/.,;:".contains(ch)
        }
        return isBoundary(before) && isBoundary(after)
    }
}
