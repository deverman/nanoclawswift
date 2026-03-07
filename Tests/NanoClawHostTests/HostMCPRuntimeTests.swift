import Testing

@testable import NanoClawHost

@Test
func testShouldRestartServerWhenSpecChanges() {
    let current = HostMCPRuntime.ServerSpec(
        id: "focusrelay",
        command: "/opt/homebrew/bin/focusrelay",
        arguments: ["serve"],
        environment: [:],
        workingDirectory: ""
    )
    let desired = HostMCPRuntime.ServerSpec(
        id: "focusrelay",
        command: "/opt/homebrew/bin/focusrelay",
        arguments: ["serve", "--verbose"],
        environment: [:],
        workingDirectory: ""
    )

    #expect(
        HostMCPRuntime.shouldRestartServer(
            currentSpec: current,
            desiredSpec: desired,
            processIsRunning: true
        )
    )
}

@Test
func testShouldRestartServerWhenProcessIsDead() {
    let spec = HostMCPRuntime.ServerSpec(
        id: "focusrelay",
        command: "/opt/homebrew/bin/focusrelay",
        arguments: ["serve"],
        environment: [:],
        workingDirectory: ""
    )

    #expect(
        HostMCPRuntime.shouldRestartServer(
            currentSpec: spec,
            desiredSpec: spec,
            processIsRunning: false
        )
    )
}

@Test
func testShouldNotRestartServerWhenSpecMatchesAndProcessIsRunning() {
    let spec = HostMCPRuntime.ServerSpec(
        id: "focusrelay",
        command: "/opt/homebrew/bin/focusrelay",
        arguments: ["serve"],
        environment: [:],
        workingDirectory: ""
    )

    #expect(
        HostMCPRuntime.shouldRestartServer(
            currentSpec: spec,
            desiredSpec: spec,
            processIsRunning: true
        ) == false
    )
}
