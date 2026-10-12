// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import MobileDevelopmentKit

/// On-device toolchain. Compile and link go through MobileDevelopmentKit,
/// which is Nyxian's open swiftc/clang driver. Sign uses the existing
/// NXT2 signer. Launch uses the existing process manager when it is loaded.
final class NyxianToolchain: DeviceToolchain {
    private var linkJobs: [MDKJob] = []
    private var compiledObjects: [String] = []

    func pull(_ request: ControlRequest, log: ControlLog) throws {}

    /// CoreCompiler names its driver "swiftc", so generated jobs look for
    /// `lib/swift/host` relative to that name. Point those flags at Documents/swift.
    private func withAbsolutePlugins(_ arguments: [String], home: URL) -> [String] {
        let host = home.appendingPathComponent("Documents/swift/host")
        let server = host.appendingPathComponent("libSwiftInProcPluginServer.dylib").path
        let plugins = host.appendingPathComponent("plugins").path
        var rewritten: [String] = []
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "-in-process-plugin-server-path", index + 1 < arguments.count {
                rewritten.append(argument)
                rewritten.append(server)
                index += 2
                continue
            }
            if argument == "-plugin-path", index + 1 < arguments.count {
                rewritten.append(argument)
                let next = arguments[index + 1]
                rewritten.append(next.hasPrefix("/") ? next : plugins)
                index += 2
                continue
            }
            rewritten.append(argument)
            index += 1
        }
        return rewritten
    }

    func compile(_ plan: BuildPlan, log: ControlLog) throws {
        let home = URL(fileURLWithPath: "/private" + NSHomeDirectory())
        let files = FileManager.default
        try? files.removeItem(at: home.appendingPathComponent("Documents/ModuleCache"))
        let temporary = home.appendingPathComponent("tmp")
        if let names = try? files.contentsOfDirectory(atPath: temporary.path) {
            for name in names where name.hasSuffix(".o") || name.hasPrefix("supplementaryOutputs") {
                try? files.removeItem(at: temporary.appendingPathComponent(name))
            }
        }
        linkJobs.removeAll()
        compiledObjects.removeAll()
        let output = URL(fileURLWithPath: plan.linkJob.output)
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        for job in plan.compileJobs {
            let type: MDKDriverType = job.tool == "swiftc" ? .swift : .clang
            guard let driver = MDKDriver(arguments: job.arguments, with: type) else {
                throw ControlError.compileFailed("driver rejected \(job.moduleName)")
            }
            guard let jobs = driver.generateJobs() else {
                throw ControlError.compileFailed("no jobs for \(job.moduleName)")
            }
            log.append("jobs \(jobs.count) for \(job.moduleName)")
            for item in jobs {
                if item.type == .linker || item.type == .driver || item.type == .swiftDriver {
                    linkJobs.append(item)
                    log.append("deferred \(item.type.rawValue) \(item.arguments.joined(separator: " "))")
                    continue
                }
                let absolute = withAbsolutePlugins(item.baseArguments, home: home)
                let runnable = PalmJob(item.type, absolute, item.inputFileURLs, item.outputFileURL) ?? item
                log.append("run \(runnable.type.rawValue) \(runnable.arguments.joined(separator: " "))")
                let primary = frontendPrimary(runnable.arguments)
                NSLog("palm run %@ %@ %@", "\(runnable.type.rawValue)", job.moduleName, primary)
                try execute(runnable, log: log, stage: "compile")
                if let path = emittedObjectPath(arguments: runnable.arguments, outputFilePath: runnable.outputFileURL?.path) {
                    compiledObjects.append(path)
                }
            }
        }
    }

    func link(_ plan: BuildPlan, log: ControlLog) throws {
        let jobs = try resolveLinkJobs(linkJobs, log: log)
        if jobs.isEmpty {
            throw ControlError.linkFailed("compiler driver emitted no linker job for \(plan.linkJob.output)")
        }
        let alreadyLinked = Set((linkJobs + jobs).flatMap(\.arguments).filter { $0.hasSuffix(".o") })
        let objects = objectFilesToLink(
            compiled: compiledObjects,
            planned: plan.linkJob.arguments,
            alreadyLinked: alreadyLinked,
            fileExists: { FileManager.default.fileExists(atPath: $0) }
        )
        log.append("link objects \(objects.count)")
        for item in jobs {
            let linked = item.type == .linker ? (PalmLinkerJob(item.arguments + objects) ?? item) : item
            log.append("link job \(linked.type.rawValue) \(linked.arguments.joined(separator: " "))")
            try execute(linked, log: log, stage: "link")
        }
        guard FileManager.default.fileExists(atPath: plan.linkJob.output) else {
            throw ControlError.linkFailed("linker produced no \(plan.linkJob.output)")
        }
        log.append("linked \(plan.linkJob.output)")
        let copied = try ProjectDriver().copyBundleResources(plan.bundleResources, nextTo: plan.linkJob.output)
        if !copied.isEmpty {
            log.append("bundle resources \(copied.joined(separator: " "))")
        }
    }

    /// Swift's legacy driver emits a clang driver job for the link. Nyxian's
    /// phase engine runs that job back through the clang driver to get lld.
    private func resolveLinkJobs(_ jobs: [MDKJob], log: ControlLog) throws -> [MDKJob] {
        var resolved: [MDKJob] = []
        for item in jobs {
            if item.type != .driver {
                resolved.append(item)
                continue
            }
            guard let driver = MDKDriver(arguments: item.arguments, with: .clang),
                  let generated = driver.generateJobs() else {
                throw ControlError.linkFailed("clang driver rejected the link job")
            }
            log.append("clang driver jobs \(generated.count)")
            for generatedJob in generated where generatedJob.type != .driver {
                resolved.append(linkerJob(expanding: generatedJob))
            }
            let nested = generated.filter { $0.type == .driver }
            if !nested.isEmpty {
                resolved.append(contentsOf: try resolveLinkJobs(nested, log: log))
            }
        }
        return resolved
    }

    /// lld receives the linker command itself. Drop clang's `-fuse-ld` and
    /// split the collapsed `-Wl,` list the swift driver produced.
    private func linkerJob(expanding job: MDKJob) -> MDKJob {
        guard job.type == .linker else { return job }
        var arguments: [String] = []
        for argument in job.arguments {
            if argument == "-fuse-ld=lld" || argument == "-fuse-ld=ld64.lld" {
                continue
            }
            if argument.hasPrefix("-Wl,") {
                arguments.append(contentsOf: argument.dropFirst(4).split(separator: ",").map(String.init))
                continue
            }
            arguments.append(argument)
        }
        if let sdkFlag = arguments.firstIndex(of: "-syslibroot"), sdkFlag + 1 < arguments.count {
            let documents = URL(fileURLWithPath: arguments[sdkFlag + 1])
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            arguments.append("-L")
            arguments.append(documents.appendingPathComponent("lib").path)
            arguments.append("-lclang_rt.ios")
            arguments.append("-adhoc_codesign")
        }
        return PalmLinkerJob(arguments) ?? job
    }

    func sign(_ plan: BuildPlan, log: ControlLog) throws {
        try signFile(plan.linkJob.output, plan: plan, log: log)
        if let testExecutable = plan.testExecutable {
            try signFile(testExecutable, plan: plan, log: log)
        }
    }

    func launch(_ plan: BuildPlan, log: ControlLog) throws -> RunningProcess {
        var error: NSString?
        let bundleURL = URL(fileURLWithPath: plan.linkJob.output).deletingLastPathComponent()
        try writeBundleInfo(plan, bundle: bundleURL)
        let bundle = bundleURL.path
        let pid = PalmLaunchBundle(plan.bundleIdentifier, bundle, &error)
        if pid <= 0 {
            throw ControlError.launchFailed((error as String?) ?? "launch failed")
        }
        log.append("launched \(plan.bundleIdentifier) pid \(pid)")
        return RunningProcess(pid: pid, bundleIdentifier: plan.bundleIdentifier, executablePath: plan.linkJob.output)
    }

    func runTests(_ plan: BuildPlan, process: RunningProcess, names: [String], log: ControlLog) throws {
        guard let executable = plan.testExecutable else {
            if !names.isEmpty {
                throw ControlError.testFailed("no test binary for \(names.joined(separator: " "))")
            }
            log.append("no tests named")
            return
        }
        let result = try CommandRunner.run(executable: executable, arguments: names, currentDirectory: nil)
        log.append(result.output)
        log.append("tests in pid \(process.pid) status \(result.status)")
        guard result.status == 0 else {
            throw ControlError.testFailed(result.output.isEmpty ? "tests failed" : result.output)
        }
    }

    private func writeBundleInfo(_ plan: BuildPlan, bundle: URL) throws {
        let name = bundle.deletingPathExtension().lastPathComponent
        var info: [String: Any] = [
            "CFBundleIdentifier": plan.bundleIdentifier,
            "CFBundleExecutable": name,
            "CFBundleName": name,
            "CFBundlePackageType": "APPL",
            "CFBundleInfoDictionaryVersion": "6.0",
            "CFBundleShortVersionString": "1.0",
            "CFBundleVersion": "1",
            "MinimumOSVersion": "18.0",
            "UIApplicationSceneManifest": [
                "UIApplicationSupportsMultipleScenes": false,
            ],
        ]
        for (key, value) in plan.infoPlist {
            info[key] = value.propertyListObject
        }
        info["CFBundleIdentifier"] = plan.bundleIdentifier
        info["CFBundleExecutable"] = name
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: bundle.appendingPathComponent("Info.plist"))
    }

    private func signFile(_ path: String, plan: BuildPlan, log: ControlLog) throws {
        let dictionary = NSMutableDictionary()
        for (key, value) in plan.entitlements {
            dictionary[key] = value.propertyListObject
        }
        if plan.preparesLaunch {
            guard PalmPatchExecutableForDlopen(path) else {
                throw ControlError.signFailed("could not convert \(path) into a loadable image")
            }
            let url = URL(fileURLWithPath: path)
            let signed = try TeamSigner.request(Data(contentsOf: url))
            try signed.write(to: url)
            log.append("team signed \(path)")
        }
        let status = trust_nxt2_sign(path, dictionary, plan.preparesLaunch, nil)
        guard status == KERN_SUCCESS else {
            throw ControlError.signFailed("sign failed (\(status)) for \(path)")
        }
        log.append("signed \(path)")
    }

    private func frontendPrimary(_ arguments: [String]) -> String {
        for flag in ["-primary-file", "-o"] {
            if let index = arguments.firstIndex(of: flag), index + 1 < arguments.count {
                return (arguments[index + 1] as NSString).lastPathComponent
            }
        }
        return ""
    }

    private func execute(_ job: MDKJob, log: ControlLog, stage: String) throws {
        var diagnostics: NSArray?
        var mainSource: NSString?
        let ok = job.execute(withOutDiagnostics: &diagnostics, withOutMainSource: &mainSource)
        if let diagnostics {
            log.append("diagnostics \(diagnostics)")
        }
        let items = (diagnostics as? [MDKDiagnostic]) ?? []
        for item in items {
            log.append("\(mainSource ?? ""): \(item.message ?? "")")
        }
        if !ok {
            let message = items.map { $0.message ?? "" }.joined(separator: "\n")
            if stage == "link" {
                throw ControlError.linkFailed(message.isEmpty ? "link failed" : message)
            }
            throw ControlError.compileFailed(message.isEmpty ? "compile failed" : message)
        }
    }
}

