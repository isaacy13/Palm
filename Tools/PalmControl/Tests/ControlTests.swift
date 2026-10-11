// SPDX-License-Identifier: AGPL-3.0-or-later

import XCTest
@testable import PalmControl

final class ControlTests: XCTestCase {
    func testThreeRequestsStayInsideTheirStages() throws {
        let fixture = fixtureRoot()
        let context = try makeContext()
        let recording = RecordingToolchain()
        let executor = ControlExecutor(toolchain: recording, sourceRoot: fixture, context: context)

        let build = executor.run(request(.build))
        XCTAssertEqual(build.stagesRun, [.pull, .compile, .link, .sign])
        XCTAssertFalse(build.launched)
        XCTAssertNil(build.process)
        XCTAssertEqual(recording.calls, ["pull", "compile", "link", "sign"])
        XCTAssertTrue(build.logs.contains("App.swift"))
        XCTAssertTrue(build.logs.contains("KitLabel.swift"))
        XCTAssertTrue(build.logs.contains("SwiftUI"))
        XCTAssertTrue(build.logs.contains("UIKit"))
        XCTAssertFalse(build.logs.contains("SampleTests.swift"))

        recording.calls.removeAll()
        let run = executor.run(request(.buildAndRun))
        XCTAssertEqual(run.stagesRun, [.pull, .compile, .link, .sign, .launch])
        XCTAssertTrue(run.launched)
        XCTAssertEqual(run.process?.bundleIdentifier, "com.palm.SwiftUIUIKit")
        XCTAssertEqual(recording.calls, ["pull", "compile", "link", "sign", "launch"])
        XCTAssertFalse(recording.calls.contains("test"))

        recording.calls.removeAll()
        let tested = executor.run(request(.buildRunAndTests, tests: ["SampleTests"], ui: [UICheck(name: "home", action: "snapshot")]))
        XCTAssertEqual(tested.stagesRun, [.pull, .compile, .link, .sign, .launch, .test])
        XCTAssertTrue(tested.launched)
        XCTAssertEqual(recording.calls.last, "test")
        XCTAssertTrue(tested.logs.contains("SampleTests.swift"))
    }

    func testCompileFailureDoesNotLinkOrLaunch() throws {
        let recording = RecordingToolchain()
        recording.failCompile = true
        let executor = ControlExecutor(toolchain: recording, sourceRoot: fixtureRoot(), context: try makeContext())
        let response = executor.run(request(.buildAndRun))
        XCTAssertFalse(response.success)
        XCTAssertEqual(response.stagesRun, [.pull])
        XCTAssertEqual(response.failedStage, .compile)
        XCTAssertFalse(response.launched)
        XCTAssertEqual(recording.calls, ["pull", "compile"])
        XCTAssertFalse(recording.calls.contains("link"))
        XCTAssertFalse(recording.calls.contains("launch"))
    }

    func testMacAgentRunsUIOnlyForTestRequest() throws {
        var uiCalls = 0
        let agent = MacAgent { _, checks in
            uiCalls += 1
            XCTAssertEqual(checks.map(\.name), ["home"])
            return "ui snapshot home\n"
        }
        let process = RunningProcess(pid: 7, bundleIdentifier: "com.palm.SwiftUIUIKit", executablePath: "/tmp/SwiftUIUIKit")
        let build = ControlResponse(success: true, kind: .build, stagesRun: [.pull, .compile, .link, .sign], failedStage: nil, logs: "built\n", launched: false, process: nil)
        let finishedBuild = agent.finish(build, request: request(.build))
        XCTAssertEqual(uiCalls, 0)
        XCTAssertFalse(finishedBuild.launched)

        let ran = ControlResponse(success: true, kind: .buildAndRun, stagesRun: [.launch], failedStage: nil, logs: "ran\n", launched: true, process: process)
        _ = agent.finish(ran, request: request(.buildAndRun))
        XCTAssertEqual(uiCalls, 0)

        let tested = ControlResponse(success: true, kind: .buildRunAndTests, stagesRun: [.test], failedStage: nil, logs: "tested\n", launched: true, process: process)
        let finished = agent.finish(tested, request: request(.buildRunAndTests, ui: [UICheck(name: "home", action: "snapshot")]))
        XCTAssertEqual(uiCalls, 1)
        XCTAssertTrue(finished.logs.contains("ui snapshot home"))
    }

