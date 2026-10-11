// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

public struct CompilerJob: Codable, Equatable {
    public var tool: String
    public var moduleName: String
    public var sources: [String]
    public var arguments: [String]

    public init(tool: String, moduleName: String, sources: [String], arguments: [String]) {
        self.tool = tool
        self.moduleName = moduleName
        self.sources = sources
        self.arguments = arguments
    }
}

public struct LinkerJob: Codable, Equatable {
    public var output: String
    public var frameworks: [String]
    public var arguments: [String]

    public init(output: String, frameworks: [String], arguments: [String]) {
        self.output = output
        self.frameworks = frameworks
        self.arguments = arguments
    }
}

public struct BuildPlan: Codable, Equatable {
    public var target: String
    public var bundleIdentifier: String
    public var deploymentTarget: String
    public var entitlements: [String: PlistValue]
    public var entitlementKeys: [String]
    public var compileJobs: [CompilerJob]
    public var linkJob: LinkerJob
    public var linkedFrameworks: [String]
    public var sdkFrameworks: [String]
    public var missingSDKFrameworks: [String]
    public var localPackages: [String]
    public var remotePackages: [String]
    public var testSources: [String]
    public var testExecutable: String?
    public var includesTests: Bool
    public var preparesLaunch: Bool

    public var descriptionForLog: String {
        var lines: [String] = []
        lines.append("target \(target) \(bundleIdentifier)")
        lines.append("frameworks \(linkedFrameworks.joined(separator: " "))")
        if !sdkFrameworks.isEmpty {
            lines.append("sdk \(sdkFrameworks.joined(separator: " "))")
        }
        if !missingSDKFrameworks.isEmpty {
            lines.append("sdk missing \(missingSDKFrameworks.joined(separator: " "))")
        }
        if !entitlementKeys.isEmpty {
            lines.append("entitlements \(entitlementKeys.joined(separator: " "))")
        }
        if !localPackages.isEmpty {
            lines.append("packages \(localPackages.joined(separator: " "))")
        }
        if !remotePackages.isEmpty {
            lines.append("remote packages \(remotePackages.joined(separator: " "))")
        }
        for job in compileJobs {
            lines.append("\(job.tool) -module-name \(job.moduleName)")
            for source in job.sources {
                lines.append("  \(source)")
            }
        }
        lines.append("link \(linkJob.output)")
        lines.append(linkJob.arguments.joined(separator: " "))
        if includesTests {
            lines.append("tests \(testSources.joined(separator: " "))")
            if let testExecutable {
                lines.append("test bin \(testExecutable)")
            }
        }
        return lines.joined(separator: "\n")
    }
}

public struct DriverContext: Equatable {
    public var sdkRoot: URL
    public var swiftResourceDir: URL
    public var moduleCache: URL
    public var workRoot: URL

    public init(sdkRoot: URL, swiftResourceDir: URL, moduleCache: URL, workRoot: URL) {
        self.sdkRoot = sdkRoot
        self.swiftResourceDir = swiftResourceDir
        self.moduleCache = moduleCache
        self.workRoot = workRoot
    }

    /// Paths Nyxian already uses after bootstrap: Documents/SDK and Documents/swift.
    public static func nyxianDocuments(home: URL) -> DriverContext {
        let root = home.appendingPathComponent("Documents")
        return DriverContext(
            sdkRoot: root.appendingPathComponent("SDK/iPhoneOS27.0.sdk"),
            swiftResourceDir: root.appendingPathComponent("swift"),
            moduleCache: root.appendingPathComponent("ModuleCache"),
            workRoot: root.appendingPathComponent("Cache/Palm")
        )
    }
}

public struct ProjectDriver {
    public init() {}

