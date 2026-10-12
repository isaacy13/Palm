// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// Swift jobs leave the output URL empty and keep the object path after `-o`.
public func compileArgumentStamp(_ arguments: [String]) -> String {
    var hash: UInt64 = 1469598103934665603
    for argument in arguments {
        for byte in normalizingDataContainerUUID(argument).utf8 {
            hash ^= UInt64(byte)
            hash &*= 1099511628211
        }
        hash &*= 1099511628211
    }
    return String(hash, radix: 16)
}

/// PalmHost's data container UUID changes on reinstall even when the files
/// were moved intact. Drop that one path segment so the compile stamp matches.
public func normalizingDataContainerUUID(_ text: String) -> String {
    guard let regex = dataContainerUUID else { return text }
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    return regex.stringByReplacingMatches(in: text, range: range, withTemplate: "/Containers/Data/Application/")
}

private let dataContainerUUID = try? NSRegularExpression(
    pattern: #"/Containers/Data/Application/[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}/"#
)

public func compileInputPaths(arguments: [String], declaredInputs: [String], output: String) -> [String] {
    var seen = Set<String>()
    var paths: [String] = []
    func add(_ path: String) {
        guard path != output, path.hasPrefix("/") else { return }
        let ext = (path as NSString).pathExtension.lowercased()
        guard ["swift", "m", "mm", "c", "cc", "cpp", "h", "hh", "modulemap"].contains(ext) else { return }
        if seen.insert(path).inserted {
            paths.append(path)
        }
    }
    declaredInputs.forEach(add)
    arguments.forEach(add)
    return paths
}

/// An object can be reused when the compiler arguments match the saved stamp
/// and every input is older than that object.
public func compileOutputIsFresh(outputExists: Bool, outputDate: Date, inputDates: [Date], savedStamp: String?, argumentStamp: String) -> Bool {
    guard outputExists, savedStamp == argumentStamp, !inputDates.isEmpty else { return false }
    return inputDates.allSatisfy { $0 <= outputDate }
}

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

/// The on-device linker stores argument pointers in a 64-wide inline buffer,
/// then appends `ld64.lld`. Once the buffer is full that grow moves every
/// short flag, including `-arch`, and lld reports the arch as missing.
/// One response-file argument stays inside the inline buffer. lld expands it.
/// The compiler driver sometimes emits two objects for one Crashlytics file,
/// `Name-abcdef.o` and `Name-123456.o`. Linking both defines the same ObjC class.
public func dedupingRepeatedObjects(_ arguments: [String]) -> [String] {
    var seen = Set<String>()
    return arguments.filter { argument in
        guard argument.hasSuffix(".o"), !argument.hasPrefix("-") else { return true }
        let name = (argument as NSString).lastPathComponent
        return seen.insert(driverObjectStem(name)).inserted
    }
}

