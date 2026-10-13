// SPDX-License-Identifier: AGPL-3.0-or-later

import Network
import XCTest
@testable import PalmControl

final class ControlTests: XCTestCase {
    func testDevelopmentProfileSkipsTheWildcardAndTheAppStoreProfile() {
        let profiles = [
            ProvisioningProfileSummary(name: "iOS Team Provisioning Profile: *", applicationIdentifier: "7834J3DHRB.*"),
            ProvisioningProfileSummary(name: "iOS Team Store Provisioning Profile: com.onexengineering.GuideAI", applicationIdentifier: "7834J3DHRB.com.onexengineering.GuideAI"),
            ProvisioningProfileSummary(name: "expired", applicationIdentifier: "7834J3DHRB.com.onexengineering.GuideAI", expires: Date(timeIntervalSince1970: 1)),
            ProvisioningProfileSummary(name: "iOS Team Provisioning Profile: com.onexengineering.GuideAI", applicationIdentifier: "7834J3DHRB.com.onexengineering.GuideAI", expires: Date(timeIntervalSinceNow: 86400)),
        ]
        let chosen = chooseDevelopmentProfile(bundleIdentifier: "com.onexengineering.GuideAI", profiles: profiles)
        XCTAssertEqual(chosen?.name, "iOS Team Provisioning Profile: com.onexengineering.GuideAI")
        XCTAssertEqual(
            teamCodesignArguments(identity: "Apple Development: Isaac Yeang (AT4W55YC44)", binary: "/tmp/GuideAI", entitlements: "/tmp/ent.plist"),
            ["-f", "-s", "Apple Development: Isaac Yeang (AT4W55YC44)", "--timestamp=none", "--generate-entitlement-der", "--entitlements", "/tmp/ent.plist", "/tmp/GuideAI"]
        )
    }

    func testCustomInfoPlistOverridesUsageStrings() {
        let merged = mergedDictionaries(
            ["CFBundleName": .string("GuideAI")],
            overlay: ["NSLocationWhenInUseUsageDescription": .string("Guide uses your location.")]
        )
        XCTAssertEqual(merged["NSLocationWhenInUseUsageDescription"], .string("Guide uses your location."))
        XCTAssertEqual(merged["CFBundleName"], .string("GuideAI"))
    }

