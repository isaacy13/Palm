// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

public protocol DeviceToolchain {
    func pull(_ request: ControlRequest, log: ControlLog) throws
    func compile(_ plan: BuildPlan, log: ControlLog) throws
    func link(_ plan: BuildPlan, log: ControlLog) throws
    func sign(_ plan: BuildPlan, log: ControlLog) throws
    func launch(_ plan: BuildPlan, log: ControlLog) throws -> RunningProcess
    func runTests(_ plan: BuildPlan, process: RunningProcess, names: [String], log: ControlLog) throws
}

public struct ControlExecutor<Toolchain: DeviceToolchain> {
    public var toolchain: Toolchain
    public var sourceRoot: URL
    public var context: DriverContext
    public var driver = ProjectDriver()

    public init(toolchain: Toolchain, sourceRoot: URL, context: DriverContext) {
        self.toolchain = toolchain
        self.sourceRoot = sourceRoot
        self.context = context
    }

    public func run(_ request: ControlRequest) -> ControlResponse {
        let allowed = request.allowedStages
        let log = ControlLog()
        var stagesRun: [ControlStage] = []
        var process: RunningProcess?
        var plan: BuildPlan?

        do {
            for stage in allowed {
                try runStage(stage, allowed: allowed, request: request, log: log, plan: &plan, process: &process)
                stagesRun.append(stage)
            }
            let launched = process != nil && allowed.contains(.launch)
            return ControlResponse(
                success: true,
                kind: request.kind,
                stagesRun: stagesRun,
                failedStage: nil,
                logs: log.text,
                launched: launched,
                process: launched ? process : nil
            )
        } catch {
            return ControlResponse(
                success: false,
                kind: request.kind,
                stagesRun: stagesRun,
                failedStage: allowed.dropFirst(stagesRun.count).first,
                logs: log.text + String(describing: error) + "\n",
                launched: false,
                process: nil
            )
        }
    }

    private func runStage(_ stage: ControlStage,
                          allowed: [ControlStage],
                          request: ControlRequest,
                          log: ControlLog,
                          plan: inout BuildPlan?,
                          process: inout RunningProcess?) throws {
        guard allowed.contains(stage) else {
            throw ControlError.stageNotRequested(stage)
        }
        log.append("stage \(stage.rawValue)")
        switch stage {
        case .pull:
            let destination = request.repository == nil
                ? sourceRoot
                : context.workRoot.appendingPathComponent("src")
            try GitPuller.pull(repository: request.repository, branch: request.branch, into: destination)
            try toolchain.pull(request, log: log)
        case .compile:
            let root = request.repository == nil ? sourceRoot : context.workRoot.appendingPathComponent("src")
            let project = root.appendingPathComponent(request.project)
            let built = try driver.plan(
                project: project,
                target: request.target,
                kind: request.kind,
                tests: request.tests,
                context: context
            )
            if request.kind != .buildRunAndTests && built.includesTests {
                throw ControlError.stageNotRequested(.test)
            }
            log.append(built.descriptionForLog)
            plan = built
            try toolchain.compile(built, log: log)
        case .link:
            guard let plan else { throw ControlError.linkFailed("link started before compile") }
            try toolchain.link(plan, log: log)
        case .sign:
            guard let plan else { throw ControlError.signFailed("sign started before compile") }
            try toolchain.sign(plan, log: log)
        case .launch:
            guard allowed.contains(.launch) else { throw ControlError.stageNotRequested(.launch) }
            guard let plan else { throw ControlError.launchFailed("launch started before compile") }
            process = try toolchain.launch(plan, log: log)
        case .test:
            guard allowed.contains(.test) else { throw ControlError.stageNotRequested(.test) }
            guard let plan else { throw ControlError.testFailed("tests started before compile") }
            guard let process else { throw ControlError.testFailed("tests started before launch") }
            try toolchain.runTests(plan, process: process, names: request.tests, log: log)
        }
    }
}

/// Mac side of a finished phone response. UI automation runs only for
/// build-run-and-tests, and only against a launch the phone reported.
public struct MacAgent {
    public var runUI: (_ process: RunningProcess, _ checks: [UICheck]) throws -> String

    public init(runUI: @escaping (_ process: RunningProcess, _ checks: [UICheck]) throws -> String = AgentDeviceRunner.run) {
        self.runUI = runUI
    }

    public func finish(_ response: ControlResponse, request: ControlRequest) -> ControlResponse {
        guard request.kind == .buildRunAndTests, response.success, response.launched, let process = response.process else {
            return response
        }
        do {
            let uiLog = try runUI(process, request.ui)
            var updated = response
            updated.logs += uiLog
            return updated
        } catch {
            var updated = response
            updated.success = false
            updated.logs += String(describing: error) + "\n"
            return updated
        }
    }
}

public enum AgentDeviceRunner {
    public static func run(process: RunningProcess, checks: [UICheck]) throws -> String {
        var lines = ["ui open \(process.bundleIdentifier) pid \(process.pid)"]
        for check in checks {
            lines.append("ui \(check.action) \(check.name)")
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