private func driverObjectStem(_ name: String) -> String {
    guard let regex = try? NSRegularExpression(pattern: #"^(.+)-[0-9a-f]{6}\.o$"#) else { return name }
    let range = NSRange(name.startIndex..<name.endIndex, in: name)
    guard let match = regex.firstMatch(in: name, range: range),
          match.numberOfRanges > 1,
          let stem = Range(match.range(at: 1), in: name) else { return name }
    return String(name[stem])
}

public func linkerInvocation(arguments: [String], responseFile: String) -> [String] {
    guard arguments.count >= 64 else { return arguments }
    return ["@" + responseFile]
}

/// Non-SDK frameworks linked with `-F` and `-framework` are recorded as
/// `@rpath` loads. The guest looks for them in the app's `Frameworks` directory.
public func frameworksToBundle(arguments: [String], sdkRoot: String, fileExists: (String) -> Bool, isDynamicLibrary: (String) -> Bool) -> [String] {
    var search: [String] = []
    var names: [String] = []
    var index = 0
    while index < arguments.count {
        let argument = arguments[index]
        if argument == "-F", index + 1 < arguments.count {
            let directory = arguments[index + 1]
            if directory != sdkRoot && !directory.hasPrefix(sdkRoot + "/") {
                search.append(directory)
            }
            index += 2
            continue
        }
        if argument == "-framework", index + 1 < arguments.count {
            names.append(arguments[index + 1])
            index += 2
            continue
        }
        index += 1
    }
    var bundles: [String] = []
    var seen = Set<String>()
    for name in names where seen.insert(name).inserted {
        for directory in search {
            let candidate = (directory as NSString).appendingPathComponent("\(name).framework")
            let binary = (candidate as NSString).appendingPathComponent(name)
            if fileExists(candidate), isDynamicLibrary(binary) {
                bundles.append(candidate)
                break
            }
        }
    }
    return bundles
}

/// Keep `-framework Name` only when `Name.framework` exists under a `-F` path
/// already on the link line. Package modules and Mac-only imports are not
/// frameworks; their objects are already on the link line.
public func droppingMissingFrameworks(_ arguments: [String], fileExists: (String) -> Bool) -> [String] {
    var search: [String] = []
    var result: [String] = []
    var index = 0
    while index < arguments.count {
        let argument = arguments[index]
        if argument == "-F", index + 1 < arguments.count {
            search.append(arguments[index + 1])
            result.append(argument)
            result.append(arguments[index + 1])
            index += 2
            continue
        }
        if argument == "-framework", index + 1 < arguments.count {
            let name = arguments[index + 1]
            let found = search.contains { directory in
                fileExists((directory as NSString).appendingPathComponent("\(name).framework"))
            }
            if found {
                result.append(argument)
                result.append(name)
            }
            index += 2
            continue
        }
        result.append(argument)
        index += 1
    }
    return result
}

/// The 26.5 SDK does not export the iOS 27 HealthKit and FoundationModels
/// symbols the repaired interfaces describe. The phone is running that OS, so
/// the link records them as dynamic lookups. Skip `libclang_rt.ios` when the
/// compiler runtime archive is not in the app container.
public func preparingLinkArguments(_ arguments: [String], runtimeLibraryExists: Bool) -> [String] {
    var arguments = arguments
    if let sdkFlag = arguments.firstIndex(of: "-syslibroot"), sdkFlag + 1 < arguments.count {
        if runtimeLibraryExists {
            let documents = URL(fileURLWithPath: arguments[sdkFlag + 1])
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            arguments.append("-L")
            arguments.append(documents.appendingPathComponent("lib").path)
            arguments.append("-lclang_rt.ios")
        }
        if !arguments.contains("-adhoc_codesign") {
            arguments.append("-adhoc_codesign")
        }
    }
    if !arguments.contains("-undefined") {
        arguments.append(contentsOf: ["-undefined", "dynamic_lookup"])
    }
    return arguments
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
            var built = try driver.plan(
                project: project,
                target: request.target,
                kind: request.kind,
                tests: request.tests,
                context: context
            )
            built.compileThreads = request.threads
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
            // A name that is not a test-target file has no binary. UI checks still
            // run on the Mac against the launch. An empty name list is not this path:
            // the driver treats that as every test source.
            if plan.testExecutable == nil, !request.ui.isEmpty {
                log.append("no on-device test binary; \(request.ui.count) ui checks run against pid \(process.pid)")
                return
            }
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
    /// The guest window is hosted inside PalmHost. Opening the guest bundle id
    /// foregrounds a different SpringBoard app with the same id.
    static var hostBundleIdentifier: String? = {
        let value = ProcessInfo.processInfo.environment["PALM_HOST_BUNDLE_ID"]
        guard let value, !value.isEmpty else { return nil }
        return value
    }()
    static var command: ([String]) throws -> (Int32, String) = { arguments in
        try CommandRunner.run(executable: "/usr/bin/env", arguments: ["agent-device"] + arguments, currentDirectory: nil)
    }

    public static func run(process: RunningProcess, checks: [UICheck]) throws -> String {
        var lines: [String] = []
        let bundle = hostBundleIdentifier ?? process.bundleIdentifier
        // open without --relaunch keeps the process the phone already launched.
        lines.append(try invoke(["open", bundle, "--foreground"] + deviceFlags()))
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
