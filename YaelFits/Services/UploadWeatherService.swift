import CoreLocation
import Foundation
#if canImport(WeatherKit)
import WeatherKit
#endif

/// Stamps in-flight uploads with current weather + location. Used
/// by `RealGenerationOrchestrator` in three places: parallel to
/// Bria (most common path), the Save-as-2D fast path, and one
/// last-chance fetch at finalize time.
///
/// `nil` returns are acceptable — the outfit just gets no tag.
final class UploadWeatherService: @unchecked Sendable {
    static let shared = UploadWeatherService()

    private let delegate = LocationDelegate()
    private let geocoder = CLGeocoder()
#if canImport(WeatherKit)
    private let weatherService = WeatherService.shared
#endif

    /// Lazy-created on MainActor so CL delegate callbacks fire on the
    /// main run loop. CLLocationManager dispatches its callbacks on
    /// the thread that created it — if the singleton first lands on
    /// a background Task's thread (which has no run loop), the
    /// callbacks never fire and every fetch returns nil after the
    /// timeout.
    private var locationManager: CLLocationManager?

    private init() {}

    func fetchCurrentLocationName() async -> String? {
        guard let location = await currentLocation() else { return nil }
        do {
            let placemarks = try await geocoder.reverseGeocodeLocation(location)
            guard let placemark = placemarks.first else { return nil }
            // Prefer the most user-recognizable name available:
            // city → sub-locality (neighborhood) → administrative area.
            return placemark.locality
                ?? placemark.subLocality
                ?? placemark.administrativeArea
                ?? placemark.name
        } catch {
            return nil
        }
    }

    /// Current weather snapshot at the device's location. Requires
    /// the WeatherKit capability + entitlement; returns `nil` if
    /// unavailable.
    func fetchCurrentWeather() async -> Weather? {
#if canImport(WeatherKit)
        guard let location = await currentLocation() else {
            #if DEBUG
            print("[Weather] skipped — no location")
            #endif
            return nil
        }
        do {
            let current = try await weatherService.weather(for: location).currentWeather
            let tempF = Int(current.temperature.converted(to: .fahrenheit).value.rounded())
            let tempC = Int(current.temperature.converted(to: .celsius).value.rounded())
            return Weather(
                tempF: tempF,
                tempC: tempC,
                condition: weatherConditionLabel(for: current.condition)
            )
        } catch {
            // Surface the actual WeatherKit failure so entitlement /
            // propagation issues are visible in the Xcode console
            // (was a silent nil before, which made diagnosis impossible).
            #if DEBUG
            print("[Weather] fetch failed: \(error)")
            #endif
            return nil
        }
#else
        return nil
#endif
    }

#if canImport(WeatherKit)
    /// Map `WeatherKit.WeatherCondition` to the lowercase labels
    /// `Weather.visualKind` recognises ("sunny", "partly cloudy",
    /// etc.). Unmapped → `""` (falls through to `.unknown`).
    private func weatherConditionLabel(for condition: WeatherCondition) -> String {
        switch condition {
        case .clear, .mostlyClear: return "clear"
        case .sunFlurries, .hot: return "sunny"
        case .partlyCloudy: return "partly cloudy"
        case .cloudy, .mostlyCloudy, .haze, .smoky, .foggy: return "cloudy"
        case .drizzle, .rain, .heavyRain, .freezingDrizzle, .freezingRain: return "rainy"
        case .thunderstorms, .strongStorms, .isolatedThunderstorms, .scatteredThunderstorms,
             .tropicalStorm, .hurricane: return "stormy"
        case .snow, .heavySnow, .blowingSnow, .blizzard, .flurries, .wintryMix, .sleet, .hail, .sunShowers: return "snowy"
        case .frigid: return "cold"
        case .breezy: return "breezy"
        case .windy: return "windy"
        default: return ""
        }
    }
#endif

    // MARK: - Location lookup

    /// Resolves authorization first (the old version called
    /// `requestLocation` before iOS had a chance to grant permission,
    /// which silently no-ops on `.notDetermined`), then triggers a
    /// single location update bounded by a 5-second deadline.
    @MainActor
    private func currentLocation() async -> CLLocation? {
        let manager = ensureLocationManager()

        let status = await delegate.waitForAuthorization(
            currentStatus: manager.authorizationStatus,
            trigger: { manager.requestWhenInUseAuthorization() }
        )
        switch status {
        case .authorizedAlways, .authorizedWhenInUse:
            break
        default:
            return nil
        }

        return await delegate.requestSingleLocation(
            trigger: { manager.requestLocation() },
            timeout: 5
        )
    }

    @MainActor
    private func ensureLocationManager() -> CLLocationManager {
        if let m = locationManager { return m }
        let m = CLLocationManager()
        m.desiredAccuracy = kCLLocationAccuracyKilometer
        m.delegate = delegate
        locationManager = m
        return m
    }
}

/// Bridges CLLocationManager's callback API into async/await.
/// Broadcasts each callback to *all* pending continuations so the
/// orchestrator's parallel weather + location fetches (which both
/// hit `currentLocation`) share the same GPS read instead of
/// racing each other and clobbering the delegate.
private final class LocationDelegate: NSObject, CLLocationManagerDelegate, @unchecked Sendable {
    private var locationContinuations: [CheckedContinuation<CLLocation?, Never>] = []
    private var authContinuations: [CheckedContinuation<CLAuthorizationStatus, Never>] = []
    private let lock = NSLock()

    func requestSingleLocation(trigger: () -> Void, timeout: TimeInterval) async -> CLLocation? {
        await withCheckedContinuation { (continuation: CheckedContinuation<CLLocation?, Never>) in
            lock.lock()
            locationContinuations.append(continuation)
            lock.unlock()
            trigger()
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                self?.resolveLocationWaiters(with: nil)
            }
        }
    }

    func waitForAuthorization(
        currentStatus: CLAuthorizationStatus,
        trigger: () -> Void
    ) async -> CLAuthorizationStatus {
        if currentStatus != .notDetermined { return currentStatus }
        return await withCheckedContinuation { (continuation: CheckedContinuation<CLAuthorizationStatus, Never>) in
            lock.lock()
            authContinuations.append(continuation)
            lock.unlock()
            trigger()
            // Bound the wait so a user who swipes away the system
            // prompt (rather than tapping Allow / Deny) doesn't stall
            // the upload pipeline forever.
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                self?.resolveAuthWaiters(with: .denied)
            }
        }
    }

    private func resolveLocationWaiters(with location: CLLocation?) {
        lock.lock()
        let pending = locationContinuations
        locationContinuations.removeAll()
        lock.unlock()
        for c in pending { c.resume(returning: location) }
    }

    private func resolveAuthWaiters(with status: CLAuthorizationStatus) {
        lock.lock()
        let pending = authContinuations
        authContinuations.removeAll()
        lock.unlock()
        for c in pending { c.resume(returning: status) }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        resolveLocationWaiters(with: locations.first)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        resolveLocationWaiters(with: nil)
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        guard status != .notDetermined else { return }
        resolveAuthWaiters(with: status)
    }
}
