import Foundation

/// Minimal event-logging helper. Fires off events to the
/// `analytics_events` Supabase table in a detached, fire-and-
/// forget task — never blocks UI, never throws to the caller,
/// silently swallows failures.
///
/// Query via the Supabase dashboard SQL editor (no in-app read
/// path). See the migration file for example funnel queries.
///
/// Adding a new event:
///   1. Pick a snake_case name with a feature prefix, e.g.
///      `contacts_prompt_shown` or `share_outfit_completed`.
///   2. Call `Analytics.log("name", properties: [...])` at the
///      moment the event happens. Properties is optional.
///   3. No backend changes needed — the table accepts any
///      event name + free-form JSON properties.
enum Analytics {

    static func log(
        _ event: String,
        properties: [String: AnalyticsValue] = [:]
    ) {
        Task.detached(priority: .background) {
            await sendEvent(name: event, properties: properties)
        }
    }

    /// Loosely typed property value. Restricting to a small set
    /// of concrete types so we never blow up on something the
    /// JSON encoder can't represent.
    enum AnalyticsValue: Encodable {
        case string(String)
        case int(Int)
        case double(Double)
        case bool(Bool)
        case null

        func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            switch self {
            case .string(let s): try c.encode(s)
            case .int(let i): try c.encode(i)
            case .double(let d): try c.encode(d)
            case .bool(let b): try c.encode(b)
            case .null: try c.encodeNil()
            }
        }
    }

    private struct EventInsert: Encodable {
        let user_id: String?
        let event_name: String
        let properties: [String: AnalyticsValue]
    }

    private static func sendEvent(
        name: String,
        properties: [String: AnalyticsValue]
    ) async {
        let userId = try? await supabase.auth.user().id.uuidString
        do {
            try await supabase
                .from("analytics_events")
                .insert(EventInsert(
                    user_id: userId,
                    event_name: name,
                    properties: properties
                ))
                .execute()
        } catch {
            // Analytics is fire-and-forget. We don't surface
            // errors — a failed event is not worth blocking the
            // user or polluting logs over.
        }
    }
}

/// Convenience initializers so callers don't have to wrap
/// every property value in `.string(...)` / `.int(...)`.
extension Analytics.AnalyticsValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral, ExpressibleByBooleanLiteral {
    init(stringLiteral value: String) { self = .string(value) }
    init(integerLiteral value: Int) { self = .int(value) }
    init(floatLiteral value: Double) { self = .double(value) }
    init(booleanLiteral value: Bool) { self = .bool(value) }
}