    func testChannelBuildDoesNotLaunchAndRunDoes() throws {
        let fixture = fixtureRoot()
        let context = try makeContext()
        let recording = RecordingToolchain()
        let executor = ControlExecutor(toolchain: recording, sourceRoot: fixture, context: context)
        let server = ControlServer { executor.run($0) }
        let port = try server.start(port: 0)
        defer { server.stop() }

        let build = try ControlClient.send(request(.build), host: "127.0.0.1", port: port)
        XCTAssertTrue(build.success)
        XCTAssertFalse(build.launched)
        XCTAssertNil(build.process)
        XCTAssertTrue(build.logs.contains("KitLabel.swift"))
        XCTAssertFalse(build.stagesRun.contains(.launch))

        let run = try ControlClient.send(request(.buildAndRun), host: "127.0.0.1", port: port)
        XCTAssertTrue(run.success)
        XCTAssertTrue(run.launched)
        XCTAssertEqual(run.process?.pid, 42)
        XCTAssertFalse(run.stagesRun.contains(.test))

        let tested = try ControlClient.send(
            request(.buildRunAndTests, tests: ["SampleTests"], ui: [UICheck(name: "home", action: "snapshot")]),
            host: "127.0.0.1",
            port: port
        )
        XCTAssertTrue(tested.stagesRun.contains(.test))
        let agent = MacAgent { process, _ in
            XCTAssertEqual(process.pid, 42)
            return "ui snapshot home\n"
        }
        let finished = agent.finish(tested, request: request(.buildRunAndTests, ui: [UICheck(name: "home", action: "snapshot")]))
        XCTAssertTrue(finished.logs.contains("ui snapshot home"))
        let buildAgain = agent.finish(build, request: request(.build, ui: [UICheck(name: "home", action: "snapshot")]))
        XCTAssertFalse(buildAgain.logs.contains("ui snapshot home"))
    }

