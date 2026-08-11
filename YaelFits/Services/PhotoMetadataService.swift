import CoreLocation
import Foundation
import ImageIO

/// What a camera-roll photo says about itself. Attached to a
/// generation job when the user picks from the library, so the fit
/// is stamped with the day the photo was TAKEN (and, when GPS is
/// present, the weather/location of that moment) instead of the day
/// it was uploaded.
struct PhotoMetadata: Sendable {
    /// EXIF capture instant. When the EXIF carries a UTC offset we
    /// honor it; otherwise the wall-clock digits are interpreted in
    /// the device's current time zone (close enough for a weather
    /// lookup, and the DAY string below never shifts either way).
    let captureDate: Date
    /// The capture day exactly as the camera wrote it — local
    /// wall-clock "yyyy-MM-dd". This is what `Outfit.date` wants:
    /// "what did I wear that day" is a wall-clock question, so we
    /// take the EXIF digits verbatim rather than round-tripping
    /// through a Date + time zone.
    let dayString: String
    /// EXIF GPS fix, if the camera recorded one.
    let coordinate: CLLocationCoordinate2D?

    var location: CLLocation? {
        coordinate.map { CLLocation(latitude: $0.latitude, longitude: $0.longitude) }
    }
}

enum PhotoMetadataService {
    /// How recent a capture can be and still count as "live" — a
    /// just-shot photo picked from the roll behaves exactly like a
    /// camera capture (current weather + location + today), so the
    /// two entry points can't drift for the common case.
    static let liveWindow: TimeInterval = 2 * 60 * 60

    /// Extracts capture metadata from raw image bytes (the
    /// PhotosPicker `Data` representation keeps EXIF + GPS unless
    /// the user disabled location in the picker). Returns nil when
    /// there's no usable capture date — screenshots, edited exports,
    /// messaging-app saves — in which case the caller falls back to
    /// live behavior (today / current) with everything editable.
    static func extract(from data: Data) -> PhotoMetadata? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return nil }

        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
        guard let raw = (exif?[kCGImagePropertyExifDateTimeOriginal]
                ?? exif?[kCGImagePropertyExifDateTimeDigitized]) as? String,
              let parsed = parseExifDate(
                  raw,
                  offset: exif?[kCGImagePropertyExifOffsetTimeOriginal] as? String
              )
        else { return nil }

        return PhotoMetadata(
            captureDate: parsed.instant,
            dayString: parsed.dayString,
            coordinate: gpsCoordinate(from: props)
        )
    }

    // MARK: - EXIF date

    /// EXIF dates are "yyyy:MM:dd HH:mm:ss" in the CAMERA's local
    /// time, with the zone (when present at all) in a separate
    /// OffsetTimeOriginal tag like "+02:00".
    private static func parseExifDate(
        _ raw: String,
        offset: String?
    ) -> (instant: Date, dayString: String)? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        formatter.timeZone = offset.flatMap(timeZone(fromOffset:)) ?? .current
        guard let instant = formatter.date(from: raw) else { return nil }

        // Day string straight from the digits — never re-derived
        // through a time zone, so the fit lands on the day the
        // camera showed, wherever the user is now.
        let day = raw.prefix(10).replacingOccurrences(of: ":", with: "-")
        guard day.count == 10 else { return nil }
        return (instant, day)
    }

    private static func timeZone(fromOffset offset: String) -> TimeZone? {
        // "+02:00" / "-05:30" → seconds from GMT.
        let trimmed = offset.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 6,
              let sign = trimmed.first, sign == "+" || sign == "-",
              let hours = Int(trimmed.dropFirst().prefix(2)),
              let minutes = Int(trimmed.suffix(2))
        else { return nil }
        let seconds = (hours * 3600 + minutes * 60) * (sign == "-" ? -1 : 1)
        return TimeZone(secondsFromGMT: seconds)
    }

    // MARK: - EXIF GPS

    private static func gpsCoordinate(from props: [CFString: Any]) -> CLLocationCoordinate2D? {
        guard let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any],
              let lat = gps[kCGImagePropertyGPSLatitude] as? Double,
              let lon = gps[kCGImagePropertyGPSLongitude] as? Double
        else { return nil }
        let latRef = (gps[kCGImagePropertyGPSLatitudeRef] as? String) ?? "N"
        let lonRef = (gps[kCGImagePropertyGPSLongitudeRef] as? String) ?? "E"
        let coordinate = CLLocationCoordinate2D(
            latitude: latRef == "S" ? -lat : lat,
            longitude: lonRef == "W" ? -lon : lon
        )
        guard CLLocationCoordinate2DIsValid(coordinate),
              coordinate.latitude != 0 || coordinate.longitude != 0
        else { return nil }
        return coordinate
    }
}