    public func plan(project: URL, target name: String, kind: ControlRequestKind, tests: [String], context: DriverContext) throws -> BuildPlan {
        let projectURL = project.hasDirectoryPath || project.pathExtension == "xcodeproj"
            ? project
            : project
        let xcodeproj = projectURL.pathExtension == "xcodeproj"
            ? projectURL
            : projectURL.appendingPathComponent("project.pbxproj").deletingLastPathComponent()
        let pbxproj = xcodeproj.appendingPathComponent("project.pbxproj")
        guard FileManager.default.fileExists(atPath: pbxproj.path) else {
            throw ControlError.missingProject(pbxproj.path)
        }
        let projectDirectory = xcodeproj.deletingLastPathComponent()
        let text = try String(contentsOf: pbxproj, encoding: .utf8)
        let objects = try PbxParser.objects(in: text)
        guard let target = nativeTarget(named: name, objects: objects) else {
            throw ControlError.missingTarget(name)
        }
        let settings = buildSettings(for: target, objects: objects)
        let bundleID = settings["PRODUCT_BUNDLE_IDENTIFIER"] ?? "app.palm.\(name)"
        let deployment = settings["IPHONEOS_DEPLOYMENT_TARGET"] ?? "18.0"
        let sources = sourceFiles(for: target, objects: objects, projectDirectory: projectDirectory)
        let packages = try packageUnits(
            for: target,
            objects: objects,
            projectDirectory: projectDirectory,
            extraModules: imports(in: sources.swift)
        )
        var imported = Set(imports(in: sources.swift))
        for package in packages where !package.isTest {
            imported.formUnion(imports(in: package.sources))
        }
        let projectImports = importsAcrossProject(objects: objects, projectDirectory: projectDirectory)
        let sdkFrameworks = SDKFrameworks.guideAIGaps.filter { projectImports.contains($0) || imported.contains($0) }
        let linked = SDKFrameworks.linkable(imported.union(sources.frameworksFromSettings))
        let missing = SDKFrameworks.missing(named: sdkFrameworks, sdkRoot: context.sdkRoot)
        let overlayRoot = context.workRoot.appendingPathComponent("SDKOverlay")
        let overlaid = try SDKFrameworks.writeOverlays(for: missing, sdkRoot: context.sdkRoot, overlayRoot: overlayRoot)
        let stillMissing = missing.filter { !overlaid.contains($0) }

        var entitlements: [String: PlistValue] = [:]
        if let relative = settings["CODE_SIGN_ENTITLEMENTS"] {
            let url = projectDirectory.appendingPathComponent(relative)
            if FileManager.default.fileExists(atPath: url.path) {
                entitlements = try PlistValue.read(from: url)
            }
        }

        let frameworkSearchPaths = binaryFrameworkSearchPaths(under: projectDirectory)
        let includeTests = kind.requestsTests
        let testSources = includeTests
            ? testFiles(named: tests, objects: objects, projectDirectory: projectDirectory, fallback: sources.swift)
            : []
        let testExecutable = includeTests && !testSources.isEmpty
            ? context.workRoot.appendingPathComponent("\(name)Tests").path
            : nil

        let packageModules = context.workRoot.appendingPathComponent("PackageModules")
        let moduleMaps = writePackageModules(packages.filter { !$0.isTest }, into: packageModules)
        let swiftModuleMaps = writeSwiftModuleMaps(packages.filter { !$0.isTest }, workRoot: context.workRoot)
        let moduleSearchPaths = frameworkSearchPaths
        var compileJobs: [CompilerJob] = []
        var packageObjects: [String] = []
        let unitsByName = Dictionary(packages.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        for package in packagesInDependencyOrder(packages.filter { !$0.isTest }) {
            let headers = headerPaths(for: package, units: unitsByName)
            if !package.sources.isEmpty {
                let job = swiftJob(
                    moduleName: package.name,
                    sources: try sourcesWithResourceBundle(try sourcesWithoutPreviews(package.sources, context: context), moduleName: sanitizedModule(package.name), context: context),
                    frameworks: linked,
                    deployment: deployment,
                    context: context,
                    overlayRoot: overlaid.isEmpty ? nil : overlayRoot,
                    frameworkSearchPaths: moduleSearchPaths,
                    headerSearchPaths: headers,
                    emitModule: true,
                    output: nil,
                    moduleMaps: moduleMaps,
                    swiftPackage: true,
                    swiftVersion: package.swiftVersion
                )
                compileJobs.append(job)
                packageObjects.append(context.workRoot.appendingPathComponent("\(package.name).o").path)
            }
            let ownModule = "/\(sanitizedModule(package.name))/"
            let swiftNames = Set(swiftModuleMaps.map { URL(fileURLWithPath: $0).deletingLastPathComponent().lastPathComponent })
            let objcOnlyMaps = moduleMaps.filter { !swiftNames.contains(URL(fileURLWithPath: $0).deletingLastPathComponent().lastPathComponent) }
            let visibleMaps = (objcOnlyMaps + swiftModuleMaps).filter { !$0.contains(ownModule) }
            for (offset, source) in package.clang.enumerated() {
                let object = context.workRoot.appendingPathComponent("\(package.name)-\(offset).o").path
                compileJobs.append(clangObjectJob(
                    source: source,
                    output: object,
                    deployment: deployment,
                    context: context,
                    headerPaths: headers,
                    defines: package.defines + ["SWIFT_PACKAGE"],
                    moduleMaps: visibleMaps
                ))
                packageObjects.append(object)
            }
        }
        let appOutput = context.workRoot.appendingPathComponent("\(name).app/\(name)").path
        if !sources.swift.isEmpty {
            compileJobs.append(swiftJob(
                moduleName: sanitizedModule(name),
                sources: try sourcesWithoutPreviews(sources.swift, context: context),
                frameworks: linked,
                deployment: deployment,
                context: context,
                overlayRoot: overlaid.isEmpty ? nil : overlayRoot,
                frameworkSearchPaths: moduleSearchPaths,
                headerSearchPaths: packages.filter { !$0.isTest }.flatMap(\.headerPaths),
                emitModule: false,
                output: appOutput,
                moduleMaps: moduleMaps
            ))
        }
        if !sources.clang.isEmpty {
            compileJobs.append(clangJob(
                sources: sources.clang,
                frameworks: linked,
                deployment: deployment,
                context: context,
                output: appOutput
            ))
        }
        if includeTests && !testSources.isEmpty {
            compileJobs.append(swiftJob(
                moduleName: sanitizedModule(name) + "Tests",
                sources: testSources,
                frameworks: linked,
                deployment: deployment,
                context: context,
                overlayRoot: overlaid.isEmpty ? nil : overlayRoot,
                frameworkSearchPaths: moduleSearchPaths,
                emitModule: false,
                output: testExecutable,
                moduleMaps: moduleMaps
            ))
        }

        var linkArguments = ["-o", appOutput]
        linkArguments.append(contentsOf: packageObjects)
        for framework in linked {
            linkArguments.append("-framework")
            linkArguments.append(framework)
        }
        linkArguments.append(contentsOf: ["-F", context.sdkRoot.appendingPathComponent("System/Library/Frameworks").path])
        for path in moduleSearchPaths {
            linkArguments.append(contentsOf: ["-F", path])
        }
        linkArguments.append(contentsOf: ["-Wl,-undefined,dynamic_lookup"])

        let remote = remotePackageURLs(objects: objects)
        return BuildPlan(
            target: name,
            bundleIdentifier: bundleID,
            deploymentTarget: deployment,
            entitlements: entitlements,
            entitlementKeys: entitlements.keys.sorted(),
            compileJobs: compileJobs,
            linkJob: LinkerJob(output: appOutput, frameworks: linked, arguments: linkArguments),
            linkedFrameworks: linked,
            sdkFrameworks: sdkFrameworks.sorted(),
            missingSDKFrameworks: stillMissing,
            localPackages: packages.filter { !$0.isTest }.map(\.name).sorted(),
            remotePackages: remote.sorted(),
            testSources: testSources.map { $0.path },
            testExecutable: testExecutable,
            includesTests: includeTests,
            preparesLaunch: kind.requestsLaunch
        )
    }

    private func swiftJob(moduleName: String,
                          sources: [URL],
                          frameworks: [String],
                          deployment: String,
                          context: DriverContext,
                          overlayRoot: URL?,
                          frameworkSearchPaths: [String] = [],
                          headerSearchPaths: [String] = [],
                          emitModule: Bool,
                          output: String?,
                          moduleMaps: [String] = [],
                          swiftPackage: Bool = false,
                          swiftVersion: String = "6") -> CompilerJob {
        let compiledName = sanitizedModule(moduleName)
        var arguments = [
            "-module-name", compiledName,
            "-target", "arm64-apple-ios\(deployment)",
            "-Xllvm", "-aarch64-use-tbi",
            "-sdk", context.sdkRoot.path,
            "-resource-dir", context.swiftResourceDir.path,
            "-module-cache-path", context.moduleCache.path,
            "-Xfrontend", "-enable-objc-interop",
            "-parse-as-library",
            "-driver-filelist-threshold", "1000000",
            "-swift-version", swiftVersion,
        ]
        if swiftVersion == "6" {
            arguments.append(contentsOf: ["-enable-upcoming-feature", "InferIsolatedConformances"])
        }
        if swiftPackage {
            arguments.append(contentsOf: ["-D", "SWIFT_PACKAGE"])
        }
        for map in moduleMaps {
            arguments.append(contentsOf: ["-Xcc", "-fmodule-map-file=\(map)"])
        }
        if emitModule {
            arguments.append(contentsOf: [
                "-c",
                "-emit-module",
                "-emit-module-path", context.workRoot.appendingPathComponent("\(compiledName).swiftmodule").path,
                "-emit-objc-header-path", context.workRoot.appendingPathComponent("\(compiledName)-Swift.h").path,
                "-o", context.workRoot.appendingPathComponent("\(moduleName).o").path,
            ])
        } else if let output {
            arguments.append(contentsOf: ["-o", output])
        }
        arguments.append(contentsOf: ["-F", context.sdkRoot.appendingPathComponent("System/Library/Frameworks").path])
        if let overlayRoot {
            arguments.append(contentsOf: ["-F", overlayRoot.path])
        }
        for path in frameworkSearchPaths {
            arguments.append(contentsOf: ["-F", path])
        }
        for path in headerSearchPaths {
            arguments.append(contentsOf: ["-I", path])
        }
        arguments.append(contentsOf: ["-I", context.workRoot.path])
        for framework in frameworks {
            arguments.append("-framework")
            arguments.append(framework)
        }
        arguments.append(contentsOf: sources.map(\.path))
        return CompilerJob(tool: "swiftc", moduleName: compiledName, sources: sources.map(\.path), arguments: arguments)
    }

    private func clangJob(sources: [URL], frameworks: [String], deployment: String, context: DriverContext, output: String) -> CompilerJob {
        var arguments = [
            "-target", "arm64-apple-ios\(deployment)",
            "-isysroot", context.sdkRoot.path,
            "-o", output,
        ]
        for framework in frameworks {
            arguments.append("-framework")
            arguments.append(framework)
        }
        arguments.append(contentsOf: sources.map(\.path))
        return CompilerJob(tool: "clang", moduleName: "clang", sources: sources.map(\.path), arguments: arguments)
    }

    private func clangObjectJob(source: URL, output: String, deployment: String, context: DriverContext, headerPaths: [String], defines: [String], moduleMaps: [String] = []) -> CompilerJob {
        let clangResource = context.swiftResourceDir.deletingLastPathComponent().appendingPathComponent("Include")
        var arguments = [
            "-target", "arm64-apple-ios\(deployment)",
            "-isysroot", context.sdkRoot.path,
            "-resource-dir", clangResource.path,
            "-fmodules",
            "-fmodules-cache-path", context.moduleCache.path,
            "-fobjc-arc",
            "-c",
            "-o", output,
        ]
        for path in headerPaths {
            arguments.append("-I")
            arguments.append(path)
        }
        for define in defines {
            arguments.append("-D")
            arguments.append(define)
        }
        for map in moduleMaps {
            arguments.append("-fmodule-map-file=\(map)")
        }
        arguments.append(source.path)
        let name = source.deletingPathExtension().lastPathComponent
        return CompilerJob(tool: "clang", moduleName: name, sources: [source.path], arguments: arguments)
    }
}

private struct PackageUnit {
    var name: String
    var sources: [URL]
    var clang: [URL]
    var headerPaths: [String]
    var umbrellaHeader: URL?
    var publicHeaders: [URL]
    var dependencies: [String]
    var defines: [String]
    var isTest: Bool
    var swiftVersion: String
}

private struct TargetSources {
    var swift: [URL]
    var clang: [URL]
    var frameworksFromSettings: Set<String>
}

private func nativeTarget(named name: String, objects: [String: PbxValue]) -> [String: PbxValue]? {
    for value in objects.values {
        guard let object = value.object,
              object["isa"]?.string == "PBXNativeTarget",
              object["name"]?.string == name else { continue }
        return object
    }
    return nil
}

private func buildSettings(for target: [String: PbxValue], objects: [String: PbxValue]) -> [String: String] {
    guard let listID = target["buildConfigurationList"]?.string,
          let list = objects[listID]?.object,
          let configs = list["buildConfigurations"]?.array else { return [:] }
    let ids = configs.compactMap(\.string)
    let chosen = ids.first { objects[$0]?.object?["name"]?.string == "Debug" } ?? ids.first
    guard let chosen, let settings = objects[chosen]?.object?["buildSettings"]?.object else { return [:] }
    var result: [String: String] = [:]
    for (key, value) in settings {
        if let string = value.string {
            result[key] = string
                .replacingOccurrences(of: "$(TARGET_NAME)", with: target["name"]?.string ?? "")
        }
    }
    return result
}

private func sourceFiles(for target: [String: PbxValue], objects: [String: PbxValue], projectDirectory: URL) -> TargetSources {
    var swift: [URL] = []
    var clang: [URL] = []
    let groupIDs = target["fileSystemSynchronizedGroups"]?.array?.compactMap(\.string) ?? []
    for id in groupIDs {
        guard let path = objects[id]?.object?["path"]?.string else { continue }
        let root = projectDirectory.appendingPathComponent(path)
        collectSources(at: root, swift: &swift, clang: &clang)
    }
    return TargetSources(swift: swift.sorted { $0.path < $1.path }, clang: clang.sorted { $0.path < $1.path }, frameworksFromSettings: [])
}

private func sourcesWithResourceBundle(_ sources: [URL], moduleName: String, context: DriverContext) throws -> [URL] {
    var usesModule = false
    var definesModule = false
    for source in sources {
        guard let text = try? String(contentsOf: source, encoding: .utf8) else { continue }
        if text.contains("Bundle.module") { usesModule = true }
        if text.contains("extension Bundle"), text.contains("static let module") || text.contains("static var module") {
            definesModule = true
        }
    }
    guard usesModule, !definesModule else { return sources }
    let directory = context.workRoot.appendingPathComponent("ResourceAccessors")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appendingPathComponent("\(moduleName).swift")
    let accessor = """
    import Foundation
    private final class PalmBundleFinder_\(moduleName) {}
    extension Bundle {
        static let module = Bundle(for: PalmBundleFinder_\(moduleName).self)
    }
    """
    try accessor.write(to: file, atomically: true, encoding: .utf8)
    return sources + [file]
}

private func sourcesWithoutPreviews(_ sources: [URL], context: DriverContext) throws -> [URL] {
    var rewritten: [URL] = []
    let directory = context.workRoot.appendingPathComponent("Stripped")
    for source in sources {
        guard let text = try? String(contentsOf: source, encoding: .utf8), text.contains("#Preview") else {
            rewritten.append(source)
            continue
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let slug = source.path.replacingOccurrences(of: "/", with: "_")
        let dest = directory.appendingPathComponent(slug)
        try stripPreviewBlocks(text).write(to: dest, atomically: true, encoding: .utf8)
        rewritten.append(dest)
    }
    return rewritten
}

private func stripPreviewBlocks(_ text: String) -> String {
    var result = ""
    var index = text.startIndex
    while let range = text.range(of: "#Preview", range: index..<text.endIndex) {
        result.append(contentsOf: dropPreviewAttributes(String(text[index..<range.lowerBound])))
        guard let open = text[range.upperBound...].firstIndex(of: "{") else {
            result.append(contentsOf: text[range.lowerBound...])
            return result
        }
        var depth = 0
        var cursor = open
        var closed = false
        while cursor < text.endIndex {
            let character = text[cursor]
            if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0 {
                    index = text.index(after: cursor)
                    closed = true
                    break
                }
            }
            cursor = text.index(after: cursor)
        }
        if !closed {
            result.append(contentsOf: text[range.lowerBound...])
            return result
        }
    }
    result.append(contentsOf: text[index...])
    return result
}

private func dropPreviewAttributes(_ text: String) -> String {
    var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    while let last = lines.last {
        let trimmed = last.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed.hasPrefix("@available") || trimmed == "@MainActor" || trimmed.hasPrefix("@Previewable") {
            lines.removeLast()
            continue
        }
        break
    }
    return lines.joined(separator: "\n")
}

private func isXCTestFile(_ url: URL) -> Bool {
    guard let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
    return text.contains("import XCTest")
}

private func collectSources(at root: URL, swift: inout [URL], clang: inout [URL], skippingTests: Bool = false, excluding: [String] = []) {
    guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return }
    var skip: Set<String> = [".build", "DerivedData", "Checkouts"]
    if skippingTests {
        skip.formUnion(["Tests", "UnitTests", "UnitTestsSwift", "SwiftPMTests"])
    }
    let rootPrefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
    for case let url as URL in enumerator {
        let relative = url.path.hasPrefix(rootPrefix) ? String(url.path.dropFirst(rootPrefix.count)) : url.lastPathComponent
        if skip.contains(url.lastPathComponent) || isExcluded(relative, by: excluding) {
            enumerator.skipDescendants()
            continue
        }
        if url.lastPathComponent == "Package.swift" || url.lastPathComponent == "Button+AppIntents.swift" { continue }
        switch url.pathExtension {
        case "swift":
            swift.append(url)
        case "c", "m", "mm", "cpp", "cc":
            clang.append(url)
        default:
            break
        }
    }
}