final class PalmControlHost {
    static let shared = PalmControlHost()
    private var server: ControlServer?
    private let port: UInt16 = 8741

    /// Load the in-process plugin server on the main thread before any compile.
    /// The compiler calls it from a background queue, and the first call deadlocks
    /// unless this image is already mapped and its main-actor entry has run.
    private func preloadPluginServer(home: URL) {
        let path = home.appendingPathComponent("Documents/swift/host/libSwiftInProcPluginServer.dylib").path
        guard let handle = dlopen(path, RTLD_NOW | RTLD_LOCAL) else {
            let reason = dlerror().map { String(cString: $0) } ?? "unknown"
            NSLog("palm plugin server %@", reason)
            return
        }
        guard let symbol = dlsym(handle, "swift_inproc_plugins_handle_message") else {
            NSLog("palm plugin server missing entry")
            return
        }
        typealias Entry = @convention(c) (
            UnsafePointer<UInt8>?, Int,
            UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>?,
            UnsafeMutablePointer<Int>?
        ) -> Bool
        let entry = unsafeBitCast(symbol, to: Entry.self)
        var byte: UInt8 = 0
        var out: UnsafeMutablePointer<UInt8>?
        var length = 0
        _ = entry(&byte, 0, &out, &length)
        NSLog("palm plugin server ready")
    }

    func start() {
        if server != nil { return }
        let home = URL(fileURLWithPath: "/private" + NSHomeDirectory())
        var context = DriverContext.nyxianDocuments(home: home)
        // CoreCompiler is the Swift 6.4 toolchain. iOS 27 SwiftUICore implements
        // @State with the SwiftUIMacros plugin, which ships only as a macOS dylib.
        // The 26.5 slice still declares State as a property wrapper, and 6.4 can load it.
        context.sdkRoot = home.appendingPathComponent("Documents/SDK/iPhoneOS26.5.sdk")
        let sourceRoot = home.appendingPathComponent("Documents/Projects")
        let executor = ControlExecutor(toolchain: NyxianToolchain(), sourceRoot: sourceRoot, context: context)
        preloadPluginServer(home: home)
        let server = ControlServer { executor.run($0) }
        do {
            let bound = try server.start(port: port)
            self.server = server
            NSLog("palm control listening on %u", bound)
        } catch {
            NSLog("palm control failed to listen: %@", String(describing: error))
        }
    }
}
