// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import MobileDevelopmentKit

/// What the PalmHost screen shows while a request is in flight.
final class PalmHostStatus {
    static let shared = PalmHostStatus()
    private let lock = NSLock()
    private var headline = "Starting"
    private var detail = ""
    private var recent: [String] = []
    private var completed = 0
    private var total = 0
    var onChange: (() -> Void)?

    func snapshot() -> (headline: String, detail: String, recent: [String], fraction: Double) {
        lock.lock()
        defer { lock.unlock() }
        let fraction = total == 0 ? 0 : Double(completed) / Double(total)
        return (headline, detail, recent, fraction)
    }

    func beginCompile(total: Int) {
        lock.lock()
        completed = 0
        self.total = total
        headline = "0 / \(total)"
        detail = "Starting compile"
        recent.append(headline)
        lock.unlock()
        publish()
    }

    func finishedFile(module: String, file: String, cached: Bool) {
        lock.lock()
        completed += 1
        headline = "\(completed) / \(total)"
        detail = (cached ? "cached  " : "") + "\(module)  \(file)"
        recent.append(detail)
        if recent.count > 80 {
            recent.removeFirst(recent.count - 80)
        }
        lock.unlock()
        publish()
    }

    func markStage(_ headline: String) {
        lock.lock()
        if total > 0 {
            completed = total
        }
        self.headline = headline
        detail = ""
        recent.append(headline)
        lock.unlock()
        publish()
    }

    func set(headline: String, detail: String = "") {
        note(headline, detail: detail, record: headline)
    }

    func compiling(module: String, file: String) {
        lock.lock()
        if total > 0 {
            headline = "\(completed) / \(total)"
        } else {
            headline = "Compiling \(module)"
        }
        detail = "\(module)  \(file)"
        recent.append(detail)
        if recent.count > 80 {
            recent.removeFirst(recent.count - 80)
        }
        lock.unlock()
        publish()
    }

    func record(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if trimmed.hasPrefix("run ") || trimmed.hasPrefix("link job ") || trimmed.hasPrefix("deferred ") {
            return
        }
        let shown = trimmed.count > 220 ? String(trimmed.prefix(220)) : trimmed
        if trimmed.hasPrefix("stage ") {
            note(trimmed.replacingOccurrences(of: "stage ", with: "").capitalized, detail: "", record: trimmed)
            return
        }
        if trimmed.hasPrefix("jobs ") {
            let module = trimmed.split(separator: " ").last.map(String.init) ?? ""
            note(module.isEmpty ? headline : "Compiling \(module)", detail: trimmed, record: trimmed)
            return
        }
        if trimmed.hasPrefix("link objects ") || trimmed.hasPrefix("linked ") || trimmed.hasPrefix("signed ") || trimmed.hasPrefix("launched ") {
            note(trimmed, detail: "", record: trimmed)
            return
        }
        if trimmed.contains("error:") || trimmed.hasPrefix("diagnostics ") {
            note("Failed", detail: shown, record: shown)
            return
        }
        lock.lock()
        recent.append(shown)
        if recent.count > 80 {
            recent.removeFirst(recent.count - 80)
        }
        lock.unlock()
        publish()
    }

    private func note(_ headline: String, detail: String, record: String) {
        lock.lock()
        self.headline = headline
        self.detail = detail
        recent.append(record)
        if recent.count > 80 {
            recent.removeFirst(recent.count - 80)
        }
        lock.unlock()
        publish()
    }

    private func publish() {
        let callback = onChange
        if Thread.isMainThread {
            callback?()
        } else {
            DispatchQueue.main.async { callback?() }
        }
    }
}