    func testGuideAIPlanExposesFrameworksAndStopsBeforeLaunch() throws {
        let project = URL(fileURLWithPath: "/Users/isaacyeang/src/GuideAI/ios/GuideAI.xcodeproj")
        XCTAssertTrue(FileManager.default.fileExists(atPath: project.path))
        let context = try makeContext()
        let driver = ProjectDriver()
        let build = try driver.plan(project: project, target: "GuideAI", kind: .build, tests: ["Ignored"], context: context)
        XCTAssertEqual(build.bundleIdentifier, "com.onexengineering.GuideAI")
        XCTAssertFalse(build.preparesLaunch)
        XCTAssertFalse(build.includesTests)
        XCTAssertTrue(build.testSources.isEmpty)
        for name in SDKFrameworks.guideAIGaps {
            XCTAssertTrue(build.sdkFrameworks.contains(name), name)
        }
        XCTAssertTrue(build.linkedFrameworks.contains("MapKit"))
        XCTAssertTrue(build.linkedFrameworks.contains("HealthKit"))
        XCTAssertTrue(build.entitlementKeys.contains("com.apple.developer.healthkit"))
        XCTAssertTrue(build.entitlementKeys.contains("com.apple.developer.weatherkit"))
        XCTAssertTrue(build.localPackages.contains("GuideAIMobilityCore"))
        XCTAssertTrue(build.localPackages.contains("Toasts"))
        XCTAssertTrue(build.localPackages.contains("WindowOverlay"))
        XCTAssertTrue(build.localPackages.contains("Lottie"))
        XCTAssertTrue(build.localPackages.contains("EmojiKit"))
        XCTAssertTrue(build.localPackages.contains("SFSymbols"))
        XCTAssertTrue(build.localPackages.contains("FirebaseCore"))
        XCTAssertTrue(build.localPackages.contains("FirebaseCrashlytics"))
        XCTAssertTrue(build.localPackages.contains("GoogleUtilities-Environment"))
        XCTAssertTrue(build.localPackages.contains("nanopb"))
        XCTAssertTrue(build.localPackages.contains("FBLPromises"))
        XCTAssertTrue(build.compileJobs.contains { job in
            job.tool == "clang" && job.sources.contains { $0.contains("FirebaseCore/Sources") } && job.arguments.contains("Firebase_VERSION=12.11.0")
        })
        XCTAssertTrue(build.compileJobs.contains { $0.arguments.contains { $0.contains("CLiteRTLM.xcframework/ios-arm64") } })
        XCTAssertTrue(build.linkJob.arguments.contains { $0.contains("FirebaseAnalytics.xcframework/ios-arm64") })
        XCTAssertFalse(build.compileJobs.contains { $0.sources.contains { $0.hasSuffix("ToolTests.swift") } })
        XCTAssertFalse(build.compileJobs.contains { $0.sources.contains { $0.hasSuffix("Package.swift") } })
        XCTAssertFalse(build.compileJobs.contains { $0.sources.contains { $0.contains("InterfaceController.swift") } })
        XCTAssertTrue(build.compileJobs.contains { job in
            job.tool == "clang" && job.sources == job.sources.filter { $0.contains("NSData+zlib/GULNSData+zlib.m") } && !job.sources.isEmpty
        })
        XCTAssertFalse(build.compileJobs.contains { $0.tool == "swiftc" && $0.moduleName.contains("-") })
        XCTAssertTrue(build.compileJobs.contains { job in
            job.moduleName == "FirebaseCoreInternal" && job.arguments.contains("SWIFT_PACKAGE") && job.arguments.contains { $0.contains("GoogleUtilities_NSData/module.modulemap") } && job.arguments.contains { $0.contains("FirebaseCoreInternal-Swift.h") }
        })
        XCTAssertTrue(build.compileJobs.contains { job in
            job.tool == "clang" && job.sources.contains { $0.contains("FIRHeartbeatLogger.m") } && job.arguments.contains { $0.contains("FirebaseCoreInternal/module.modulemap") }
        })
        XCTAssertTrue(build.compileJobs.contains { job in
            job.tool == "clang" && job.sources.contains { $0.contains("FBLPromise+Delay.m") } && job.arguments.contains { $0.contains("FBLPromises/include") }
        })
        XCTAssertTrue(build.compileJobs.contains { job in
            job.tool == "clang" && job.sources.contains { $0.contains("FIRInstallations.m") } && job.arguments.contains { $0.contains("FirebaseCore/module.modulemap") }
        })
        XCTAssertFalse(build.compileJobs.contains { job in
            job.arguments.filter { $0.contains("FirebaseCrashlytics/module.modulemap") }.count > 1
        })
        XCTAssertTrue(build.compileJobs.contains { job in
            job.tool == "clang" && job.sources.contains { $0.contains("FIRInstallationsErrorUtil.m") } && job.arguments.contains { $0.contains("FBLPromises/include/module.modulemap") }
        })
        XCTAssertFalse(build.compileJobs.contains { job in
            job.arguments.contains { $0.contains("PackageModules/FBLPromises/module.modulemap") }
        })
        XCTAssertFalse(build.compileJobs.contains { job in
            job.moduleName != "FirebaseSessions" && job.sources.contains { $0.contains("SessionInitiator.swift") }
        })
        XCTAssertTrue(build.compileJobs.contains { job in
            job.tool == "clang" && job.sources.contains { $0.contains("FIRCLSReportAdapter.m") } && job.arguments.contains("PB_ENABLE_MALLOC=1")
        })
        XCTAssertFalse(build.compileJobs.contains { $0.sources.contains { $0.hasSuffix("Button+AppIntents.swift") } })
        XCTAssertTrue(build.compileJobs.contains { job in
            job.moduleName == "EmojiKit" && job.sources.contains { $0.contains("ResourceAccessors/EmojiKit.swift") }
        })
        let moduleOrder = build.compileJobs.map(\.moduleName)
        if let promises = moduleOrder.firstIndex(of: "Promises"), let sessions = moduleOrder.firstIndex(of: "FirebaseSessions") {
            XCTAssertLessThan(promises, sessions)
        } else {
            XCTFail("Promises and FirebaseSessions must both be compile jobs")
        }
        XCTAssertTrue(build.compileJobs.contains { $0.tool == "swiftc" && $0.arguments.contains("-sdk") })
        XCTAssertTrue(build.linkJob.arguments.contains("-framework"))
        XCTAssertTrue(build.linkJob.arguments.contains("MapKit"))

        let tested = try driver.plan(project: project, target: "GuideAI", kind: .buildRunAndTests, tests: [], context: context)
        XCTAssertTrue(tested.preparesLaunch)
        XCTAssertTrue(tested.includesTests)
        XCTAssertFalse(tested.testSources.isEmpty)
    }