private func packageUnits(for target: [String: PbxValue], objects: [String: PbxValue], projectDirectory: URL, extraModules: Set<String>) throws -> [PackageUnit] {
    let loaded = try loadedPackages(for: target, objects: objects, projectDirectory: projectDirectory)
    let productIDs = target["packageProductDependencies"]?.array?.compactMap(\.string) ?? []
    var seeds: [String] = []
    for id in productIDs {
        if let name = objects[id]?.object?["productName"]?.string {
            seeds.append(name)
        }
    }
    seeds.append(contentsOf: extraModules)
    var units: [PackageUnit] = []
    var seen = Set<String>()
    var queue = seeds
    var index = 0
    while index < queue.count {
        let name = queue[index]
        index += 1
        guard !seen.contains(name) else { continue }
        guard let found = resolvePackageTarget(named: name, loaded: loaded) else { continue }
        seen.insert(name)
        seen.insert(found.declaration.name)
        var unit = makePackageUnit(found.declaration, packageRoot: found.root)
        let toolsMajor = loaded.first { $0.root.path == found.root.path }?.manifest.toolsMajor ?? 5
        unit.swiftVersion = toolsMajor >= 6 ? "6" : "5"
        unit.dependencies = found.declaration.dependencies.compactMap { dependency in
            resolvePackageTarget(named: dependency, loaded: loaded)?.declaration.name
        }
        if unit.dependencies.contains("nanopb") || unit.name == "nanopb" {
            for define in ["PB_FIELD_32BIT=1", "PB_NO_PACKED_STRUCTS=1", "PB_ENABLE_MALLOC=1"] where !unit.defines.contains(define) {
                unit.defines.append(define)
            }
        }
        guard !unit.sources.isEmpty || !unit.clang.isEmpty || !unit.headerPaths.isEmpty else { continue }
        units.append(unit)
        queue.append(contentsOf: found.declaration.dependencies)
    }
    return units
}