/// On-device toolchain. Compile and link go through MobileDevelopmentKit,
/// which is Nyxian's open swiftc/clang driver. Sign uses the existing
/// NXT2 signer. Launch uses the existing process manager when it is loaded.
final class NyxianToolchain: DeviceToolchain {
    private var linkJobs: [MDKJob] = []
    private var compiledObjects: [String] = []
    private let stateLock = NSLock()
    private var compileFailure: String?
    private var compileStampPrefix = ""

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
        let stamp = sdkInterfaceStamp(home: home)
        compileStampPrefix = stamp
        let stampURL = home.appendingPathComponent("Documents/Cache/Palm/sdk-stamp.txt")
        let previous = try? String(contentsOf: stampURL, encoding: .utf8)
        if previous != stamp {
            try? FileManager.default.removeItem(at: home.appendingPathComponent("Documents/ModuleCache"))
            try? FileManager.default.createDirectory(at: stampURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? stamp.write(to: stampURL, atomically: true, encoding: .utf8)
        }
        compileFailure = nil
        linkJobs.removeAll()
        compiledObjects.removeAll()
        let store = home.appendingPathComponent("Documents/Cache/Palm/objects")
        let restored = (try? restoreTemporaryObjects(from: store, to: URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true))) ?? 0
        if restored > 0 {
            log.append("restored \(restored) objects into tmp")
        }
        let output = URL(fileURLWithPath: plan.linkJob.output)
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        var pending: [(module: String, job: MDKJob)] = []
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
                pending.append((job.moduleName, runnable))
            }
        }
        PalmHostStatus.shared.beginCompile(total: pending.count)
        var clangBatch: [(module: String, job: MDKJob)] = []
        var swiftBatch: [(module: String, job: MDKJob)] = []
        func runBatch(_ batch: [(module: String, job: MDKJob)], parallel: Bool) throws {
            guard !batch.isEmpty else { return }
            var modules: [String: String] = [:]
            for item in batch {
                modules[frontendKey(item.job)] = item.module
            }
            let jobs = batch.map(\.job)
            let ok = PalmRunJobs(jobs, parallel && jobs.count > 1, 1) { [self] job in
                guard let job else { return false }
                return performFrontend(modules[frontendKey(job)] ?? "", job, log: log)
            }
            if !ok {
                throw ControlError.compileFailed(compileFailure ?? "compile failed")
            }
        }
        func flushClang() throws {
            let batch = clangBatch
            clangBatch.removeAll()
            // A parallel clang batch in this process segfaulted the host (signal 11).
            try runBatch(batch, parallel: false)
        }
        func flushSwift() throws {
            let batch = swiftBatch
            swiftBatch.removeAll()
            // One Swift frontend at a time. Six frontends share the plugin server and
            // hang. One frontend with six primary files fails immediately because each
            // file has its own -emit-module-path.
            try runBatch(batch, parallel: false)
        }
        for item in pending {
            if item.job.type == .compiler {
                try flushSwift()
                clangBatch.append(item)
                continue
            }
            try flushClang()
            if let first = swiftBatch.first, first.module != item.module {
                try flushSwift()
            }
            swiftBatch.append(item)
        }
        try flushClang()
        try flushSwift()
    }

    func link(_ plan: BuildPlan, log: ControlLog) throws {
        PalmHostStatus.shared.markStage("Linking")
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
            let expanded = droppingMissingFrameworks(dedupingRepeatedObjects(item.arguments + objects)) { path in
                FileManager.default.fileExists(atPath: path)
            }
            let invocation = try linkerResponseInvocation(expanded)
            let linked = item.type == .linker ? (PalmLinkerJob(invocation) ?? item) : item
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

    /// A full GuideAI link is far past 64 arguments. The installed linker
    /// would drop `-arch` on that command, so hand lld a response file.
    private func linkerResponseInvocation(_ arguments: [String]) throws -> [String] {
        let path = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("palm-link-\(UUID().uuidString).rsp")
            .path
        let invocation = linkerInvocation(arguments: arguments, responseFile: path)
        guard invocation != arguments else { return arguments }
        let lines = arguments.map { argument -> String in
            if argument.contains(where: { $0 == " " || $0 == "\t" || $0 == "\\" || $0 == "\"" }) {
                let escaped = argument
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"")
                return "\"\(escaped)\""
            }
            return argument
        }.joined(separator: "\n") + "\n"
        guard FileManager.default.createFile(atPath: path, contents: Data(lines.utf8)) else {
            throw ControlError.linkFailed("could not write \(path)")
        }
        return invocation
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
        let runtime = arguments.firstIndex(of: "-syslibroot").map { index -> Bool in
            guard index + 1 < arguments.count else { return false }
            let documents = URL(fileURLWithPath: arguments[index + 1])
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            return FileManager.default.fileExists(atPath: documents.appendingPathComponent("lib/libclang_rt.ios.a").path)
        } ?? false
        arguments = preparingLinkArguments(arguments, runtimeLibraryExists: runtime)
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
        if let identifier = plan.signingProfileIdentifier {
            log.append("profile \(identifier)")
        }
        try bundleLinkedFrameworks(plan, into: bundleURL, log: log)
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

    private func isMachODylib(_ path: String) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        let data = handle.readData(ofLength: 16)
        guard data.count >= 16 else { return false }
        let magic = data.withUnsafeBytes { $0.load(as: UInt32.self) }
        let fileType = data.withUnsafeBytes { $0.load(fromByteOffset: 12, as: UInt32.self) }
        let dylib: UInt32 = 6
        return (magic == 0xfeedfacf || magic == 0xfeedface || magic == 0xcffaedfe || magic == 0xcefaedfe) && fileType == dylib
    }

    private func bundleLinkedFrameworks(_ plan: BuildPlan, into bundle: URL, log: ControlLog) throws {
        let home = URL(fileURLWithPath: "/private" + NSHomeDirectory())
        let sdk = home.appendingPathComponent("Documents/SDK/iPhoneOS26.5.sdk").path
        let sources = frameworksToBundle(arguments: plan.linkJob.arguments, sdkRoot: sdk, fileExists: { path in
            FileManager.default.fileExists(atPath: path)
        }, isDynamicLibrary: isMachODylib)
        guard !sources.isEmpty else { return }
        let frameworks = bundle.appendingPathComponent("Frameworks")
        try FileManager.default.createDirectory(at: frameworks, withIntermediateDirectories: true)
        for source in sources {
            let destination = frameworks.appendingPathComponent((source as NSString).lastPathComponent)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: URL(fileURLWithPath: source), to: destination)
            let binary = destination.appendingPathComponent(destination.deletingPathExtension().lastPathComponent)
            if FileManager.default.fileExists(atPath: binary.path) {
                try signFile(binary.path, plan: plan, log: log)
            }
            log.append("bundled \(destination.lastPathComponent)")
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
        if let profile = plan.provisioningProfile {
            try profile.write(to: bundle.appendingPathComponent("embedded.mobileprovision"))
        }
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

    private func frontendKey(_ job: MDKJob) -> String {
        emittedObjectPath(arguments: job.arguments, outputFilePath: job.outputFileURL?.path) ?? job.arguments.joined(separator: "\n")
    }

    private func frontendPrimary(_ arguments: [String]) -> String {
        for flag in ["-primary-file", "-o"] {
            if let index = arguments.firstIndex(of: flag), index + 1 < arguments.count {
                return (arguments[index + 1] as NSString).lastPathComponent
            }
        }
        return ""
    }

    private func performFrontend(_ module: String, _ job: MDKJob, log: ControlLog) -> Bool {
        let primary = frontendPrimary(job.arguments)
        if let cached = freshObject(for: job) {
            stateLock.lock()
            compiledObjects.append(cached)
            stateLock.unlock()
            logLine(log, "cached \(module) \(primary)")
            PalmHostStatus.shared.finishedFile(module: module, file: primary, cached: true)
            storeTemporaryObject(cached)
            return true
        }
        PalmHostStatus.shared.compiling(module: module, file: primary)
        NSLog("palm run %@ %@ %@", "\(job.type.rawValue)", module, primary)
        var diagnostics: NSArray?
        var mainSource: NSString?
        let ok = job.execute(withOutDiagnostics: &diagnostics, withOutMainSource: &mainSource)
        let items = (diagnostics as? [MDKDiagnostic]) ?? []
        stateLock.lock()
        if let diagnostics {
            log.append("diagnostics \(diagnostics)")
        }
        for item in items {
            log.append("\(mainSource ?? ""): \(item.message ?? "")")
        }
        if ok, let path = emittedObjectPath(arguments: job.arguments, outputFilePath: job.outputFileURL?.path) {
            compiledObjects.append(path)
            writeStamp(for: job, output: path)
            storeTemporaryObject(path)
        } else if !ok {
            let message = items.map { $0.message ?? "" }.joined(separator: "\n")
            compileFailure = message.isEmpty ? "compile failed" : message
        }
        stateLock.unlock()
        if ok {
            PalmHostStatus.shared.finishedFile(module: module, file: primary, cached: false)
        }
        return ok
    }

    private func logLine(_ log: ControlLog, _ line: String) {
        stateLock.lock()
        log.append(line)
        stateLock.unlock()
    }

    private func freshObject(for job: MDKJob) -> String? {
        guard let output = emittedObjectPath(arguments: job.arguments, outputFilePath: job.outputFileURL?.path) else { return nil }
        let files = FileManager.default
        guard files.fileExists(atPath: output),
              let outputDate = fileDate(output) else { return nil }
        let inputs = compileInputPaths(
            arguments: job.arguments,
            declaredInputs: (job.inputFileURLs ?? []).map(\.path),
            output: output
        )
        let inputDates = inputs.compactMap { fileDate($0) }
        guard inputDates.count == inputs.count else { return nil }
        let saved = try? String(contentsOfFile: output + ".palmflags", encoding: .utf8)
        let stamp = compileArgumentStamp([compileStampPrefix] + job.arguments)
        guard compileOutputIsFresh(outputExists: true, outputDate: outputDate, inputDates: inputDates, savedStamp: saved, argumentStamp: stamp) else {
            return nil
        }
        return output
    }

    private func writeStamp(for job: MDKJob, output: String) {
        let stamp = compileArgumentStamp([compileStampPrefix] + job.arguments)
        try? stamp.write(toFile: output + ".palmflags", atomically: true, encoding: .utf8)
    }

    private func storeTemporaryObject(_ output: String) {
        let home = URL(fileURLWithPath: "/private" + NSHomeDirectory())
        let store = home.appendingPathComponent("Documents/Cache/Palm/objects")
        try? persistTemporaryObject(output, temporaryDirectory: NSTemporaryDirectory(), storeDirectory: store)
    }

    private func fileDate(_ path: String) -> Date? {
        try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date
    }

    private func sdkInterfaceStamp(home: URL) -> String {
        let root = home.appendingPathComponent("Documents/SDK/iPhoneOS26.5.sdk")
        let relatives = [
            "System/Library/Frameworks/AVFAudio.framework/Headers/AVAudioSession.h",
            "System/Library/Frameworks/FoundationModels.framework/Modules/FoundationModels.swiftmodule/arm64e-apple-ios.swiftinterface",
            "System/Library/Frameworks/HealthKit.framework/Modules/HealthKit.swiftmodule/arm64e-apple-ios.swiftinterface",
            "System/Library/Frameworks/_MapKit_SwiftUI.framework/Modules/_MapKit_SwiftUI.swiftmodule/arm64e-apple-ios.swiftinterface",
        ]
        return relatives.map { relative in
            let path = root.appendingPathComponent(relative).path
            let date = fileDate(path)?.timeIntervalSince1970 ?? 0
            return "\(relative)=\(date)"
        }.joined(separator: "\n")
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
            PalmHostStatus.shared.set(headline: "Plugin server failed", detail: reason)
            return
        }
        guard let symbol = dlsym(handle, "swift_inproc_plugins_handle_message") else {
            NSLog("palm plugin server missing entry")
            PalmHostStatus.shared.set(headline: "Plugin server failed", detail: "missing entry")
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
        PalmHostStatus.shared.set(headline: "Plugin server ready")
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
        ControlLog.mirror = { PalmHostStatus.shared.record($0) }
        preloadPluginServer(home: home)
        let server = ControlServer { executor.run($0) }
        do {
            let bound = try server.start(port: port)
            self.server = server
            NSLog("palm control listening on %u", bound)
            PalmHostStatus.shared.set(headline: "Listening on \(bound)", detail: "Waiting for a build")
        } catch {
            NSLog("palm control failed to listen: %@", String(describing: error))
            PalmHostStatus.shared.set(headline: "Not listening", detail: String(describing: error))
        }
    }
}
