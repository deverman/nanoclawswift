import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

actor TestEnvironmentLock {
    static let shared = TestEnvironmentLock()
    private var isLocked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func withEnv<T>(
        _ key: String,
        _ value: String?,
        body: () async throws -> T
    ) async rethrows -> T {
        try await withEnvs([key: value], body: body)
    }

    func withEnvs<T>(
        _ values: [String: String?],
        body: () async throws -> T
    ) async rethrows -> T {
        await acquire()
        var restoredValues: [String: String?] = [:]

        for key in values.keys {
            restoredValues[key] = currentEnvValue(key)
        }

        for (key, value) in values {
            if let value {
                setenv(key, value, 1)
            } else {
                unsetenv(key)
            }
        }

        defer {
            for (key, value) in restoredValues {
                if let value {
                    setenv(key, value, 1)
                } else {
                    unsetenv(key)
                }
            }
            release()
        }

        return try await body()
    }

    private func acquire() async {
        if !isLocked {
            isLocked = true
            return
        }

        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    private func release() {
        if waiters.isEmpty {
            isLocked = false
            return
        }

        let next = waiters.removeFirst()
        next.resume()
    }

    private func currentEnvValue(_ key: String) -> String? {
        guard let value = getenv(key) else { return nil }
        return String(cString: value)
    }
}