private struct LoadedPackage {
    var root: URL
    var manifest: PackageManifest
}

private func loadedPackages(for target: [String: PbxValue], objects: [String: PbxValue], projectDirectory: URL) throws -> [LoadedPackage] {
    var roots: [URL] = []
    let checkouts = projectDirectory.appendingPathComponent("Checkouts")
    if let children = try? FileManager.default.contentsOfDirectory(at: checkouts, includingPropertiesForKeys: nil) {
        roots.append(contentsOf: children)
    }
    let productIDs = target["packageProductDependencies"]?.array?.compactMap(\.string) ?? []
    for id in productIDs {
        guard let packageID = objects[id]?.object?["package"]?.string,
              let package = objects[packageID]?.object,
              let root = packageRoot(for: package, projectDirectory: projectDirectory) else { continue }
        roots.append(root)
    }
    var loaded: [LoadedPackage] = []
    var seen = Set<String>()
    for root in roots where seen.insert(root.path).inserted {
        let manifestURL = root.appendingPathComponent("Package.swift")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else { continue }
        let text = try String(contentsOf: manifestURL, encoding: .utf8)
        loaded.append(LoadedPackage(root: root, manifest: packageManifest(in: text)))
    }
    return loaded
}

private func resolvePackageTarget(named name: String, loaded: [LoadedPackage]) -> (declaration: PackageDeclaration, root: URL)? {
    for package in loaded {
        if let declaration = package.manifest.declarations.first(where: { !$0.isTest && $0.name == name }) {
            return (declaration, package.root)
        }
        if let targetName = package.manifest.products[name],
           let declaration = package.manifest.declarations.first(where: { !$0.isTest && $0.name == targetName }) {
            return (declaration, package.root)
        }
    }
    return nil
}

