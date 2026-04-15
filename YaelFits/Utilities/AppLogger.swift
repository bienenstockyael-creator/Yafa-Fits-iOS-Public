import OSLog

enum AppLogger {
    static let auth = Logger(subsystem: "com.yafa", category: "auth")
    static let data = Logger(subsystem: "com.yafa", category: "data")
    static let social = Logger(subsystem: "com.yafa", category: "social")
    static let storage = Logger(subsystem: "com.yafa", category: "storage")
    static let cache = Logger(subsystem: "com.yafa", category: "cache")
}
