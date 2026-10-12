// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// Swift jobs leave the output URL empty and keep the object path after `-o`.
public func emittedObjectPath(arguments: [String], outputFilePath: String?) -> String? {
    if let outputFilePath, outputFilePath.hasSuffix(".o") {
        return outputFilePath
    }
    guard let index = arguments.lastIndex(of: "-o"), index + 1 < arguments.count else { return nil }
    let path = arguments[index + 1]
    return path.hasSuffix(".o") ? path : nil
}

/// Swift package jobs compile one object per file under tmp. The planned
/// `Module.o` path is never written. Link the objects that were actually
/// emitted, and skip any the driver link job already names.
public func objectFilesToLink(compiled: [String], planned: [String], alreadyLinked: Set<String>, fileExists: (String) -> Bool) -> [String] {
    var seen = alreadyLinked
    var result: [String] = []
    for path in compiled where path.hasSuffix(".o") && seen.insert(path).inserted {
        result.append(path)
    }
    for path in planned where path.hasSuffix(".o") && fileExists(path) && seen.insert(path).inserted {
        result.append(path)
    }
    return result
}

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
    /// Physical device that built the app. Set `PALM_DEVICE_UDID` when more than one iOS device is visible.
    static var deviceUDID = ProcessInfo.processInfo.environment["PALM_DEVICE_UDID"]
    static var command: ([String]) throws -> (Int32, String) = { arguments in
        try CommandRunner.run(executable: "/usr/bin/env", arguments: ["agent-device"] + arguments, currentDirectory: nil)
    }

    public static func run(process: RunningProcess, checks: [UICheck]) throws -> String {
        var lines: [String] = []
        // open without --relaunch keeps the process the phone already launched.
        lines.append(try invoke(["open", process.bundleIdentifier, "--foreground"] + deviceFlags()))
        for check in checks {
            guard let checkArguments = arguments(for: check) else {
                throw ControlError.testFailed("unknown ui action \(check.action)")
            }
            lines.append(try invoke(checkArguments + deviceFlags()))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func arguments(for check: UICheck) -> [String]? {
        switch check.action {
        case "snapshot":
            return check.name.isEmpty ? ["snapshot", "-i"] : ["snapshot", "-i", "--scope", check.name]
        case "wait":
            return ["wait", "text", check.name]
        case "press":
            return ["press", check.name, "--settle"]
        case "click":
            return ["click", check.name, "--settle"]
        default:
            return nil
        }
    }

    private static func deviceFlags() -> [String] {
        var flags = ["--platform", "ios"]
        if let deviceUDID, !deviceUDID.isEmpty {
            flags.append(contentsOf: ["--udid", deviceUDID])
        }
        return flags
    }

    private static func invoke(_ arguments: [String]) throws -> String {
        let result = try command(arguments)
        guard result.0 == 0 else {
            throw ControlError.testFailed(result.1.isEmpty ? "agent-device \(arguments.joined(separator: " ")) failed" : result.1)
        }
        return result.1
    }
}