    func testHealthKitRepairAddsThePreferredZoneMethod() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("palm-hk-\(UUID().uuidString)")
        let header = root.appendingPathComponent("System/Library/Frameworks/HealthKit.framework/Modules/HealthKit.swiftmodule/arm64e-apple-ios.swiftinterface")
        try? FileManager.default.createDirectory(at: header.deletingLastPathComponent(), withIntermediateDirectories: true)
        let existing = """
        extension HealthKit.HKWorkout {
          public var zoneGroupsByType: [HealthKit.HKQuantityType : HealthKit.HKWorkoutZoneGroup]? { get }
        }
        public struct HKWorkoutZone : Swift.Sendable {
          public let index: Swift.Int
        }

        """
        try? existing.write(to: header, atomically: true, encoding: .utf8)
        repairHealthKitWorkoutZones(sdkRoot: root)
        let updated = (try? String(contentsOf: header, encoding: .utf8)) ?? ""
        XCTAssertTrue(updated.contains("preferredWorkoutZoneConfiguration"))
        XCTAssertTrue(updated.contains("var minimum:"))
        XCTAssertEqual(updated.components(separatedBy: "struct HKWorkoutZone ").count, 2)
        try? FileManager.default.removeItem(at: root)
    }

    func testCompileCacheKeepsAnUnchangedObject() {
        let stamp = compileArgumentStamp(["swiftc", "-c", "/src/A.swift"])
        let older = Date(timeIntervalSince1970: 10)
        let newer = Date(timeIntervalSince1970: 20)
        XCTAssertTrue(compileOutputIsFresh(outputExists: true, outputDate: newer, inputDates: [older], savedStamp: stamp, argumentStamp: stamp))
        XCTAssertFalse(compileOutputIsFresh(outputExists: true, outputDate: older, inputDates: [newer], savedStamp: stamp, argumentStamp: stamp))
        XCTAssertFalse(compileOutputIsFresh(outputExists: true, outputDate: newer, inputDates: [older], savedStamp: "stale", argumentStamp: stamp))
        XCTAssertEqual(
            compileInputPaths(arguments: ["-c", "/src/A.swift", "-sdk", "/sdk"], declaredInputs: ["/src/B.swift"], output: "/tmp/A.o"),
            ["/src/B.swift", "/src/A.swift"]
        )
    }

    func testTemporaryObjectsRoundTripIntoTheDurableStore() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("palm-objects-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let temporary = root.appendingPathComponent("tmp")
        let store = root.appendingPathComponent("objects")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        let object = temporary.appendingPathComponent("App-62473e.o")
        try Data("object".utf8).write(to: object)
        try Data("stamp".utf8).write(to: temporary.appendingPathComponent("App-62473e.o.palmflags"))
        let past = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: object.path)
        XCTAssertTrue(outputLivesInTemporaryDirectory(object.path, temporaryDirectory: temporary.path))
        XCTAssertFalse(outputLivesInTemporaryDirectory(root.appendingPathComponent("Documents/Cache/Palm/GuideAI.o").path, temporaryDirectory: temporary.path))
        XCTAssertTrue(outputLivesInTemporaryDirectory(
            "/private/var/mobile/Containers/Data/Application/AEDC0392-19FC-4FBF-B721-BE5E764DABB7/tmp/App-62473e.o",
            temporaryDirectory: "/var/mobile/Containers/Data/Application/AEDC0392-19FC-4FBF-B721-BE5E764DABB7/tmp/"
        ))
        try persistTemporaryObject(object.path, temporaryDirectory: temporary.path, storeDirectory: store)
        try FileManager.default.removeItem(at: temporary)
        let restored = try restoreTemporaryObjects(from: store, to: temporary)
        XCTAssertEqual(restored, 1)
        let broughtBack = try Data(contentsOf: object)
        XCTAssertEqual(broughtBack, Data("object".utf8))
        let kept = try FileManager.default.attributesOfItem(atPath: object.path)[.modificationDate] as? Date
        XCTAssertEqual(kept?.timeIntervalSince1970 ?? 0, past.timeIntervalSince1970, accuracy: 1)
        XCTAssertEqual(try restoreTemporaryObjects(from: store, to: temporary), 0)
    }

    func testUnchangedRewriteLeavesModificationTime() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("palm-rewrite-\(UUID().uuidString).swift")
        defer { try? FileManager.default.removeItem(at: url) }
        let text = "import Foundation\nstruct S {\n    isolated deinit { }\n}\n"
        try writeIfChanged(text, to: url)
        let past = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: url.path)
        try writeIfChanged(text, to: url)
        let kept = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        XCTAssertEqual(kept?.timeIntervalSince1970 ?? 0, past.timeIntervalSince1970, accuracy: 0.001)
        try writeIfChanged(text + "let added = 1\n", to: url)
        let updated = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        XCTAssertGreaterThan(updated ?? past, past)
        let written = try Data(contentsOf: url)
        XCTAssertEqual(written, Data((text + "let added = 1\n").utf8))
    }

    func testContainerUUIDDoesNotChangeTheCompileStamp() {
        let oldID = "AEDC0392-19FC-4FBF-B721-BE5E764DABB7"
        let newID = "11111111-2222-4333-8444-555555555555"
        func path(_ id: String, _ rest: String) -> String {
            "/private/var/mobile/Containers/Data/Application/\(id)/\(rest)"
        }
        let oldArgs = [
            "-c", path(oldID, "Documents/Projects/ios/GuideAI/A.swift"),
            "-sdk", path(oldID, "Documents/SDK/iPhoneOS26.5.sdk"),
        ]
        let newArgs = [
            "-c", path(newID, "Documents/Projects/ios/GuideAI/A.swift"),
            "-sdk", path(newID, "Documents/SDK/iPhoneOS26.5.sdk"),
        ]
        XCTAssertEqual(compileArgumentStamp(oldArgs), compileArgumentStamp(newArgs))
        XCTAssertEqual(
            compileArgumentStamp(["/Containers/Data/Application/\(oldID)/Documents/A.swift"]),
            compileArgumentStamp(["/Containers/Data/Application/\(newID)/Documents/A.swift"])
        )
        XCTAssertNotEqual(
            compileArgumentStamp(oldArgs),
            compileArgumentStamp([
                "-c", path(oldID, "Documents/Projects/ios/GuideAI/B.swift"),
                "-sdk", path(oldID, "Documents/SDK/iPhoneOS26.5.sdk"),
            ])
        )
        XCTAssertNotEqual(compileArgumentStamp(oldArgs), compileArgumentStamp(oldArgs + ["-enable-testing"]))
        XCTAssertNotEqual(
            compileArgumentStamp(["HealthKit.swiftinterface=10"] + oldArgs),
            compileArgumentStamp(["HealthKit.swiftinterface=20"] + oldArgs)
        )
    }

    func testAVAudioSessionActivationMatchesTheIOS27SDK() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("palm-av-sdk-\(UUID().uuidString)")
        let header = root.appendingPathComponent("System/Library/Frameworks/AVFAudio.framework/Headers/AVAudioSession.h")
        try? FileManager.default.createDirectory(at: header.deletingLastPathComponent(), withIntermediateDirectories: true)
        let stale = "- (void)activateWithOptions:(AVAudioSessionActivationOptions)options completionHandler:(void (^)(BOOL activated, NSError * _Nullable error))handler API_AVAILABLE(watchos(5.0)) API_UNAVAILABLE(ios, tvos) API_UNAVAILABLE(macos, macCatalyst);\n"
        try? stale.write(to: header, atomically: true, encoding: .utf8)
        repairAVAudioSessionActivation(sdkRoot: root)
        let updated = (try? String(contentsOf: header, encoding: .utf8)) ?? ""
        XCTAssertTrue(updated.contains("API_AVAILABLE(ios(27.0), watchos(5.0), tvos(27.0), visionos(27.0))"))
        XCTAssertFalse(updated.contains("API_UNAVAILABLE(ios, tvos)"))
        try? FileManager.default.removeItem(at: root)
    }

    func testBinaryFrameworkKeepsItsOwnModuleMap() {
        let headers = [URL(fileURLWithPath: "/wrap/include/dummy.h")]
        XCTAssertFalse(shouldEmitPackageModuleMap(moduleName: "FirebaseAnalytics", headers: headers, binaryModules: ["FirebaseAnalytics"]))
        XCTAssertTrue(shouldEmitPackageModuleMap(moduleName: "FirebaseCrashlytics", headers: [URL(fileURLWithPath: "/Public/FIRCrashlytics.h")], binaryModules: ["FirebaseAnalytics"]))
    }

    func testIsolatedDeinitMarksTheWorkCopyAndLeavesOtherLines() {
        let source = """
        @MainActor
        final class Camera: UIViewController {
            deinit {
                remove()
            }
            nonisolated deinit {
            }
        }
        """
        let updated = isolateDeinits(source)
        XCTAssertTrue(updated.contains("isolated deinit {"))
        XCTAssertTrue(updated.contains("nonisolated deinit {"))
        XCTAssertFalse(updated.split(separator: "\n").contains { $0.trimmingCharacters(in: .whitespaces).hasPrefix("deinit") })
    }

    func testPreviewStripKeepsMembersMentionedBesideTheMacroName() {
        let source = """
        /// Stable default so `#Preview` does not mint a new UUID.
        static let idleSavedPlaceLocationsRevision = UUID()

        #Preview {
            Text("Hi")
        }
        """
        let stripped = stripPreviewBlocks(source)
        XCTAssertTrue(stripped.contains("/// Stable default so `#Preview` does not mint a new UUID."))
        XCTAssertTrue(stripped.contains("idleSavedPlaceLocationsRevision"))
        XCTAssertFalse(stripped.contains("Text(\"Hi\")"))
    }

    func testPreviewStripRemovesWidgetTimelineClosures() {
        let source = """
        struct SleepVitalsWidget {}
        #Preview("Sleep", as: .systemMedium) { SleepVitalsWidget() } timeline: {
            VitalsWidgetEntry(date: .now, vitals: .widgetPreview)
        }
        struct KeptAfterPreview {}
        """
        let stripped = stripPreviewBlocks(source)
        XCTAssertTrue(stripped.contains("struct SleepVitalsWidget {}"))
        XCTAssertTrue(stripped.contains("struct KeptAfterPreview {}"))
        XCTAssertFalse(stripped.contains("VitalsWidgetEntry"))
        XCTAssertFalse(stripped.contains("timeline:"))
        XCTAssertFalse(stripped.contains("#Preview"))
    }

    func testPreviewStripKeepsGuideAISourcesBalanced() throws {
        let root = URL(fileURLWithPath: "/Users/isaacyeang/src/GuideAI/ios/GuideAI")
        var seen = 0
        guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
            XCTFail("missing GuideAI sources")
            return
        }
        for case let url as URL in files {
            guard url.pathExtension == "swift" else { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            guard text.contains("#Preview") else { continue }
            seen += 1
            let stripped = stripPreviewBlocks(text)
            XCTAssertEqual(braceDepth(stripped), 0, url.lastPathComponent)
            for line in stripped.split(separator: "\n") where line.contains("#Preview") {
                XCTAssertTrue(line.contains("//"), "\(url.lastPathComponent): \(line)")
            }
        }
        XCTAssertGreaterThan(seen, 20)
    }

    func testGenerableExpansionMatchesFoundationModelsMacro() throws {
        let source = """
        import FoundationModels

        struct SampleTool {
            @Generable
            struct Arguments {
                @Guide(description: "day count", .range(1...10))
                let dayCount: Int
            }
        }

        @Generable
        struct SampleDate: Equatable {
            @Guide(description: "Four-digit year.", .range(1...4000))
            let year: Int
            @Guide(description: "Optional place")
            let place: String?
            func kept() -> Int { year }
        }
        """
        let expanded = expandGenerableMacros(source)
        XCTAssertFalse(expanded.contains("@Generable"))
        XCTAssertFalse(expanded.contains("@Guide"))
        XCTAssertTrue(expanded.contains("let dayCount: Int"))
        XCTAssertTrue(expanded.contains("let year: Int"))
        XCTAssertTrue(expanded.contains("func kept() -> Int { year }"))
        XCTAssertTrue(expanded.contains("extension SampleTool.Arguments: nonisolated FoundationModels.Generable"))
        XCTAssertTrue(expanded.contains("extension SampleDate: nonisolated FoundationModels.Generable"))
        XCTAssertTrue(expanded.contains("name: \"year\", description: \"Four-digit year.\", type: Int.self, guides: [.range(1...4000)]"))
        XCTAssertTrue(expanded.contains("name: \"place\", description: \"Optional place\", type: String?.self"))
        XCTAssertTrue(expanded.contains("var place: String?.PartiallyGenerated?"))
        XCTAssertTrue(expanded.contains("ConvertibleFromGeneratedContent, Equatable"))
        let sampleDate = try XCTUnwrap(expanded.range(of: "struct SampleDate"))
        XCTAssertFalse(expanded[..<sampleDate.lowerBound].contains("extension SampleTool"))
    }

    func testGenerableExpansionOfGuideAISourcesKeepsStoredPropertiesOnly() throws {
        let roots = [
            URL(fileURLWithPath: "/Users/isaacyeang/src/GuideAI/ios/GuideAI"),
            URL(fileURLWithPath: "/Users/isaacyeang/src/GuideAI/ios/GuideAIUnitTests"),
        ]
        var seen = 0
        for root in roots {
            guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
                XCTFail("GuideAI sources are missing")
                return
            }
            for case let url as URL in enumerator {
                guard url.pathExtension == "swift" else { continue }
                let source = try String(contentsOf: url, encoding: .utf8)
                guard source.contains("@Generable") else { continue }
                seen += 1
                let expanded = expandGenerableMacros(source)
                XCTAssertTrue(codeLines(expanded, containing: "@Generable").isEmpty, url.lastPathComponent)
                XCTAssertTrue(codeLines(expanded, containing: "@Guide").isEmpty, url.lastPathComponent)
                XCTAssertEqual(braceDepth(expanded), 0, url.lastPathComponent)
                if url.lastPathComponent == "GenerableDate.swift" {
                    XCTAssertFalse(expanded.contains("forProperty: \"coord\""))
                    XCTAssertTrue(expanded.contains("func fetchTimeZone"))
                    XCTAssertTrue(expanded.contains("forProperty: \"minute\""))
                }
            }
        }
        XCTAssertGreaterThan(seen, 4)
    }

    func testCompiledDataModelIsCopiedBesideTheExecutable() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("palm-model-\(UUID().uuidString)")
        let model = root.appendingPathComponent("GuideAI.xcdatamodeld")
        let compiled = root.appendingPathComponent("GuideAI.momd")
        try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: compiled, withIntermediateDirectories: true)
        try Data("model".utf8).write(to: compiled.appendingPathComponent("GuideAI.mom"))
        let found = ProjectDriver().compiledDataModels(under: root)
        XCTAssertEqual(
            found.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path },
            [compiled.resolvingSymlinksInPath().path]
        )
        let executable = root.appendingPathComponent("GuideAI.app/GuideAI").path
        let copied = try ProjectDriver().copyBundleResources(found, nextTo: executable)
        XCTAssertEqual(copied, ["GuideAI.momd"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("GuideAI.app/GuideAI.momd/GuideAI.mom").path))
    }

    func testSwiftJobsRecordTheObjectPathAfterTheOutputFlag() {
        XCTAssertEqual(
            emittedObjectPath(arguments: ["-frontend", "-c", "-o", "/tmp/A-111.o", "A.swift"], outputFilePath: nil),
            "/tmp/A-111.o"
        )
        XCTAssertEqual(
            emittedObjectPath(arguments: ["-o", "/tmp/App"], outputFilePath: nil),
            nil
        )
        XCTAssertEqual(
            emittedObjectPath(arguments: ["-o", "/tmp/ignored.o"], outputFilePath: "/tmp/Cache/Foo-0.o"),
            "/tmp/Cache/Foo-0.o"
        )
    }

    func testLinkUsesEmittedObjectsInsteadOfTheUnwrittenModuleObject() {
        let objects = objectFilesToLink(
            compiled: ["/tmp/A-111.o", "/tmp/Cache/Foo-0.o"],
            planned: ["/tmp/Cache/Lottie.o", "/tmp/Cache/Foo-0.o"],
            alreadyLinked: ["/tmp/App-1.o"],
            fileExists: { $0 == "/tmp/Cache/Foo-0.o" }
        )
        XCTAssertEqual(objects, ["/tmp/A-111.o", "/tmp/Cache/Foo-0.o"])
    }

    func testLaunchBundlesAVendorFrameworkAndSkipsTheSDK() {
        let sdk = "/var/SDK/iPhoneOS26.5.sdk"
        let vendor = "/var/Projects/ios/Vendor/LiteRT-LM/CLiteRTLM.xcframework/ios-arm64"
        let bundled = frameworksToBundle(
            arguments: [
                "-F", sdk + "/System/Library/Frameworks",
                "-framework", "UIKit",
                "-F", vendor,
                "-framework", "CLiteRTLM",
                "-framework", "FirebaseAnalytics",
                "-framework", "MissingKit",
            ],
            sdkRoot: sdk,
            fileExists: {
                $0 == vendor + "/CLiteRTLM.framework" || $0 == vendor + "/FirebaseAnalytics.framework"
            },
            isDynamicLibrary: { $0.hasSuffix("/CLiteRTLM") }
        )
        XCTAssertEqual(bundled, [vendor + "/CLiteRTLM.framework"])
    }

    func testLinkKeepsOneCopyOfARepeatedDriverObject() {
        let arguments = [
            "/tmp/EncodedRolloutAssignment-67928c.o",
            "/tmp/EncodedRolloutAssignment-f9c4ca.o",
            "/tmp/Other-abcdef.o",
            "-o", "/tmp/GuideAI",
        ]
        XCTAssertEqual(
            dedupingRepeatedObjects(arguments),
            ["/tmp/EncodedRolloutAssignment-67928c.o", "/tmp/Other-abcdef.o", "-o", "/tmp/GuideAI"]
        )
    }

    func testLinkLooksUpIOS27SymbolsAndSkipsAMissingRuntimeArchive() {
        let prepared = preparingLinkArguments(
            ["-syslibroot", "/private/var/mobile/Documents/SDK/iPhoneOS26.5.sdk", "-o", "/tmp/GuideAI"],
            runtimeLibraryExists: false
        )
        XCTAssertFalse(prepared.contains("-lclang_rt.ios"))
        XCTAssertEqual(prepared.suffix(3), ["-adhoc_codesign", "-undefined", "dynamic_lookup"])
    }

    func testLinkerDropsFrameworksThatAreNotOnDisk() {
        let arguments = [
            "-F", "/sdk/Frameworks",
            "-framework", "UIKit",
            "-framework", "AppKit",
            "-framework", "EmojiKit",
            "-o", "/tmp/GuideAI",
        ]
        let kept = droppingMissingFrameworks(arguments) { path in
            path == "/sdk/Frameworks/UIKit.framework"
        }
        XCTAssertEqual(kept, ["-F", "/sdk/Frameworks", "-framework", "UIKit", "-o", "/tmp/GuideAI"])
    }

    func testLargeLinkUsesOneResponseFileArgument() {
        let small = (0..<63).map { "-L\($0)" }
        XCTAssertEqual(linkerInvocation(arguments: small, responseFile: "/tmp/link.rsp"), small)
        let large = (0..<64).map { "-framework\($0)" }
        XCTAssertEqual(
            linkerInvocation(arguments: large, responseFile: "/tmp/link.rsp"),
            ["@/tmp/link.rsp"]
        )
    }

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
        let tested = executor.run(request(.buildRunAndTests, ui: [UICheck(name: "home", action: "snapshot")]))
        XCTAssertEqual(tested.stagesRun, [.pull, .compile, .link, .sign, .launch])
        XCTAssertTrue(tested.launched)
        XCTAssertFalse(recording.calls.contains("test"))
        XCTAssertFalse(tested.logs.contains("SampleTests.swift"))
    }

    func testBuildRunAndTestsDoesNotCompileAnOnDeviceTestBinary() throws {
        let recording = RecordingToolchain()
        let executor = ControlExecutor(toolchain: recording, sourceRoot: fixtureRoot(), context: try makeContext())
        let tested = executor.run(request(
            .buildRunAndTests,
            ui: [UICheck(name: "Welcome to GuideAI", action: "wait")]
        ))
        XCTAssertTrue(tested.success)
        XCTAssertTrue(tested.launched)
        XCTAssertEqual(tested.stagesRun, [.pull, .compile, .link, .sign, .launch])
        XCTAssertFalse(recording.calls.contains("test"))
        XCTAssertFalse(tested.logs.contains("SampleTests.swift"))
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

    func testClientIgnoresAKeepaliveAndReadsTheResult() throws {
        let listener = try NWListener(using: .tcp, on: .any)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
        }
        let accepted = DispatchSemaphore(value: 0)
        var incoming: NWConnection?
        listener.newConnectionHandler = { connection in
            incoming = connection
            connection.start(queue: .global())
            accepted.signal()
        }
        listener.start(queue: .global())
        ready.wait()
        defer {
            listener.cancel()
            incoming?.cancel()
        }
        let port = try XCTUnwrap(listener.port).rawValue
        let finished = DispatchSemaphore(value: 0)
        var response: ControlResponse?
        var clientError: Error?
        DispatchQueue.global().async {
            do {
                response = try ControlClient.send(request(.build), host: "127.0.0.1", port: port)
            } catch {
                clientError = error
            }
            finished.signal()
        }
        XCTAssertEqual(accepted.wait(timeout: .now() + 5), .success)
        let result = ControlResponse(
            success: true,
            kind: .build,
            stagesRun: [.sign],
            failedStage: nil,
            logs: "signed\n",
            launched: false,
            process: nil
        )
        var message = Data("{\"op\":\"ping\",\"bytes\":\"\"}\n".utf8)
        message.append(try JSONEncoder().encode(result))
        message.append(0x0A)
        let sent = DispatchSemaphore(value: 0)
        try XCTUnwrap(incoming).send(content: message, completion: .contentProcessed { _ in
            sent.signal()
        })
        XCTAssertEqual(sent.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(finished.wait(timeout: .now() + 5), .success)
        XCTAssertNil(clientError)
        XCTAssertEqual(response?.success, true)
        XCTAssertEqual(response?.logs, "signed\n")
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
        XCTAssertTrue(tested.launched)
        XCTAssertFalse(tested.stagesRun.contains(.test))
        let agent = MacAgent { process, _ in
            XCTAssertEqual(process.pid, 42)
            return "ui snapshot home\n"
        }
        let finished = agent.finish(tested, request: request(.buildRunAndTests, ui: [UICheck(name: "home", action: "snapshot")]))
        XCTAssertTrue(finished.logs.contains("ui snapshot home"))
        let buildAgain = agent.finish(build, request: request(.build, ui: [UICheck(name: "home", action: "snapshot")]))
        XCTAssertFalse(buildAgain.logs.contains("ui snapshot home"))
    }

    func testAgentDeviceRunnerOpensTheLaunchedAppAndChecksIt() throws {
        let previousCommand = AgentDeviceRunner.command
        let previousDevice = AgentDeviceRunner.deviceUDID
        let previousHost = AgentDeviceRunner.hostBundleIdentifier
        defer {
            AgentDeviceRunner.command = previousCommand
            AgentDeviceRunner.deviceUDID = previousDevice
            AgentDeviceRunner.hostBundleIdentifier = previousHost
        }
        var calls: [[String]] = []
        AgentDeviceRunner.deviceUDID = "00008150-000A70980EA0C01C"
        AgentDeviceRunner.hostBundleIdentifier = nil
        AgentDeviceRunner.command = { arguments in
            calls.append(arguments)
            return (0, "ran \(arguments[0])\n")
        }
        let process = RunningProcess(pid: 42, bundleIdentifier: "com.onexengineering.GuideAI", executablePath: "/tmp/GuideAI")
        let log = try AgentDeviceRunner.run(process: process, checks: [UICheck(name: "home", action: "snapshot")])
        XCTAssertEqual(calls, [
            ["open", "com.onexengineering.GuideAI", "--foreground", "--platform", "ios", "--udid", "00008150-000A70980EA0C01C"],
            ["snapshot", "-i", "--scope", "home", "--platform", "ios", "--udid", "00008150-000A70980EA0C01C"],
        ])
        XCTAssertFalse(calls[0].contains("--relaunch"))
        XCTAssertTrue(log.contains("ran open"))
        XCTAssertTrue(log.contains("ran snapshot"))

        calls.removeAll()
        AgentDeviceRunner.hostBundleIdentifier = "com.onexengineering.PalmHost"
        _ = try AgentDeviceRunner.run(process: process, checks: [UICheck(name: "Welcome to GuideAI", action: "wait")])
        XCTAssertEqual(calls[0], ["open", "com.onexengineering.PalmHost", "--foreground", "--platform", "ios", "--udid", "00008150-000A70980EA0C01C"])
        XCTAssertEqual(calls[1], ["wait", "text", "Welcome to GuideAI", "--platform", "ios", "--udid", "00008150-000A70980EA0C01C"])
    }

    func testGuideAIPlanExposesFrameworksAndStopsBeforeLaunch() throws {
        let project = URL(fileURLWithPath: "/Users/isaacyeang/src/GuideAI/ios/GuideAI.xcodeproj")
        XCTAssertTrue(FileManager.default.fileExists(atPath: project.path))
        let context = try makeContext()
        let cross = context.sdkRoot.appendingPathComponent("System/Library/Frameworks/MapKit.framework/Modules/MapKit.swiftcrossimport")
        try FileManager.default.createDirectory(at: cross, withIntermediateDirectories: true)
        try """
        ---
        version: 1
        modules:
          - name: _MapKit_SwiftUI
        """.write(to: cross.appendingPathComponent("SwiftUI.swiftoverlay"), atomically: true, encoding: .utf8)
        let interfaceDirectory = context.sdkRoot.appendingPathComponent("System/Library/Frameworks/_MapKit_SwiftUI.framework/Modules/_MapKit_SwiftUI.swiftmodule")
        try FileManager.default.createDirectory(at: interfaceDirectory, withIntermediateDirectories: true)
        let mapInterface = interfaceDirectory.appendingPathComponent("arm64e-apple-ios.swiftinterface")
        try "public struct MapFeature {}\n".write(to: mapInterface, atomically: true, encoding: .utf8)
        let transcriptDirectory = context.sdkRoot.appendingPathComponent("System/Library/Frameworks/FoundationModels.framework/Modules/FoundationModels.swiftmodule")
        try FileManager.default.createDirectory(at: transcriptDirectory, withIntermediateDirectories: true)
        let transcriptInterface = transcriptDirectory.appendingPathComponent("arm64e-apple-ios.swiftinterface")
        try """
        public struct Transcript {
          public enum Entry {
            case response(FoundationModels.Transcript.Response)
          }
          public static func == (a: FoundationModels.Transcript, b: FoundationModels.Transcript) -> Swift.Bool
        }
        """.write(to: transcriptInterface, atomically: true, encoding: .utf8)
        let driver = ProjectDriver()
        let build = try driver.plan(project: project, target: "GuideAI", kind: .build, context: context)
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
        XCTAssertEqual(
            build.infoPlist["NSHealthShareUsageDescription"],
            .string("GuideAI shows the health information you choose to share, including activity, sleep, nutrition, mood, medications, and measurements.")
        )
        XCTAssertEqual(
            build.infoPlist["NSLocationWhenInUseUsageDescription"],
            .string("Guide uses your location to suggest nearby destinations")
        )
        XCTAssertFalse(plistText(build.infoPlist).contains("$(PRODUCT_MODULE_NAME)"))
        XCTAssertTrue(plistText(build.infoPlist).contains("GuideAI.CarPlaySceneDelegate"))
        XCTAssertTrue(build.localPackages.contains("GuideAIMobilityCore"))
        XCTAssertTrue(build.localPackages.contains("Toasts"))
        XCTAssertTrue(build.localPackages.contains("WindowOverlay"))
        XCTAssertTrue(build.localPackages.contains("Lottie"))
        XCTAssertTrue(build.localPackages.contains("EmojiKit"))
        XCTAssertTrue(build.localPackages.contains("SFSymbols"))
        XCTAssertTrue(build.localPackages.contains("FirebaseCore"))
        XCTAssertTrue(build.localPackages.contains("FirebaseCrashlytics"))
        XCTAssertTrue(build.localPackages.contains("GoogleUtilities-Environment"))
        XCTAssertTrue(build.localPackages.contains("GoogleUtilities-Network"))
        XCTAssertTrue(build.localPackages.contains("GoogleUtilities-Reachability"))
        XCTAssertTrue(build.localPackages.contains("nanopb"))
        XCTAssertTrue(build.localPackages.contains("FBLPromises"))
        XCTAssertTrue(build.compileJobs.contains { job in
            job.tool == "clang" && job.sources.contains { $0.contains("FirebaseCore/Sources") } && job.arguments.contains("Firebase_VERSION=12.11.0")
        })
        XCTAssertTrue(build.compileJobs.contains { $0.arguments.contains { $0.contains("CLiteRTLM.xcframework/ios-arm64") } })
        XCTAssertTrue(build.linkJob.arguments.contains { $0.contains("FirebaseAnalytics.xcframework/ios-arm64") })
        XCTAssertTrue(build.linkJob.arguments.contains("-lsqlite3"))
        XCTAssertTrue(build.linkJob.arguments.contains("-lc++"))
        XCTAssertTrue(build.linkJob.arguments.contains("-lz"))
        XCTAssertTrue(build.linkJob.arguments.contains("StoreKit"))
        let guideLinkArguments = build.compileJobs.first { $0.moduleName == "GuideAI" }?.arguments ?? []
        XCTAssertTrue(guideLinkArguments.contains("-lsqlite3"))
        XCTAssertTrue(guideLinkArguments.contains("StoreKit"))
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
        XCTAssertEqual(swiftLanguageMode(build.compileJobs.first { $0.sources.contains { $0.contains("ExperimentalFlags.swift") } }), "5")
        XCTAssertEqual(swiftLanguageMode(build.compileJobs.first { $0.moduleName == "Toasts" }), "6")
        let policy = build.compileJobs.first { $0.moduleName == "GuideAI" }?.sources.first { $0.contains("CatalogSavedPlaceMapOverlayPolicy") }
        let policyText = try String(contentsOfFile: try XCTUnwrap(policy))
        XCTAssertTrue(policyText.contains("enum CatalogSavedPlaceMapOverlayPolicy"))
        XCTAssertTrue(policyText.contains("dedicatedMarkerCategoryIDs"))
        XCTAssertTrue(policyText.contains("idleSavedPlaceLocationsRevision"))
        let generable = build.compileJobs.first { $0.moduleName == "GuideAI" }?.sources.first { $0.contains("GenerableDate") }
        let generableText = try String(contentsOfFile: try XCTUnwrap(generable))
        XCTAssertFalse(generableText.contains("@Generable"))
        XCTAssertFalse(generableText.contains("@Guide"))
        XCTAssertTrue(generableText.contains("let year: Int"))
        XCTAssertTrue(generableText.contains("extension GenerableDate: nonisolated FoundationModels.Generable"))
        XCTAssertTrue(generableText.contains("description: \"Four-digit Gregorian year. Example: 2025. Use the user's intended year.\""))
        let guideArguments = build.compileJobs.first { $0.moduleName == "GuideAI" }?.arguments ?? []
        XCTAssertTrue(guideArguments.contains("-default-isolation"))
        XCTAssertTrue(guideArguments.contains("MainActor"))
        XCTAssertTrue(guideArguments.contains("MemberImportVisibility"))
        XCTAssertTrue(guideArguments.contains("IsolatedDeinit"))
        XCTAssertTrue(guideArguments.contains { $0.hasSuffix("host/libSwiftInProcPluginServer.dylib") })
        XCTAssertTrue(guideArguments.contains { $0.hasSuffix("host/plugins") })
        XCTAssertTrue(build.compileJobs.contains { job in
            job.moduleName == "Lottie" && job.sources.contains { $0.hasSuffix("EpoxyCore/Views/ViewType.swift") }
        })
        XCTAssertTrue(build.compileJobs.contains { job in
            job.moduleName == "Lottie" && job.sources.contains { $0.hasSuffix("ZipFoundation/Archive.swift") }
        })
        XCTAssertTrue(build.compileJobs.contains { job in
            job.moduleName == "Lottie" && job.sources.contains { $0.hasSuffix("EpoxyCore/Model/EpoxyModeled.swift") }
        })
        let navigation = build.compileJobs.first { $0.moduleName == "GuideAI" }?.sources.first { $0.contains("NavigationState") }
        XCTAssertTrue(navigation?.contains("CrossImports") == true)
        let navigationText = try String(contentsOfFile: try XCTUnwrap(navigation))
        XCTAssertTrue(navigationText.hasPrefix("import _MapKit_SwiftUI\n"))
        let firstRun = build.compileJobs.first { $0.moduleName == "GuideAI" }?.sources.first { $0.contains("FirstRunSetupView") }
        XCTAssertTrue(firstRun?.contains("BindingSetters") == true)
        let firstRunText = try String(contentsOfFile: try XCTUnwrap(firstRun))
        XCTAssertTrue(firstRunText.contains("set: { applyPagerSelectionFromSwipe($0) }"))
        XCTAssertFalse(firstRunText.contains("set: applyPagerSelectionFromSwipe\n"))
        XCTAssertTrue(build.compileJobs.contains { job in
            job.moduleName == "GuideAI" && job.sources.contains { $0.hasSuffix("HealthLungCycleArtwork.swift") }
        })
        let mapUtilities = build.compileJobs.first { $0.moduleName == "GuideAI" }?.sources.first { $0.contains("MapUtilities") }
        XCTAssertTrue(mapUtilities?.contains("CrossImports") == true)
        let mapUtilitiesText = try String(contentsOfFile: try XCTUnwrap(mapUtilities))
        XCTAssertTrue(mapUtilitiesText.hasPrefix("import _MapKit_SwiftUI\n"))
        let charts = build.compileJobs.first { $0.moduleName == "GuideAI" }?.sources.first { $0.contains("WeatherChartsView") }
        XCTAssertTrue(charts?.contains("EntryExpanded") == true)
        let chartsText = try String(contentsOfFile: try XCTUnwrap(charts))
        XCTAssertFalse(chartsText.contains("@Entry"))
        XCTAssertTrue(chartsText.contains("struct __Key_weatherChartEmbedded: EnvironmentKey"))
        XCTAssertTrue(chartsText.contains("struct __Key_weatherChartPlotHeight: EnvironmentKey"))
        XCTAssertEqual(braceDepth(chartsText), 0)
        let repairedInterface = try String(contentsOf: mapInterface, encoding: .utf8)
        XCTAssertTrue(repairedInterface.contains("public struct MapCamera :"))
        XCTAssertTrue(repairedInterface.contains("public struct MapCameraPosition :"))
        let repairedTranscript = try String(contentsOf: transcriptInterface, encoding: .utf8)
        XCTAssertTrue(repairedTranscript.contains("case reasoning(FoundationModels.Transcript.Reasoning)"))
        XCTAssertTrue(repairedTranscript.contains("public struct Reasoning :"))
        XCTAssertTrue(build.compileJobs.contains { $0.tool == "swiftc" && $0.arguments.contains("1000000") })
        let moduleOrder = build.compileJobs.map(\.moduleName)
        if let promises = moduleOrder.firstIndex(of: "Promises"), let sessions = moduleOrder.firstIndex(of: "FirebaseSessions") {
            XCTAssertLessThan(promises, sessions)
        } else {
            XCTFail("Promises and FirebaseSessions must both be compile jobs")
        }
        XCTAssertTrue(build.compileJobs.contains { $0.tool == "swiftc" && $0.arguments.contains("-sdk") })
        XCTAssertTrue(build.linkJob.arguments.contains("-framework"))
        XCTAssertTrue(build.linkJob.arguments.contains("MapKit"))

        let tested = try driver.plan(project: project, target: "GuideAI", kind: .buildRunAndTests, context: context)
        XCTAssertTrue(tested.preparesLaunch)
        XCTAssertFalse(tested.includesTests)
        XCTAssertTrue(tested.testSources.isEmpty)
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

private func swiftLanguageMode(_ job: CompilerJob?) -> String? {
    guard let job, let index = job.arguments.firstIndex(of: "-swift-version"), index + 1 < job.arguments.count else { return nil }
    return job.arguments[index + 1]
}

private func codeLines(_ text: String, containing token: String) -> [String] {
    text.split(separator: "\n").compactMap { line in
        guard let range = line.range(of: token) else { return nil }
        if line[..<range.lowerBound].contains("//") { return nil }
        return String(line)
    }
}

private func plistText(_ value: [String: PlistValue]) -> String {
    func walk(_ item: PlistValue) -> String {
        switch item {
        case .string(let text):
            return text
        case .array(let values):
            return values.map(walk).joined(separator: " ")
        case .dictionary(let values):
            return values.values.map(walk).joined(separator: " ")
        default:
            return ""
        }
    }
    return value.values.map(walk).joined(separator: " ")
}

private func braceDepth(_ text: String) -> Int {
    var depth = 0
    var index = text.startIndex
    while index < text.endIndex {
        if text[index] == "/" && text.index(after: index) < text.endIndex && text[text.index(after: index)] == "/" {
            index = text[index...].firstIndex(of: "\n") ?? text.endIndex
            continue
        }
        if text[index] == "\"" {
            index = text.index(after: index)
            while index < text.endIndex && text[index] != "\"" && text[index] != "\n" {
                if text[index] == "\\" { index = text.index(after: index) }
                if index < text.endIndex { index = text.index(after: index) }
            }
            if index < text.endIndex { index = text.index(after: index) }
            continue
        }
        if text[index] == "{" { depth += 1 }
        if text[index] == "}" { depth -= 1 }
        index = text.index(after: index)
    }
    return depth
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
