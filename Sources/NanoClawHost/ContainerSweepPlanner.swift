import Foundation

enum ContainerSweepAction: Equatable {
    case stopAndRemove(name: String)
    case remove(name: String)
}

enum ContainerSweepPlanner {
    static func plan(
        from entries: [[String: String]],
        activeSessionContainerNames: Set<String>
    ) -> [ContainerSweepAction] {
        var actions: [ContainerSweepAction] = []

        for entry in entries {
            guard let name = entry["name"], name.hasPrefix("nanoclaw-") else {
                continue
            }
            if activeSessionContainerNames.contains(name) {
                continue
            }

            let status = entry["status"]?.lowercased() ?? ""
            if status == "running" {
                actions.append(.stopAndRemove(name: name))
            } else {
                actions.append(.remove(name: name))
            }
        }

        return actions
    }
}
