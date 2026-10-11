// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import MobileDevelopmentKit

/// On-device toolchain. Compile and link go through MobileDevelopmentKit,
/// which is Nyxian's open swiftc/clang driver. Sign uses the existing
/// NXT2 signer. Launch uses the existing process manager when it is loaded.
final class NyxianToolchain: DeviceToolchain {
    private var linkJobs: [MDKJob] = []

    func pull(_ request: ControlRequest, log: ControlLog) throws {}

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
                log.append("run \(item.type.rawValue) \(item.arguments.joined(separator: " "))")
                let primary = frontendPrimary(item.arguments)
                NSLog("palm run %@ %@ %@", "\(item.type.rawValue)", job.moduleName, primary)
                try execute(item, log: log, stage: "compile")
            }
        }
    }

    func link(_ plan: BuildPlan, log: ControlLog) throws {
        let jobs = try resolveLinkJobs(linkJobs, log: log)
        if jobs.isEmpty {
            throw ControlError.linkFailed("compiler driver emitted no linker job for \(plan.linkJob.output)")
        }
        let objects = plan.linkJob.arguments.filter { $0.hasSuffix(".o") }
        for item in jobs {
            let linked = item.type == .linker ? (PalmLinkerJob(item.arguments + objects) ?? item) : item
            log.append("link job \(linked.type.rawValue) \(linked.arguments.joined(separator: " "))")
            try execute(linked, log: log, stage: "link")
        }
        guard FileManager.default.fileExists(atPath: plan.linkJob.output) else {
            throw ControlError.linkFailed("linker produced no \(plan.linkJob.output)")
        }
        log.append("linked \(plan.linkJob.output)")
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
        let info: [String: Any] = [
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

    func start() {
        if server != nil { return }
        let home = URL(fileURLWithPath: "/private" + NSHomeDirectory())
        var context = DriverContext.nyxianDocuments(home: home)
        // The linked CoreCompiler is Nyxian 0.11.4's Swift 6.3.3. The 27.0 SDK
        // swiftinterface is Swift 6.4, so this host uses the 26.5 slice.
        context.sdkRoot = home.appendingPathComponent("Documents/SDK/iPhoneOS26.5.sdk")
        let sourceRoot = home.appendingPathComponent("Documents/Projects")
        let executor = ControlExecutor(toolchain: NyxianToolchain(), sourceRoot: sourceRoot, context: context)
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
