import Foundation

enum WeatherVisualKind: Sendable {
    case sunny
    case clear
    case partlyCloudy
    case cloudy
    case rainy
    case stormy
    case snowy
    case cold
    case breezy
    case windy
    case unknown
}

struct Weather: Codable, Hashable, Sendable {
    let tempF: Int
    let tempC: Int
    let condition: String

    func formatted(useFahrenheit: Bool) -> String {
        let temp = useFahrenheit ? "\(tempF)°F" : "\(tempC)°C"
        return condition.isEmpty ? temp : "\(temp) · \(condition)"
    }

    var visualKind: WeatherVisualKind {
        switch condition.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "sunny":
            return .sunny
        case "clear":
            return .clear
        case "partly cloudy":
            return .partlyCloudy
        case "cloudy", "overcast":
            return .cloudy
        case "rainy":
            return .rainy
        case "stormy":
            return .stormy
        case "snowy":
            return .snowy
        case "cold":
            return .cold
        case "breezy":
            return .breezy
        case "windy":
            return .windy
        default:
            return .unknown
        }
    }
}

struct Product: Codable, Hashable, Identifiable, Sendable {
    /// Stable identity: prefer productId, fall back to name
    var id: String { productId?.uuidString ?? name }
    let name: String
    let price: String?
    let image: String
    var shopLink: String?
    var productId: UUID?   // references products table
    var tags: [String]?    // from products table

    var displayName: String {
        name.split(separator: " ")
            .map { word in
                let lowercased = word.lowercased()
                return lowercased.prefix(1).uppercased() + lowercased.dropFirst()
            }
            .joined(separator: " ")
    }

    var resolvedImageURL: URL? {
        let trimmed = image.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let absoluteURL = URL(string: trimmed), absoluteURL.scheme != nil {
            return absoluteURL
        }

        let normalizedPath: String
        if trimmed.hasPrefix("/") {
            normalizedPath = String(trimmed.dropFirst())
        } else {
            normalizedPath = trimmed.replacingOccurrences(of: "^\\./?", with: "", options: .regularExpression)
        }

        guard !normalizedPath.isEmpty else { return nil }
        return AppConfig.siteBaseURL.appendingPathComponent(normalizedPath)
    }
}

struct Outfit: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    var date: String
    let frameCount: Int
    let folder: String
    let prefix: String
    var frameExt: String?
    var remoteBaseURL: String?
    var scale: Double?
    var isRotationReversed: Bool?
    var tags: [String]?
    var activity: String?
    var weather: Weather?
    var products: [Product]?
    var caption: String?
    /// Free-text place label shown next to the date in the carousel
    /// detail card (e.g. "NEW YORK"). Optional — older outfits and
    /// outfits without a captured location simply hide the label.
    var location: String?
    /// Device-local owner used to scope on-disk assets and metadata to the
    /// signed-in account that created the outfit.
    var localOwnerUserId: String? = nil
    /// Whether this outfit is published publicly (mirrors Supabase
    /// `outfits.is_public`). Nil for bundled/demo outfits and anything
    /// not synced from the server. Drives shareability — only public
    /// outfits can be featured on the web profile card.
    var isPublic: Bool? = nil
    /// Personal "diary" note the owner writes on this fit in the
    /// carousel detail view (a little annotation / journal entry).
    /// Optional. Rendered in the style named by `noteStyle`.
    var diaryNote: String?
    /// Which font/style the diary note renders in — a
    /// `DiaryNoteStyle` rawValue. Nil defaults to handwritten.
    var noteStyle: String?
    /// When true, the note is shown to viewers + eligible for the
    /// share card (opt-in via the Publish sheet toggle). Nil/false =
    /// private to the owner. Only meaningful when `diaryNote` is set.
    var noteShared: Bool? = nil
    /// Normalized note position within the fit frame — 0…1 on each axis
    /// (0.5,0.5 = center). Resolution-independent so it maps to any
    /// render size. Nil defaults to a lower-center placement.
    var noteX: Double?
    var noteY: Double?
    /// Note text scale (pinch-to-zoom). Nil defaults to 1.0.
    var noteScale: Double?
    /// Note rotation in radians (rotate gesture). Nil defaults to 0.
    var noteRotation: Double?
    /// Ink color index into `DiaryInk.palette`. Nil defaults to 0 (white).
    var noteColorIndex: Int?

    var normalizedFrameExt: String {
        let ext = (frameExt ?? "webp").trimmingCharacters(in: .whitespaces).lowercased()
        return ext == "webmp" ? "webp" : (ext.isEmpty ? "webp" : ext)
    }

    var effectiveScale: Double { scale ?? 1.0 }
    var rotationReversed: Bool { isRotationReversed ?? false }

    var parsedDate: Date? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: date)
    }

    var monthBucket: Date? {
        guard let parsedDate else { return nil }
        let components = Calendar.current.dateComponents([.year, .month], from: parsedDate)
        return Calendar.current.date(from: components)
    }

    var dayNumberLabel: String {
        parsedDate?.formatted(.dateTime.day()) ?? date
    }

    var weekdayLabel: String {
        parsedDate?.formatted(.dateTime.weekday(.wide)) ?? ""
    }

    var monthDayLabel: String {
        parsedDate?.formatted(.dateTime.month(.abbreviated).day()) ?? date
    }

    var monthYearLabel: String {
        parsedDate?.formatted(.dateTime.month(.wide).year()) ?? date
    }

    var fullDateLabel: String {
        parsedDate?.formatted(date: .complete, time: .omitted) ?? date
    }

    func numericDateLabel(useFahrenheit: Bool) -> String {
        guard let parsedDate else { return date }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = useFahrenheit ? "MM/dd/yy" : "dd/MM/yy"
        return formatter.string(from: parsedDate)
    }

    var outfitNumber: Int? {
        // IDs come in two shapes:
        //   outfit-120                (legacy / device-generated)
        //   outfit-31c9f3fd-120       (server-generated; middle chunk is user-id prefix)
        // The outfit number is always the trailing digit run.
        let trailing = id.reversed().prefix { $0.isNumber }
        guard !trailing.isEmpty else { return nil }
        return Int(String(trailing.reversed()))
    }

    func framePath(index: Int) -> String {
        let padded = String(format: "%05d", index)
        return "\(folder)/\(prefix)\(padded).\(normalizedFrameExt)"
    }

    func uniqueFrameKey(index: Int) -> String {
        let base = remoteBaseURL ?? "local"
        return "\(base)/\(framePath(index: index))"
    }

    var resolvedRemoteBaseURL: URL? {
        if let remoteBaseURL,
           let url = URL(string: remoteBaseURL),
           url.scheme != nil {
            return url
        }
        return AppConfig.remoteBaseURL
    }

    func frameURL(index: Int, baseURL: URL) -> URL {
        baseURL.appendingPathComponent(framePath(index: index))
    }
}

struct OutfitData: Codable, Sendable {
    let outfits: [Outfit]
}
