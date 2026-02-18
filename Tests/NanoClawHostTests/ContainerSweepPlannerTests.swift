import Testing

@testable import NanoClawHost

@Test
func testContainerSweepPlanSkipsActiveSessionContainer() {
    let entries: [[String: String]] = [
        ["name": "nanoclaw-main-123", "status": "running"],
    ]

    let actions = ContainerSweepPlanner.plan(
        from: entries,
        activeSessionContainerNames: ["nanoclaw-main-123"]
    )

    #expect(actions.isEmpty)
}

@Test
func testContainerSweepPlanStopsAndRemovesRunningOrphans() {
    let entries: [[String: String]] = [
        ["name": "nanoclaw-main-100", "status": "running"],
        ["name": "nanoclaw-team-200", "status": "RUNNING"],
    ]

    let actions = ContainerSweepPlanner.plan(
        from: entries,
        activeSessionContainerNames: []
    )

    #expect(actions == [
        .stopAndRemove(name: "nanoclaw-main-100"),
        .stopAndRemove(name: "nanoclaw-team-200"),
    ])
}

@Test
func testContainerSweepPlanRemovesExitedContainersWithoutStop() {
    let entries: [[String: String]] = [
        ["name": "nanoclaw-main-100", "status": "exited"],
        ["name": "nanoclaw-team-200", "status": "created"],
    ]

    let actions = ContainerSweepPlanner.plan(
        from: entries,
        activeSessionContainerNames: []
    )

    #expect(actions == [
        .remove(name: "nanoclaw-main-100"),
        .remove(name: "nanoclaw-team-200"),
    ])
}

@Test
func testContainerSweepPlanIgnoresNonNanoclawContainers() {
    let entries: [[String: String]] = [
        ["name": "redis", "status": "running"],
        ["name": "postgres", "status": "exited"],
    ]

    let actions = ContainerSweepPlanner.plan(
        from: entries,
        activeSessionContainerNames: []
    )

    #expect(actions.isEmpty)
}

@Test
func testDeterministicContainerNameSanitizesGroupFolder() {
    let name = ContainerSessionManager.deterministicContainerName(for: "Team Alpha/Main")
    #expect(name == "nanoclaw-team-alpha-main-active")
}