private func makePackageUnit(_ declaration: PackageDeclaration, packageRoot: URL) -> PackageUnit {
    let base = packageRoot.appendingPathComponent(declaration.path ?? "Sources/\(declaration.name)")
    var sources: [URL] = []
    var clang: [URL] = []
    if declaration.sourceEntries.isEmpty {
        collectSources(at: base, swift: &sources, clang: &clang, skippingTests: !declaration.isTest, excluding: declaration.excludes)
    } else {
        for entry in declaration.sourceEntries where !entry.split(separator: "/").contains("..") && !isExcluded(entry, by: declaration.excludes) {
            let url = base.appendingPathComponent(entry)
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
                collectSources(at: url, swift: &sources, clang: &clang, skippingTests: !declaration.isTest)
            } else {
                switch url.pathExtension {
                case "swift":
                    sources.append(url)
                case "c", "m", "mm", "cpp", "cc":
                    clang.append(url)
                default:
                    break
                }
            }
        }
    }
    if !declaration.isTest {
        sources = sources.filter { !isXCTestFile($0) }
    }
    var headers: [String] = []
    if FileManager.default.fileExists(atPath: base.path) {
        headers.append(base.path)
    }
    for relative in declaration.headerSearchPaths {
        let resolved = base.appendingPathComponent(relative).standardizedFileURL
        if FileManager.default.fileExists(atPath: resolved.path) {
            headers.append(resolved.path)
        }
    }
    var umbrella: URL?
    var publicHeaders: [URL] = []
    let publicRelative = declaration.publicHeadersPath ?? "include"
    let publicRoot = base.appendingPathComponent(publicRelative)
        if FileManager.default.fileExists(atPath: publicRoot.path) {
            headers.append(publicRoot.path)
            if let enumerator = FileManager.default.enumerator(at: publicRoot, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                for case let url as URL in enumerator where url.pathExtension == "h" {
                    publicHeaders.append(url)
                }
            }
            let candidates = [
                publicRoot.appendingPathComponent("\(declaration.name)/\(declaration.name).h"),
                publicRoot.appendingPathComponent("\(declaration.name).h"),
            ]
            umbrella = candidates.first { FileManager.default.fileExists(atPath: $0.path) }
        }
    return PackageUnit(
        name: declaration.name,
        sources: sources,
        clang: clang,
        headerPaths: headers,
        umbrellaHeader: umbrella,
        publicHeaders: publicHeaders,
        dependencies: declaration.dependencies,
        defines: declaration.defines,
        isTest: declaration.isTest,
        swiftVersion: "5"
    )
}

