import Foundation
import Logging

public enum NanoClawLog {
    private static var bootstrapOnce = false

    public static func make(_ label: String) -> Logger {
        if !bootstrapOnce {
            LoggingSystem.bootstrap { label in
                var handler = StreamLogHandler.standardOutput(label: label)
                handler.logLevel = NanoClawLog.defaultLevel()
                return handler
            }
            bootstrapOnce = true
        }
        return Logger(label: label)
    }

    private static func defaultLevel() -> Logger.Level {
        if let level = ProcessInfo.processInfo.environment["NANOCLAW_LOG_LEVEL"],
           let parsed = Logger.Level(rawValue: level.lowercased()) {
            return parsed
        }
        return .info
    }
}
