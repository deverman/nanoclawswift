import Foundation
import Logging
import Configuration

public enum NanoClawLog {
    private static let bootstrap: Void = {
        LoggingSystem.bootstrap { label in
            var handler = StreamLogHandler.standardOutput(label: label)
            handler.logLevel = NanoClawLog.defaultLevel()
            return handler
        }
    }()

    public static func make(_ label: String) -> Logger {
        _ = bootstrap
        return Logger(label: label)
    }

    private static func defaultLevel() -> Logger.Level {
        if #available(macOS 15.0, iOS 18.0, *) {
            let reader = ConfigReader(providers: [EnvironmentVariablesProvider()])
            if let level = reader.string(forKey: "NANOCLAW_LOG_LEVEL"),
               let parsed = Logger.Level(rawValue: level.lowercased()) {
                return parsed
            }
        } else if let level = ProcessInfo.processInfo.environment["NANOCLAW_LOG_LEVEL"],
                  let parsed = Logger.Level(rawValue: level.lowercased()) {
            return parsed
        }
        return .info
    }
}