private func packagesInDependencyOrder(_ packages: [PackageUnit]) -> [PackageUnit] {
    let byName = Dictionary(packages.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
    var ordered: [PackageUnit] = []
    var emitted = Set<String>()
    var visiting = Set<String>()
    func visit(_ name: String) {
        guard let unit = byName[name], !emitted.contains(name) else { return }
        if !visiting.insert(name).inserted { return }
        for dependency in unit.dependencies {
            visit(dependency)
        }
        visiting.remove(name)
        emitted.insert(name)
        ordered.append(unit)
    }
    for package in packages {
        visit(package.name)
    }
    return ordered
}

private func headerPaths(for unit: PackageUnit, units: [String: PackageUnit]) -> [String] {
    var paths: [String] = []
    var seenPaths = Set<String>()
    var seenNames = Set<String>()
    var queue = [unit.name]
    var index = 0
    while index < queue.count {
        let name = queue[index]
        index += 1
        guard seenNames.insert(name).inserted, let item = units[name] else { continue }
        for path in item.headerPaths where seenPaths.insert(path).inserted {
            paths.append(path)
        }
        queue.append(contentsOf: item.dependencies)
    }
    return paths
}

private func writePackageModules(_ units: [PackageUnit], into root: URL) -> [String] {
    var maps: [String] = []
    for unit in units {
        let headers = unit.publicHeaders.isEmpty ? (unit.umbrellaHeader.map { [$0] } ?? []) : unit.publicHeaders
        guard !headers.isEmpty else { continue }
        let moduleName = sanitizedModule(unit.name)
        if let existing = shippedModuleMap(among: headers, moduleName: moduleName) {
            maps.append(existing)
            continue
        }
        let directory = root.appendingPathComponent(moduleName)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let umbrella = headers.map { "#import \"\($0.path)\"" }.joined(separator: "\n") + "\n"
        try? umbrella.write(to: directory.appendingPathComponent("\(moduleName).h"), atomically: true, encoding: .utf8)
        let map = """
        module \(moduleName) {
          umbrella header "\(moduleName).h"
          export *
        }
        """
        let mapURL = directory.appendingPathComponent("module.modulemap")
        try? map.write(to: mapURL, atomically: true, encoding: .utf8)
        maps.append(mapURL.path)
    }
    return maps
}

private func isExcluded(_ relative: String, by excludes: [String]) -> Bool {
    let normalized = relative.hasSuffix("/") ? String(relative.dropLast()) : relative
    for exclude in excludes {
        let rule = exclude.hasSuffix("/") ? String(exclude.dropLast()) : exclude
        if normalized == rule || normalized.hasPrefix(rule + "/") { return true }
    }
    return false
}

private func shippedModuleMap(among headers: [URL], moduleName: String) -> String? {
    var seen = Set<String>()
    for header in headers {
        var directory = header.deletingLastPathComponent()
        for _ in 0..<2 {
            let candidate = directory.appendingPathComponent("module.modulemap")
            if seen.insert(candidate.path).inserted,
               let text = try? String(contentsOf: candidate, encoding: .utf8),
               text.contains("module \(moduleName)") {
                return candidate.path
            }
            directory.deleteLastPathComponent()
        }
    }
    return nil
}

private func writeSwiftModuleMaps(_ units: [PackageUnit], workRoot: URL) -> [String] {
    var maps: [String] = []
    let directory = workRoot.appendingPathComponent("SwiftModuleMaps")
    for unit in units where !unit.sources.isEmpty {
        let moduleName = sanitizedModule(unit.name)
        let folder = directory.appendingPathComponent(moduleName)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let header = workRoot.appendingPathComponent("\(moduleName)-Swift.h").path
        let map = """
        module \(moduleName) {
          header "\(header)"
          export *
        }
        """
        let mapURL = folder.appendingPathComponent("module.modulemap")
        try? map.write(to: mapURL, atomically: true, encoding: .utf8)
        maps.append(mapURL.path)
    }
    return maps
}

private func packageRoot(for package: [String: PbxValue], projectDirectory: URL) -> URL? {
    if package["isa"]?.string == "XCLocalSwiftPackageReference", let relative = package["relativePath"]?.string {
        let root = projectDirectory.appendingPathComponent(relative)
        if FileManager.default.fileExists(atPath: root.appendingPathComponent("Package.swift").path) {
            return root
        }
    }
    if package["isa"]?.string == "XCRemoteSwiftPackageReference", let repository = package["repositoryURL"]?.string {
        return checkoutRoot(repository: repository, projectDirectory: projectDirectory)
    }
    return nil
}

private func checkoutRoot(repository: String, projectDirectory: URL) -> URL? {
    guard let name = URL(string: repository)?.deletingPathExtension().lastPathComponent, !name.isEmpty else { return nil }
    let root = projectDirectory.appendingPathComponent("Checkouts").appendingPathComponent(name)
    guard FileManager.default.fileExists(atPath: root.appendingPathComponent("Package.swift").path) else { return nil }
    return root
}

private func binaryFrameworkSearchPaths(under root: URL) -> [String] {
    guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
        return []
    }
    let skip: Set<String> = [".build", "DerivedData"]
    var paths: [String] = []
    for case let url as URL in enumerator {
        if skip.contains(url.lastPathComponent) {
            enumerator.skipDescendants()
            continue
        }
        guard url.pathExtension == "xcframework" else { continue }
        let slice = url.appendingPathComponent("ios-arm64")
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: slice.path, isDirectory: &isDirectory), isDirectory.boolValue,
           let children = try? FileManager.default.contentsOfDirectory(at: slice, includingPropertiesForKeys: nil),
           children.contains(where: { $0.pathExtension == "framework" }) {
            paths.append(slice.path)
        }
        enumerator.skipDescendants()
    }
    return paths.sorted()
}