    func testGitPullChecksOutTheRequestedBranch() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("palm-git-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let origin = root.appendingPathComponent("origin")
        try FileManager.default.createDirectory(at: origin, withIntermediateDirectories: true)
        func git(_ args: [String], _ cwd: URL) throws {
            let result = try CommandRunner.run(executable: "/usr/bin/git", arguments: args, currentDirectory: cwd)
            XCTAssertEqual(result.status, 0, result.output)
        }
        try git(["init", "-b", "main"], origin)
        try git(["config", "user.email", "palm@example.com"], origin)
        try git(["config", "user.name", "Palm"], origin)
        try "one".write(to: origin.appendingPathComponent("marker.txt"), atomically: true, encoding: .utf8)
        try git(["add", "marker.txt"], origin)
        try git(["commit", "-m", "one"], origin)
        try git(["checkout", "-b", "feature"], origin)
        try "two".write(to: origin.appendingPathComponent("marker.txt"), atomically: true, encoding: .utf8)
        try git(["commit", "-am", "two"], origin)
        let checkout = root.appendingPathComponent("checkout")
        try GitPuller.pull(repository: origin.path, branch: "feature", into: checkout)
        let marker = try String(contentsOf: checkout.appendingPathComponent("marker.txt"), encoding: .utf8)
        XCTAssertEqual(marker, "two")
    }

    func testMissingSDKFrameworkStaysOnTheNyxianSlice() throws {
        let sdk = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("palm-sdk-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: sdk.appendingPathComponent("System/Library/Frameworks/UIKit.framework"), withIntermediateDirectories: true)
        XCTAssertTrue(SDKFrameworks.isPresent(named: "UIKit", sdkRoot: sdk))
        XCTAssertEqual(SDKFrameworks.missing(named: ["UIKit", "MapKit"], sdkRoot: sdk), ["MapKit"])
        let overlay = sdk.appendingPathComponent("overlay")
        let written = try SDKFrameworks.writeOverlays(for: ["MapKit"], sdkRoot: sdk, overlayRoot: overlay)
        XCTAssertTrue(written.isEmpty)
    }
}

private final class RecordingToolchain: DeviceToolchain {
    var calls: [String] = []
    var failCompile = false

    func pull(_ request: ControlRequest, log: ControlLog) throws { calls.append("pull") }
    func compile(_ plan: BuildPlan, log: ControlLog) throws {
        calls.append("compile")
        if failCompile { throw ControlError.compileFailed("compile failed") }
        log.append("swiftc \(plan.compileJobs.count) jobs")
    }
    func link(_ plan: BuildPlan, log: ControlLog) throws { calls.append("link") }
    func sign(_ plan: BuildPlan, log: ControlLog) throws { calls.append("sign") }
    func launch(_ plan: BuildPlan, log: ControlLog) throws -> RunningProcess {
        calls.append("launch")
        return RunningProcess(pid: 42, bundleIdentifier: plan.bundleIdentifier, executablePath: plan.linkJob.output)
    }
    func runTests(_ plan: BuildPlan, process: RunningProcess, names: [String], log: ControlLog) throws {
        calls.append("test")
        log.append("ran \(names.joined(separator: " ")) in \(process.pid)")
    }
}

private func fixtureRoot() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/SwiftUIUIKit")
}

private func makeContext() throws -> DriverContext {
    let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("palm-work-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return DriverContext(
        sdkRoot: root.appendingPathComponent("sdk"),
        swiftResourceDir: root.appendingPathComponent("swift"),
        moduleCache: root.appendingPathComponent("ModuleCache"),
        workRoot: root.appendingPathComponent("work")
    )
}

private func request(_ kind: ControlRequestKind, tests: [String] = [], ui: [UICheck] = []) -> ControlRequest {
    ControlRequest(
        kind: kind,
        branch: "main",
        project: "SwiftUIUIKit.xcodeproj",
        target: "SwiftUIUIKit",
        tests: tests,
        ui: ui
    )
}
