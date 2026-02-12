import Foundation
import Logging

actor GroupQueue {
    private let logger: Logger
    private let maxConcurrentGroups: Int
    private let processor: @Sendable (QueueJob) async -> Void

    private var pendingByGroup: [String: [QueueJob]] = [:]
    private var activeGroups: Set<String> = []
    private var activeCount = 0

    init(
        maxConcurrentGroups: Int,
        logger: Logger,
        processor: @escaping @Sendable (QueueJob) async -> Void
    ) {
        self.maxConcurrentGroups = max(1, maxConcurrentGroups)
        self.logger = logger
        self.processor = processor
    }

    func enqueue(_ job: QueueJob) {
        pendingByGroup[job.group.folder, default: []].append(job)
        scheduleWorkersIfNeeded()
    }

    func queueDepth() -> Int {
        pendingByGroup.values.reduce(0) { $0 + $1.count }
    }

    private func scheduleWorkersIfNeeded() {
        guard activeCount < maxConcurrentGroups else { return }

        let candidateGroup = pendingByGroup.first { group, jobs in
            !jobs.isEmpty && !activeGroups.contains(group)
        }?.key

        guard let candidateGroup else { return }

        activeGroups.insert(candidateGroup)
        activeCount += 1

        Task { [weak self] in
            await self?.runGroupWorker(groupFolder: candidateGroup)
        }

        if activeCount < maxConcurrentGroups {
            scheduleWorkersIfNeeded()
        }
    }

    private func dequeueNext(for groupFolder: String) -> QueueJob? {
        guard var queue = pendingByGroup[groupFolder], !queue.isEmpty else {
            return nil
        }
        let next = queue.removeFirst()
        pendingByGroup[groupFolder] = queue
        return next
    }

    private func runGroupWorker(groupFolder: String) async {
        logger.debug("Group queue worker started for \(groupFolder)")
        while let job = dequeueNext(for: groupFolder) {
            await processor(job)
        }

        activeGroups.remove(groupFolder)
        activeCount = max(0, activeCount - 1)
        logger.debug("Group queue worker stopped for \(groupFolder)")
        scheduleWorkersIfNeeded()
    }
}