private struct PackageDeclaration {
    var name: String
    var isTest: Bool
    var path: String?
    var dependencies: [String]
    var sourceEntries: [String]
    var excludes: [String]
    var publicHeadersPath: String?
    var headerSearchPaths: [String]
    var defines: [String]
}

private struct PackageManifest {
    var declarations: [PackageDeclaration]
    var products: [String: String]
    var toolsMajor: Int
}

private func packageManifest(in text: String) -> PackageManifest {
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    let constants = stringConstants(in: text)
    var declarations: [PackageDeclaration] = []
    var products: [String: String] = [:]
    var index = 0
    while index < lines.count {
        let line = lines[index].trimmingCharacters(in: .whitespaces)
        if line.contains(".library(") {
            let block = targetBlock(lines, from: index)
            let window = block.joined(separator: "\n")
            if let name = firstMatch(#"name:\s*"([^"]+)""#, in: window),
               let target = firstMatch(#"targets:\s*\[\s*"([^"]+)""#, in: window) {
                products[name] = target
            }
        }
        let isBinary = line.contains(".binaryTarget")
        let isTest = line.contains(".testTarget")
        let isTarget = !isBinary && (line.contains(".target(") || isTest)
        if isTarget {
            let block = targetBlock(lines, from: index)
            if let declaration = declaration(in: block, isTest: isTest, constants: constants) {
                declarations.append(declaration)
            }
        }
        index += 1
    }
    let toolsMajor = Int(firstMatch(#"swift-tools-version:\s*([0-9]+)"#, in: text) ?? "") ?? 5
    return PackageManifest(declarations: declarations, products: products, toolsMajor: toolsMajor)
}

private func targetBlock(_ lines: [String], from index: Int) -> [String] {
    var block = [lines[index]]
    var cursor = index + 1
    while cursor < lines.count && cursor < index + 400 {
        let trimmed = lines[cursor].trimmingCharacters(in: .whitespaces)
        if trimmed.contains(".target(") || trimmed.contains(".testTarget(") || trimmed.contains(".binaryTarget(") || trimmed.contains(".library(") {
            break
        }
        block.append(lines[cursor])
        cursor += 1
    }
    return block
}

private func declaration(in block: [String], isTest: Bool, constants: [String: String]) -> PackageDeclaration? {
    let window = block.joined(separator: "\n")
    guard let name = firstMatch(#"name:\s*"([^"]+)""#, in: window) else { return nil }
    var dependencies: [String] = []
    var sourceEntries: [String] = []
    var excludes: [String] = []
    var defines: [String] = []
    var collectingSources = false
    var collectingExcludes = false
    var sawName = false
    for raw in block {
        let line = raw.trimmingCharacters(in: .whitespaces)
        if !sawName, line.contains("name:") {
            sawName = true
        } else if let dependency = firstMatch(#"^"([^"]+)"\s*,?$"#, in: line) {
            dependencies.append(dependency)
        } else if sawName, line.contains("name:"), let dependency = firstMatch(#"name:\s*"([^"]+)""#, in: line) {
            dependencies.append(dependency)
        }
        if let define = firstMatch(#"define\(\s*"([^"]+)""#, in: line) {
            if let literal = firstMatch(#"to:\s*"([^"]+)""#, in: line) {
                defines.append("\(define)=\(literal)")
            } else if let symbol = firstMatch(#"to:\s*([A-Za-z_][A-Za-z0-9_]*)"#, in: line), let value = constants[symbol] {
                defines.append("\(define)=\(value)")
            } else {
                defines.append(define)
            }
        }
        if line.range(of: #"(^|[^\w])sources\s*:"#, options: .regularExpression) != nil {
            collectingSources = true
            collectingExcludes = false
        } else if collectingSources {
            if line.hasPrefix("]") {
                collectingSources = false
            } else if let entry = firstMatch(#""([^"]+)""#, in: line) {
                sourceEntries.append(entry)
            }
        }
        if line.range(of: #"(^|[^\w])exclude\s*:"#, options: .regularExpression) != nil {
            collectingExcludes = true
            collectingSources = false
        } else if collectingExcludes {
            if line.hasPrefix("]") {
                collectingExcludes = false
            } else if let entry = firstMatch(#""([^"]+)""#, in: line) {
                excludes.append(entry)
            }
        }
    }
    return PackageDeclaration(
        name: name,
        isTest: isTest,
        path: firstMatch(#"path:\s*"([^"]+)""#, in: window),
        dependencies: dependencies,
        sourceEntries: sourceEntries,
        excludes: excludes,
        publicHeadersPath: firstMatch(#"publicHeadersPath:\s*"([^"]+)""#, in: window),
        headerSearchPaths: allMatches(#"headerSearchPath\(\s*"([^"]+)""#, in: window),
        defines: defines
    )
}

private func stringConstants(in text: String) -> [String: String] {
    var constants: [String: String] = [:]
    let pattern = #"let\s+([A-Za-z_][A-Za-z0-9_]*)\s*=\s*"([^"]+)""#
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return constants }
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    for match in regex.matches(in: text, range: range) where match.numberOfRanges > 2 {
        guard let name = Range(match.range(at: 1), in: text),
              let value = Range(match.range(at: 2), in: text) else { continue }
        constants[String(text[name])] = String(text[value])
    }
    return constants
}

private func allMatches(_ pattern: String, in text: String) -> [String] {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    return regex.matches(in: text, range: range).compactMap { match in
        guard match.numberOfRanges > 1, let hit = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[hit])
    }
}

private func firstMatch(_ pattern: String, in text: String) -> String? {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    guard let match = regex.firstMatch(in: text, range: range), match.numberOfRanges > 1,
          let hit = Range(match.range(at: 1), in: text) else { return nil }
    return String(text[hit])
}

private func imports(in files: [URL]) -> Set<String> {
    var names: Set<String> = []
    for url in files {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("import ") else { continue }
            let rest = trimmed.dropFirst("import ".count)
            guard let token = rest.split(separator: " ").first else { continue }
            if token == "class" || token == "struct" || token == "enum" || token == "func" || token == "typealias" {
                continue
            }
            let head = token.split(separator: ".").first.map(String.init) ?? String(token)
            if !head.isEmpty { names.insert(head) }
        }
    }
    return names
}

private func importsAcrossProject(objects: [String: PbxValue], projectDirectory: URL) -> Set<String> {
    var names: Set<String> = []
    for value in objects.values {
        guard let object = value.object, object["isa"]?.string == "PBXNativeTarget" else { continue }
        let sources = sourceFiles(for: object, objects: objects, projectDirectory: projectDirectory)
        names.formUnion(imports(in: sources.swift))
    }
    return names
}

private func remotePackageURLs(objects: [String: PbxValue]) -> [String] {
    var urls: [String] = []
    for value in objects.values {
        guard let object = value.object, object["isa"]?.string == "XCRemoteSwiftPackageReference" else { continue }
        if let url = object["repositoryURL"]?.string {
            urls.append(url)
        }
    }
    return urls
}

private func testFiles(named tests: [String], objects: [String: PbxValue], projectDirectory: URL, fallback: [URL]) -> [URL] {
    var pool: [URL] = []
    for value in objects.values {
        guard let object = value.object,
              object["isa"]?.string == "PBXNativeTarget",
              let product = object["productType"]?.string,
              product.contains("test") else { continue }
        pool.append(contentsOf: sourceFiles(for: object, objects: objects, projectDirectory: projectDirectory).swift)
    }
    if tests.isEmpty { return pool }
    let wanted = Set(tests)
    let matched = pool.filter { url in
        wanted.contains(url.deletingPathExtension().lastPathComponent) || wanted.contains(url.lastPathComponent) || wanted.contains(url.path)
    }
    return matched.isEmpty ? fallback.filter { url in
        wanted.contains(url.deletingPathExtension().lastPathComponent)
    } : matched
}

private func sanitizedModule(_ name: String) -> String {
    let scalars = name.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : "_" }
    let joined = String(scalars)
    return joined.isEmpty ? "App" : joined
}
