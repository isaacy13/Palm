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
    /// Compiled bundles to place next to the executable, such as a Core Data `.momd`.
    public var bundleResources: [String] = []
    /// `InfoOverrides.plist` plus `INFOPLIST_KEY_*` usage strings for the signed app.
    public var infoPlist: [String: PlistValue] = [:]
    /// Copied into the guest bundle as `embedded.mobileprovision`.
    public var provisioningProfile: Data? = nil
    public var signingProfileIdentifier: String? = nil

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
            sdkRoot: root.appendingPathComponent("SDK/iPhoneOS26.5.sdk"),
            swiftResourceDir: root.appendingPathComponent("swift"),
            moduleCache: root.appendingPathComponent("ModuleCache"),
            workRoot: root.appendingPathComponent("Cache/Palm")
        )
    }
}

public struct ProjectDriver {
    public init() {}

    public func plan(project: URL, target name: String, kind: ControlRequestKind, context: DriverContext) throws -> BuildPlan {
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
        repairMapKitCameraInterface(sdkRoot: context.sdkRoot)
        repairFoundationModelsTranscriptInterface(sdkRoot: context.sdkRoot)
        repairAVAudioSessionActivation(sdkRoot: context.sdkRoot)
        repairHealthKitWorkoutZones(sdkRoot: context.sdkRoot)
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
        let testSources: [URL] = []
        let testExecutable: String? = nil

        let packageModules = context.workRoot.appendingPathComponent("PackageModules")
        let binaryModules = binaryModuleNames(in: frameworkSearchPaths)
        let moduleMaps = writePackageModules(packages.filter { !$0.isTest }, into: packageModules, binaryModules: binaryModules)
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
                    sources: try sourcesWithResourceBundle(try sourcesWithCrossImports(try sourcesWithoutEntryMacros(try sourcesWithoutGenerableMacros(try sourcesWithoutPreviews(package.sources, context: context), context: context), context: context), sdkRoot: context.sdkRoot, context: context), moduleName: sanitizedModule(package.name), context: context),
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
                    swiftVersion: package.swiftVersion,
                    extraArguments: package.clang.isEmpty ? [] : ["-import-underlying-module"]
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
        let linkExtras = packageLinkExtras(
            from: packages.filter { !$0.isTest },
            frameworksOnDisk: frameworkNames(in: moduleSearchPaths),
            alreadyLinked: Set(linked)
        )
        var appFrameworks = linked
        for framework in linkExtras.frameworks where !appFrameworks.contains(framework) {
            appFrameworks.append(framework)
        }
        if !sources.swift.isEmpty {
            compileJobs.append(swiftJob(
                moduleName: sanitizedModule(name),
                sources: try sourcesWithIsolatedDeinits(try sourcesWithoutBindingMethodSetters(try sourcesWithCrossImports(try sourcesWithoutEntryMacros(try sourcesWithoutGenerableMacros(try sourcesWithoutPreviews(sources.swift, context: context), context: context), context: context), sdkRoot: context.sdkRoot, context: context), context: context), context: context, enabled: usesIsolatedDeinits(settings)),
                frameworks: appFrameworks,
                deployment: deployment,
                context: context,
                overlayRoot: overlaid.isEmpty ? nil : overlayRoot,
                frameworkSearchPaths: moduleSearchPaths,
                headerSearchPaths: packages.filter { !$0.isTest }.flatMap(\.headerPaths),
                emitModule: false,
                output: appOutput,
                moduleMaps: moduleMaps,
                libraries: linkExtras.libraries,
                extraArguments: swiftLanguageArguments(from: settings)
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
        var linkArguments = ["-o", appOutput]
        linkArguments.append(contentsOf: packageObjects)
        for framework in appFrameworks {
            linkArguments.append("-framework")
            linkArguments.append(framework)
        }
        for library in linkExtras.libraries {
            linkArguments.append("-l\(library)")
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
            linkJob: LinkerJob(output: appOutput, frameworks: appFrameworks, arguments: linkArguments),
            linkedFrameworks: appFrameworks,
            sdkFrameworks: sdkFrameworks.sorted(),
            missingSDKFrameworks: stillMissing,
            localPackages: packages.filter { !$0.isTest }.map(\.name).sorted(),
            remotePackages: remote.sorted(),
            testSources: testSources.map { $0.path },
            testExecutable: testExecutable,
            includesTests: false,
            preparesLaunch: kind.requestsLaunch,
            bundleResources: compiledDataModels(under: projectDirectory),
            infoPlist: launchInfoDictionary(settings: settings, projectDirectory: projectDirectory, moduleName: name)
        )
    }

    /// Bundle id, entitlements file, and Info.plist from the project, without compiling.
    public func signingInputs(project: URL, target name: String) throws -> SigningInputs {
        let xcodeproj = project.pathExtension == "xcodeproj"
            ? project
            : project.appendingPathComponent("project.pbxproj").deletingLastPathComponent()
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
        func existing(_ key: String) -> String? {
            guard let relative = settings[key] else { return nil }
            let url = projectDirectory.appendingPathComponent(relative)
            return FileManager.default.fileExists(atPath: url.path) ? url.path : nil
        }
        return SigningInputs(
            bundleIdentifier: bundleID,
            entitlementsPath: existing("CODE_SIGN_ENTITLEMENTS"),
            infoPlistPath: existing("INFOPLIST_FILE")
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
                          swiftVersion: String = "6",
                          libraries: [String] = [],
                          extraArguments: [String] = []) -> CompilerJob {
        let compiledName = sanitizedModule(moduleName)
        var arguments = [
            "-module-name", compiledName,
            "-target", "arm64-apple-ios\(deployment)",
            "-Xllvm", "-aarch64-use-tbi",
            "-sdk", context.sdkRoot.path,
            "-resource-dir", context.swiftResourceDir.path,
            "-in-process-plugin-server-path", context.swiftResourceDir.appendingPathComponent("host/libSwiftInProcPluginServer.dylib").path,
            "-plugin-path", context.swiftResourceDir.appendingPathComponent("host/plugins").path,
            "-module-cache-path", context.moduleCache.path,
            "-Xfrontend", "-enable-objc-interop",
            "-parse-as-library",
            "-driver-filelist-threshold", "1000000",
            "-swift-version", swiftVersion,
        ]
        if swiftVersion == "6" {
            arguments.append(contentsOf: ["-enable-upcoming-feature", "InferIsolatedConformances"])
        }
        arguments.append(contentsOf: extraArguments)
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
        for library in libraries {
            arguments.append("-l\(library)")
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
    func compiledDataModels(under root: URL) -> [String] {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
            return []
        }
        let skip: Set<String> = [".build", "DerivedData", "Checkouts", "GuideAIUnitTests", "GuideAISnapshotTests", "GuideAIWatch"]
        var found: [String] = []
        for case let url as URL in enumerator {
            if skip.contains(url.lastPathComponent) {
                enumerator.skipDescendants()
                continue
            }
            guard url.pathExtension == "xcdatamodeld" else { continue }
            let compiled = url.deletingPathExtension().appendingPathExtension("momd")
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: compiled.path, isDirectory: &isDirectory), isDirectory.boolValue {
                found.append(compiled.path)
            }
            enumerator.skipDescendants()
        }
        return found.sorted()
    }

    func copyBundleResources(_ paths: [String], nextTo executable: String) throws -> [String] {
        let bundle = URL(fileURLWithPath: executable).deletingLastPathComponent()
        let files = FileManager.default
        try files.createDirectory(at: bundle, withIntermediateDirectories: true)
        var copied: [String] = []
        for path in paths {
            let source = URL(fileURLWithPath: path)
            let destination = bundle.appendingPathComponent(source.lastPathComponent)
            if files.fileExists(atPath: destination.path) {
                try files.removeItem(at: destination)
            }
            do {
                try files.copyItem(at: source, to: destination)
            } catch {
                throw ControlError.linkFailed("could not copy \(source.lastPathComponent) into \(bundle.path)")
            }
            copied.append(source.lastPathComponent)
        }
        return copied
    }

}

func launchInfoDictionary(settings: [String: String], projectDirectory: URL, moduleName: String) -> [String: PlistValue] {
    var variables = settings
    variables["PRODUCT_MODULE_NAME"] = settings["PRODUCT_MODULE_NAME"] ?? moduleName
    variables["TARGET_NAME"] = settings["TARGET_NAME"] ?? moduleName
    var info: [String: PlistValue] = [:]
    if let relative = settings["INFOPLIST_FILE"] {
        let url = projectDirectory.appendingPathComponent(relative)
        if let overrides = try? PlistValue.read(from: url) {
            info = overrides.mapValues { expandPlistVariables($0, variables: variables) }
        }
    }
    for (key, value) in settings where key.hasPrefix("INFOPLIST_KEY_") && !key.contains("[") {
        let name = String(key.dropFirst("INFOPLIST_KEY_".count))
        if value == "YES" {
            info[name] = .bool(true)
        } else if value == "NO" {
            info[name] = .bool(false)
        } else {
            info[name] = .string(expandPlistText(value, variables: variables))
        }
    }
    return info
}

public func expandPlistVariables(_ value: PlistValue, variables: [String: String]) -> PlistValue {
    switch value {
    case .string(let text):
        return .string(expandPlistText(text, variables: variables))
    case .array(let values):
        return .array(values.map { expandPlistVariables($0, variables: variables) })
    case .dictionary(let values):
        return .dictionary(values.mapValues { expandPlistVariables($0, variables: variables) })
    default:
        return value
    }
}

func expandPlistText(_ text: String, variables: [String: String]) -> String {
    var result = text
    for (key, value) in variables where !value.contains("$(") {
        result = result.replacingOccurrences(of: "$(\(key))", with: value)
    }
    return result
}

private struct PackageUnit {
    var name: String
    var sources: [URL]
    var clang: [URL]
    var headerPaths: [String]
    var umbrellaHeader: URL?
    var publicHeaders: [URL]
    var dependencies: [String]
    var linkDependencies: [String]
    var linkLibraries: [String]
    var linkFrameworks: [String]
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

/// The iOS 26.5 `_MapKit_SwiftUI` interface uses `MapCamera` and
/// `MapCameraPosition` in `Map` initializers and never declares them.
/// Declare the same stored shape so client code and those initializers agree.
private func repairMapKitCameraInterface(sdkRoot: URL) {
    let interface = sdkRoot.appendingPathComponent(
        "System/Library/Frameworks/_MapKit_SwiftUI.framework/Modules/_MapKit_SwiftUI.swiftmodule/arm64e-apple-ios.swiftinterface"
    )
    guard var text = try? String(contentsOf: interface, encoding: .utf8) else { return }
    guard !text.contains("public struct MapCamera :") else { return }
    text += """

    @available(iOS 17.0, macOS 14.0, watchOS 10.0, tvOS 17.0, *)
    public struct MapCamera : Swift.Equatable {
      public var centerCoordinate: _LocationEssentials.CLLocationCoordinate2D
      public var distance: Swift.Double
      public var heading: Swift.Double
      public var pitch: Swift.Double
      public static func == (lhs: _MapKit_SwiftUI.MapCamera, rhs: _MapKit_SwiftUI.MapCamera) -> Swift.Bool
      public init(centerCoordinate: _LocationEssentials.CLLocationCoordinate2D, distance: Swift.Double, heading: Swift.Double = 0, pitch: Swift.Double = 0)
      public init(_ camera: MapKit.MKMapCamera)
    }
    @available(iOS 17.0, macOS 14.0, watchOS 10.0, tvOS 17.0, *)
    public struct MapCameraPosition : Swift.Equatable {
      public static var automatic: _MapKit_SwiftUI.MapCameraPosition { get }
      public static func camera(_ camera: _MapKit_SwiftUI.MapCamera) -> _MapKit_SwiftUI.MapCameraPosition
      public static func region(_ region: MapKit.MKCoordinateRegion) -> _MapKit_SwiftUI.MapCameraPosition
      public static func rect(_ rect: MapKit.MKMapRect) -> _MapKit_SwiftUI.MapCameraPosition
      public static func item(_ item: MapKit.MKMapItem, allowsAutomaticPitch: Swift.Bool = true) -> _MapKit_SwiftUI.MapCameraPosition
      public static func userLocation(followsHeading: Swift.Bool = false, fallback: _MapKit_SwiftUI.MapCameraPosition) -> _MapKit_SwiftUI.MapCameraPosition
      public var camera: _MapKit_SwiftUI.MapCamera? { get }
      public var region: MapKit.MKCoordinateRegion? { get }
      public var rect: MapKit.MKMapRect? { get }
      public var item: MapKit.MKMapItem? { get }
      public var positionedByUser: Swift.Bool { get }
      public var followsUserLocation: Swift.Bool { get }
      public var followsUserHeading: Swift.Bool { get }
      public var fallbackPosition: _MapKit_SwiftUI.MapCameraPosition? { get }
      public var allowsAutomaticPitch: Swift.Bool { get }
      public static func == (a: _MapKit_SwiftUI.MapCameraPosition, b: _MapKit_SwiftUI.MapCameraPosition) -> Swift.Bool
    }
    """
    try? text.write(to: interface, atomically: true, encoding: .utf8)
}

/// The iOS 26.5 HealthKit interface has no workout zone types. iOS 27 adds
/// `HKWorkout.zoneGroupsByType`, which client code calls inside `#available(iOS 27.0, *)`.
func repairHealthKitWorkoutZones(sdkRoot: URL) {
    let interface = sdkRoot.appendingPathComponent(
        "System/Library/Frameworks/HealthKit.framework/Modules/HealthKit.swiftmodule/arm64e-apple-ios.swiftinterface"
    )
    guard var text = try? String(contentsOf: interface, encoding: .utf8) else { return }
    let health = text.contains("HealthKit::") ? "HealthKit::" : "HealthKit."
    let swift = text.contains("Swift::") ? "Swift::" : "Swift."
    let foundation = text.contains("Foundation::") ? "Foundation::" : "Foundation."
    var addition = ""
    if !text.contains("zoneGroupsByType") {
        addition += """

@available(iOS 27.0, *)
extension \(health)HKWorkout {
  public var zoneGroupsByType: [\(health)HKQuantityType : \(health)HKWorkoutZoneGroup]? {
    get
  }
}
@available(iOS 27.0, *)
public struct HKWorkoutZone : \(swift)Sendable {
  public let index: \(swift)Int
}
@available(iOS 27.0, *)
public struct HKWorkoutZoneDuration : \(swift)Sendable {
  public let zone: \(health)HKWorkoutZone
  public let duration: \(foundation)TimeInterval
}
@available(iOS 27.0, *)
public struct HKWorkoutZoneGroup : \(swift)Sendable {
  public let zoneDurations: [\(health)HKWorkoutZoneDuration]
}
"""
    }
    let zoneHasMinimum: Bool = {
        guard let zone = text.range(of: "struct HKWorkoutZone") else { return false }
        return text[zone.lowerBound...].prefix(400).contains("var minimum:")
    }()
    if !zoneHasMinimum && !text.contains("extension \(health)HKWorkoutZone") {
        addition += """

@available(iOS 27.0, *)
extension \(health)HKWorkoutZone {
  public var minimum: \(health)HKQuantity? {
    get
  }
  public var maximum: \(health)HKQuantity? {
    get
  }
}
"""
    }
    if !text.contains("struct HKWorkoutZoneConfiguration") {
        addition += """

@available(iOS 27.0, *)
public struct HKWorkoutZoneConfiguration : \(swift)Sendable {
  public enum Source : \(swift)Sendable {
    case system
    case user
    case app
  }
  public let source: \(health)HKWorkoutZoneConfiguration.Source
  public let zones: [\(health)HKWorkoutZone]
}
"""
    }
    if !text.contains("preferredWorkoutZoneConfiguration") {
        addition += """

@available(iOS 27.0, *)
extension \(health)HKHealthStore {
  public func preferredWorkoutZoneConfiguration(for quantityType: \(health)HKQuantityType) async throws -> \(health)HKWorkoutZoneConfiguration?
}
"""
    }
    guard !addition.isEmpty else { return }
    text.append(addition)
    try? text.write(to: interface, atomically: true, encoding: .utf8)
}

/// The iOS 26.5 FoundationModels interface stops at the iOS 26 `Transcript.Entry`
/// cases. iOS 27 adds `reasoning`, and client code still typechecks that case
/// inside `#available(iOS 27.0, *)`.
/// The 26.5 AVFAudio header marks `activateWithOptions` unavailable on iOS.
/// The iOS 27 SDK marks it available starting in iOS 27. GuideAI calls it
/// inside `@available(iOS 27, *)`.
func repairAVAudioSessionActivation(sdkRoot: URL) {
    let header = sdkRoot.appendingPathComponent("System/Library/Frameworks/AVFAudio.framework/Headers/AVAudioSession.h")
    guard var text = try? String(contentsOf: header, encoding: .utf8) else { return }
    let stale = "handler API_AVAILABLE(watchos(5.0)) API_UNAVAILABLE(ios, tvos) API_UNAVAILABLE(macos, macCatalyst);"
    let current = "handler API_AVAILABLE(ios(27.0), watchos(5.0), tvos(27.0), visionos(27.0)) API_UNAVAILABLE(macos);"
    guard text.contains(stale) else { return }
    text = text.replacingOccurrences(of: stale, with: current)
    try? text.write(to: header, atomically: true, encoding: .utf8)
}

private func repairFoundationModelsTranscriptInterface(sdkRoot: URL) {
    let interface = sdkRoot.appendingPathComponent(
        "System/Library/Frameworks/FoundationModels.framework/Modules/FoundationModels.swiftmodule/arm64e-apple-ios.swiftinterface"
    )
    guard var text = try? String(contentsOf: interface, encoding: .utf8) else { return }
    guard !text.contains("case reasoning(") else { return }
    let responseCase = "    case response(FoundationModels.Transcript.Response)\n"
    let equality = "  public static func == (a: FoundationModels.Transcript, b: FoundationModels.Transcript) -> Swift.Bool\n"
    guard let responseRange = text.range(of: responseCase), let equalityRange = text.range(of: equality) else { return }
    let reasoningCase = """
        case response(FoundationModels.Transcript.Response)
        @available(iOS 27.0, macOS 27.0, visionOS 27.0, *)
        @available(tvOS, unavailable)
        @available(watchOS, unavailable)
        case reasoning(FoundationModels.Transcript.Reasoning)

    """
    let reasoningStruct = """
      @available(iOS 27.0, macOS 27.0, visionOS 27.0, *)
      @available(tvOS, unavailable)
      @available(watchOS, unavailable)
      public struct Reasoning : Swift.Sendable, Swift.Identifiable, Swift.Equatable {
        public var id: Swift.String
        public var segments: [FoundationModels.Transcript.Segment]
        public var signature: Foundation.Data?
        public var metadata: [Swift.String : any Swift.Codable & Swift.Sendable & Swift.Equatable]
        public init(id: Swift.String = UUID().uuidString, metadata: [Swift.String : any Swift.Sendable & Swift.Codable & Swift.Equatable] = [:], segments: [FoundationModels.Transcript.Segment], signature: Foundation.Data? = nil)
        public static func == (lhs: FoundationModels.Transcript.Reasoning, rhs: FoundationModels.Transcript.Reasoning) -> Swift.Bool
        @available(iOS 27.0, macOS 27.0, visionOS 27.0, *)
        @available(tvOS, unavailable)
        @available(watchOS, unavailable)
        public typealias ID = Swift.String
      }
      public static func == (a: FoundationModels.Transcript, b: FoundationModels.Transcript) -> Swift.Bool

    """
    text.replaceSubrange(equalityRange, with: reasoningStruct)
    text.replaceSubrange(responseRange, with: reasoningCase)
    try? text.write(to: interface, atomically: true, encoding: .utf8)
}

private func swiftLanguageArguments(from settings: [String: String]) -> [String] {
    var arguments: [String] = []
    if let isolation = settings["SWIFT_DEFAULT_ACTOR_ISOLATION"], !isolation.isEmpty, isolation != "nonisolated" {
        arguments.append(contentsOf: ["-default-isolation", isolation])
        arguments.append(contentsOf: ["-enable-upcoming-feature", "IsolatedDeinit"])
    }
    if settings["SWIFT_APPROACHABLE_CONCURRENCY"] == "YES" {
        for feature in ["NonisolatedNonsendingByDefault", "InferIsolatedConformances", "InferSendableFromCaptures"] {
            arguments.append(contentsOf: ["-enable-upcoming-feature", feature])
        }
    }
    for (key, value) in settings where key.hasPrefix("SWIFT_UPCOMING_FEATURE_") && value == "YES" {
        let feature = key.dropFirst("SWIFT_UPCOMING_FEATURE_".count).split(separator: "_").map { part in
            part.prefix(1).uppercased() + part.dropFirst().lowercased()
        }.joined()
        guard !feature.isEmpty else { continue }
        arguments.append(contentsOf: ["-enable-upcoming-feature", feature])
    }
    return arguments
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
    appendExplicitSources(of: target, objects: objects, projectDirectory: projectDirectory, swift: &swift, clang: &clang)
    return TargetSources(swift: swift.sorted { $0.path < $1.path }, clang: clang.sorted { $0.path < $1.path }, frameworksFromSettings: [])
}

/// Synchronized folders miss files that are only listed on the target's Sources phase.
private func appendExplicitSources(of target: [String: PbxValue], objects: [String: PbxValue], projectDirectory: URL, swift: inout [URL], clang: inout [URL]) {
    let phaseIDs = target["buildPhases"]?.array?.compactMap(\.string) ?? []
    for id in phaseIDs {
        guard let phase = objects[id]?.object, phase["isa"]?.string == "PBXSourcesBuildPhase" else { continue }
        for fileID in phase["files"]?.array?.compactMap(\.string) ?? [] {
            guard let buildFile = objects[fileID]?.object,
                  let refID = buildFile["fileRef"]?.string,
                  let ref = objects[refID]?.object,
                  let path = ref["path"]?.string else { continue }
            let url = projectDirectory.appendingPathComponent(path)
            if path.hasSuffix(".swift") {
                if !swift.contains(where: { $0.path == url.path }) { swift.append(url) }
            } else if ["m", "c", "mm", "cc", "cpp"].contains(url.pathExtension) {
                if !clang.contains(where: { $0.path == url.path }) { clang.append(url) }
            }
        }
    }
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
    try writeIfChanged(accessor, to: file)
    return sources + [file]
}

private struct CrossImportOverlay {
    var declaring: String
    var bystander: String
    var modules: [String]
}

/// Swift loads `MapKit.swiftcrossimport/SwiftUI.swiftoverlay` when a file imports
/// both modules. The on-device compiler does not, so files that import both
/// sides get an explicit `import` of the overlay module.
private func crossImportOverlays(sdkRoot: URL) -> [CrossImportOverlay] {
    var overlays: [CrossImportOverlay] = []
    let frameworks = sdkRoot.appendingPathComponent("System/Library/Frameworks")
    if let names = try? FileManager.default.contentsOfDirectory(at: frameworks, includingPropertiesForKeys: nil) {
        for framework in names where framework.pathExtension == "framework" {
            collectCrossImports(in: framework.appendingPathComponent("Modules"), into: &overlays)
        }
    }
    collectCrossImports(in: sdkRoot.appendingPathComponent("usr/include"), into: &overlays)
    return overlays
}

private func collectCrossImports(in directory: URL, into overlays: inout [CrossImportOverlay]) {
    guard let children = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
    for child in children where child.lastPathComponent.hasSuffix(".swiftcrossimport") {
        guard let files = try? FileManager.default.contentsOfDirectory(at: child, includingPropertiesForKeys: nil) else { continue }
        let suffix = ".swiftcrossimport"
        let declaring = String(child.lastPathComponent.dropLast(suffix.count))
        for file in files where file.pathExtension == "swiftoverlay" {
            let modules = overlayModuleNames(in: file)
            guard !modules.isEmpty else { continue }
            overlays.append(CrossImportOverlay(
                declaring: declaring,
                bystander: file.deletingPathExtension().lastPathComponent,
                modules: modules
            ))
        }
    }
}

private func overlayModuleNames(in url: URL) -> [String] {
    guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
    var names: [String] = []
    for line in text.split(separator: "\n") {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let range = trimmed.range(of: "name:") else { continue }
        let name = trimmed[range.upperBound...].trimmingCharacters(in: .whitespaces)
        if !name.isEmpty { names.append(String(name)) }
    }
    return names
}

/// Swift 6.3.3 aborts in IRGen when a MainActor method is passed straight to
/// `Binding`'s setter. A closure call at that site compiles.
private func usesIsolatedDeinits(_ settings: [String: String]) -> Bool {
    guard let isolation = settings["SWIFT_DEFAULT_ACTOR_ISOLATION"], !isolation.isEmpty, isolation != "nonisolated" else {
        return false
    }
    return true
}

/// The on-device Swift 6.4 compiler accepts `IsolatedDeinit` but still typechecks
/// an unmarked `deinit` as nonisolated. Mark the work copy `isolated deinit`.
func isolateDeinits(_ text: String) -> String {
    text.split(separator: "\n", omittingEmptySubsequences: false).map { line in
        let raw = String(line)
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("deinit"), !trimmed.hasPrefix("isolated "), !trimmed.hasPrefix("nonisolated ") else {
            return raw
        }
        guard let range = raw.range(of: #"\bdeinit\b"#, options: .regularExpression) else { return raw }
        var updated = raw
        updated.replaceSubrange(range, with: "isolated deinit")
        return updated
    }.joined(separator: "\n")
}

private func sourcesWithIsolatedDeinits(_ sources: [URL], context: DriverContext, enabled: Bool) throws -> [URL] {
    guard enabled else { return sources }
    var rewritten: [URL] = []
    let directory = context.workRoot.appendingPathComponent("IsolatedDeinit")
    for source in sources {
        guard let text = try? String(contentsOf: source, encoding: .utf8) else {
            rewritten.append(source)
            continue
        }
        let updated = isolateDeinits(text)
        guard updated != text else {
            rewritten.append(source)
            continue
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let dest = directory.appendingPathComponent(shortSourceName(source))
        try writeIfChanged(updated, to: dest)
        rewritten.append(dest)
    }
    return rewritten
}

private func sourcesWithoutBindingMethodSetters(_ sources: [URL], context: DriverContext) throws -> [URL] {
    var rewritten: [URL] = []
    let directory = context.workRoot.appendingPathComponent("BindingSetters")
    for source in sources {
        guard let text = try? String(contentsOf: source, encoding: .utf8) else {
            rewritten.append(source)
            continue
        }
        let updated = expandBindingMethodSetters(text)
        guard updated != text else {
            rewritten.append(source)
            continue
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let dest = directory.appendingPathComponent(shortSourceName(source))
        try writeIfChanged(updated, to: dest)
        rewritten.append(dest)
    }
    return rewritten
}

private func expandBindingMethodSetters(_ text: String) -> String {
    text.split(separator: "\n", omittingEmptySubsequences: false).map { line in
        let raw = String(line)
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("set:") else { return raw }
        var rest = trimmed.dropFirst("set:".count).trimmingCharacters(in: .whitespaces)
        let comma = rest.hasSuffix(",")
        if comma { rest = rest.dropLast().trimmingCharacters(in: .whitespaces) }
        guard !rest.isEmpty, !rest.contains("{"), !rest.contains("("), !rest.contains("."), !rest.contains(" ") else { return raw }
        guard rest.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else { return raw }
        let indent = String(raw.prefix { $0 == " " || $0 == "\t" })
        return "\(indent)set: { \(rest)($0) }\(comma ? "," : "")"
    }.joined(separator: "\n")
}

private func sourcesWithCrossImports(_ sources: [URL], sdkRoot: URL, context: DriverContext) throws -> [URL] {
    let overlays = crossImportOverlays(sdkRoot: sdkRoot)
    guard !overlays.isEmpty else { return sources }
    var rewritten: [URL] = []
    let directory = context.workRoot.appendingPathComponent("CrossImports")
    for source in sources {
        guard let text = try? String(contentsOf: source, encoding: .utf8) else {
            rewritten.append(source)
            continue
        }
        let imported = imports(in: [source])
        let extra = overlays
            .filter { imported.contains($0.declaring) && imported.contains($0.bystander) }
            .flatMap(\.modules)
            .filter { !imported.contains($0) }
        guard !extra.isEmpty else {
            rewritten.append(source)
            continue
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let dest = directory.appendingPathComponent(shortSourceName(source))
        let header = extra.sorted().map { "import \($0)\n" }.joined()
        try writeIfChanged(header + text, to: dest)
        rewritten.append(dest)
    }
    return rewritten
}

/// FoundationModelsMacros is a Mac compiler plugin. Expand `@Generable` the
/// way that plugin would, so the on-device compiler never has to load it.
private func sourcesWithoutGenerableMacros(_ sources: [URL], context: DriverContext) throws -> [URL] {
    var rewritten: [URL] = []
    let directory = context.workRoot.appendingPathComponent("GenerableExpanded")
    for source in sources {
        guard let text = try? String(contentsOf: source, encoding: .utf8), text.contains("@Generable") else {
            rewritten.append(source)
            continue
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let dest = directory.appendingPathComponent(shortSourceName(source))
        try writeIfChanged(expandGenerableMacros(text), to: dest)
        rewritten.append(dest)
    }
    return rewritten
}

func expandGenerableMacros(_ text: String) -> String {
    let expanded = expandGenerable(text, parents: [])
    if expanded.extensions.isEmpty { return expanded.body }
    return expanded.body + "\n" + expanded.extensions
}

private struct GenerableExpansion {
    var body: String
    var extensions: String
}

private struct GenerableProperty {
    var name: String
    var type: String
    var description: String?
    var guides: [String]
}

private func expandGenerable(_ text: String, parents: [String]) -> GenerableExpansion {
    guard text.contains("@Generable") else { return GenerableExpansion(body: text, extensions: "") }
    var body = ""
    var extensions = ""
    var index = text.startIndex
    var depth = 0
    var typeStack: [(name: String, depth: Int)] = []
    var pendingType: String?
    while index < text.endIndex {
        if text[index] == "/" && text.index(after: index) < text.endIndex && text[text.index(after: index)] == "/" {
            let end = text[index...].firstIndex(of: "\n") ?? text.endIndex
            body.append(contentsOf: text[index..<end])
            index = end
            continue
        }
        if text[index] == "/" && text.index(after: index) < text.endIndex && text[text.index(after: index)] == "*" {
            let search = text.index(index, offsetBy: 2)
            let end = text.range(of: "*/", range: search..<text.endIndex)?.upperBound ?? text.endIndex
            body.append(contentsOf: text[index..<end])
            index = end
            continue
        }
        if text[index] == "\"" {
            let end = endOfStringLiteral(text, from: index)
            body.append(contentsOf: text[index..<end])
            index = end
            continue
        }
        if text[index...].hasPrefix("@Generable"), !identifierContinues(text, at: text.index(index, offsetBy: "@Generable".count)) {
            if let consumed = consumeGenerableType(text, from: index, parents: parents + typeStack.map(\.name)) {
                body.append(contentsOf: consumed.body)
                if !consumed.extensions.isEmpty {
                    if !extensions.isEmpty { extensions.append("\n") }
                    extensions.append(consumed.extensions)
                }
                index = consumed.end
                pendingType = nil
                continue
            }
        }
        if let name = typeDeclarationName(text, from: index) {
            pendingType = name.name
            let end = text.index(index, offsetBy: name.keywordCount)
            body.append(contentsOf: text[index..<end])
            index = end
            continue
        }
        if text[index] == "{" {
            depth += 1
            if let name = pendingType {
                typeStack.append((name, depth))
                pendingType = nil
            }
            body.append("{")
            index = text.index(after: index)
            continue
        }
        if text[index] == "}" {
            depth -= 1
            typeStack.removeAll { $0.depth > depth }
            body.append("}")
            index = text.index(after: index)
            continue
        }
        body.append(text[index])
        index = text.index(after: index)
    }
    return GenerableExpansion(body: body, extensions: extensions)
}

private struct ConsumedGenerable {
    var body: String
    var extensions: String
    var end: String.Index
}

private func consumeGenerableType(_ text: String, from start: String.Index, parents: [String]) -> ConsumedGenerable? {
    var index = text.index(start, offsetBy: "@Generable".count)
    index = skipPreviewSpace(text, from: index)
    if index < text.endIndex, text[index] == "(" {
        guard let after = skipBalancedDelimiters(text, from: index, open: "(", close: ")") else { return nil }
        index = skipPreviewSpace(text, from: after)
    }
    let modifiers: Set<String> = ["nonisolated", "public", "private", "internal", "fileprivate", "open", "final", "package"]
    var header = ""
    while let word = identifier(text, from: index), modifiers.contains(word) {
        header.append(word)
        index = text.index(index, offsetBy: word.count)
        let spaced = skipPreviewSpace(text, from: index)
        header.append(contentsOf: text[index..<spaced])
        index = spaced
    }
    guard text[index...].hasPrefix("struct") else { return nil }
    header.append("struct")
    index = text.index(index, offsetBy: "struct".count)
    let afterKeyword = skipPreviewSpace(text, from: index)
    header.append(contentsOf: text[index..<afterKeyword])
    index = afterKeyword
    guard let name = identifier(text, from: index) else { return nil }
    header.append(name)
    index = text.index(index, offsetBy: name.count)
    guard let open = text[index...].firstIndex(of: "{") else { return nil }
    let inheritance = String(text[index..<open])
    header.append(contentsOf: inheritance)
    guard let close = endOfBrace(text, from: open) else { return nil }
    let rawBody = String(text[text.index(after: open)..<close])
    let parsed = stripGuides(rawBody)
    let nested = expandGenerable(parsed.body, parents: parents + [name])
    let qualified = (parents + [name]).joined(separator: ".")
    let equatable = inheritanceClause(inheritance).contains("Equatable")
    let members = generableMembers(parsed.properties, equatable: equatable)
    let extensionText = generableExtension(qualified: qualified, properties: parsed.properties)
    var combined = nested.extensions
    if !combined.isEmpty { combined.append("\n") }
    combined.append(extensionText)
    let rewritten = header + "{\n" + nested.body + "\n" + members + "\n}"
    return ConsumedGenerable(body: rewritten, extensions: combined, end: text.index(after: close))
}

private func generableMembers(_ properties: [GenerableProperty], equatable: Bool) -> String {
    let fields = properties.map { property in
        "            FoundationModels.GenerationSchema.Property(\(propertyCall(property)))"
    }.joined(separator: ",\n")
    let adds = properties.map { "    addProperty(name: \"\($0.name)\", value: self.\($0.name))" }.joined(separator: "\n")
    let partials = properties.map { "    var \($0.name): \($0.type).PartiallyGenerated?" }.joined(separator: "\n")
    let reads = properties.map { "        self.\($0.name) = try content.value(forProperty: \"\($0.name)\")" }.joined(separator: "\n")
    let conformance = equatable
        ? "Identifiable, nonisolated FoundationModels.ConvertibleFromGeneratedContent, Equatable"
        : "Identifiable, nonisolated FoundationModels.ConvertibleFromGeneratedContent"
    return """
    nonisolated static var generationSchema: FoundationModels.GenerationSchema {
        FoundationModels.GenerationSchema(
            type: Self.self,
            properties: [
    \(fields)
            ]
        )
    }

    nonisolated var generatedContent: GeneratedContent {
        let explicitNil = false
        var properties = [(name: String, value: any ConvertibleToGeneratedContent)]()
    \(adds)
        return GeneratedContent(
            properties: properties,
            uniquingKeysWith: { _, second in
                second
            }
        )
        func addProperty(name: String, value: some Generable) {
          properties.append((name: name, value: value))
        }
        func addProperty(name: String, value: (some Generable)?) {
          if explicitNil || value != nil {
            properties.append((name: name, value: value))
          }
        }
    }

    nonisolated struct PartiallyGenerated: \(conformance) {
        var id: GenerationID
    \(partials)
        nonisolated init(_ content: FoundationModels.GeneratedContent) throws {
            self.id = content.id ?? GenerationID()
    \(reads)
        }
    }
    """
}

private func generableExtension(qualified: String, properties: [GenerableProperty]) -> String {
    let reads = properties.map { "        self.\($0.name) = try content.value(forProperty: \"\($0.name)\")" }.joined(separator: "\n")
    return """
    extension \(qualified): nonisolated FoundationModels.Generable {
        nonisolated init(_ content: FoundationModels.GeneratedContent) throws {
    \(reads)
        }
    }
    """
}

private func propertyCall(_ property: GenerableProperty) -> String {
    var parts = ["name: \"\(property.name)\""]
    if let description = property.description {
        parts.append("description: \(description)")
    }
    parts.append("type: \(property.type).self")
    if !property.guides.isEmpty {
        parts.append("guides: [\(property.guides.joined(separator: ", "))]")
    }
    return parts.joined(separator: ", ")
}

private func stripGuides(_ body: String) -> (body: String, properties: [GenerableProperty]) {
    var result = ""
    var properties: [GenerableProperty] = []
    var index = body.startIndex
    var depth = 0
    var pendingDescription: String?
    var pendingGuides: [String] = []
    while index < body.endIndex {
        if body[index] == "/" && body.index(after: index) < body.endIndex && body[body.index(after: index)] == "/" {
            let end = body[index...].firstIndex(of: "\n") ?? body.endIndex
            result.append(contentsOf: body[index..<end])
            index = end
            continue
        }
        if body[index] == "\"" {
            let end = endOfStringLiteral(body, from: index)
            result.append(contentsOf: body[index..<end])
            index = end
            continue
        }
        if body[index] == "{" {
            depth += 1
            result.append("{")
            index = body.index(after: index)
            continue
        }
        if body[index] == "}" {
            depth -= 1
            result.append("}")
            index = body.index(after: index)
            continue
        }
        if depth == 0, body[index...].hasPrefix("@Guide"), !identifierContinues(body, at: body.index(index, offsetBy: "@Guide".count)) {
            var cursor = body.index(index, offsetBy: "@Guide".count)
            cursor = skipPreviewSpace(body, from: cursor)
            if cursor < body.endIndex, body[cursor] == "(" {
                if let after = skipBalancedDelimiters(body, from: cursor, open: "(", close: ")") {
                    let inside = String(body[body.index(after: cursor)..<body.index(before: after)])
                    let parsed = guideArguments(inside)
                    pendingDescription = parsed.description
                    pendingGuides = parsed.guides
                    index = after
                    continue
                }
            }
            index = cursor
            continue
        }
        if depth == 0, let property = storedProperty(body, from: index) {
            properties.append(GenerableProperty(
                name: property.name,
                type: property.type,
                description: pendingDescription,
                guides: pendingGuides
            ))
            pendingDescription = nil
            pendingGuides = []
            result.append(contentsOf: body[index..<property.end])
            index = property.end
            continue
        }
        result.append(body[index])
        index = body.index(after: index)
    }
    return (result, properties)
}

private func storedProperty(_ text: String, from index: String.Index) -> (name: String, type: String, end: String.Index)? {
    let prefixes = ["let ", "var "]
    guard let prefix = prefixes.first(where: { text[index...].hasPrefix($0) }) else { return nil }
    if index > text.startIndex {
        let previous = text[text.index(before: index)]
        if previous.isLetter || previous.isNumber || previous == "_" { return nil }
    }
    var cursor = text.index(index, offsetBy: prefix.count)
    guard let name = identifier(text, from: cursor) else { return nil }
    cursor = text.index(cursor, offsetBy: name.count)
    cursor = skipPreviewSpace(text, from: cursor)
    guard cursor < text.endIndex, text[cursor] == ":" else { return nil }
    cursor = skipPreviewSpace(text, from: text.index(after: cursor))
    let typeStart = cursor
    var depth = 0
    while cursor < text.endIndex {
        let character = text[cursor]
        if character == "(" || character == "[" || character == "<" { depth += 1 }
        if character == ")" || character == "]" || character == ">" { depth -= 1 }
        if depth == 0 && (character == "=" || character == "{" || character == "\n" || character == "/") {
            break
        }
        cursor = text.index(after: cursor)
    }
    let type = text[typeStart..<cursor].trimmingCharacters(in: .whitespacesAndNewlines)
    guard !type.isEmpty, !type.contains("{") else { return nil }
    return (name, type, cursor)
}

private func guideArguments(_ text: String) -> (description: String?, guides: [String]) {
    var description: String?
    var guides: [String] = []
    for argument in splitTopLevel(text, separator: ",") {
        let trimmed = argument.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { continue }
        if trimmed.hasPrefix("description:") {
            description = trimmed.dropFirst("description:".count).trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            guides.append(trimmed)
        }
    }
    return (description, guides)
}

private func splitTopLevel(_ text: String, separator: Character) -> [String] {
    var parts: [String] = []
    var current = ""
    var depth = 0
    var index = text.startIndex
    while index < text.endIndex {
        if text[index] == "\"" {
            let end = endOfStringLiteral(text, from: index)
            current.append(contentsOf: text[index..<end])
            index = end
            continue
        }
        let character = text[index]
        if character == "(" || character == "[" || character == "{" || character == "<" { depth += 1 }
        if character == ")" || character == "]" || character == "}" || character == ">" { depth -= 1 }
        if character == separator && depth == 0 {
            parts.append(current)
            current = ""
        } else {
            current.append(character)
        }
        index = text.index(after: index)
    }
    parts.append(current)
    return parts
}

private func inheritanceClause(_ headerTail: String) -> [String] {
    guard let colon = headerTail.firstIndex(of: ":") else { return [] }
    return headerTail[headerTail.index(after: colon)...]
        .split(separator: ",")
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
}

private struct TypeKeyword {
    var name: String
    var keywordCount: Int
}

private func typeDeclarationName(_ text: String, from index: String.Index) -> TypeKeyword? {
    let keywords = ["struct", "enum", "class", "actor"]
    guard let keyword = keywords.first(where: { text[index...].hasPrefix($0) }) else { return nil }
    let after = text.index(index, offsetBy: keyword.count)
    if index > text.startIndex {
        let previous = text[text.index(before: index)]
        if previous.isLetter || previous.isNumber || previous == "_" { return nil }
    }
    guard after < text.endIndex, text[after].isWhitespace else { return nil }
    let nameStart = skipPreviewSpace(text, from: after)
    guard let name = identifier(text, from: nameStart) else { return nil }
    return TypeKeyword(name: name, keywordCount: keyword.count)
}

private func identifier(_ text: String, from index: String.Index) -> String? {
    guard index < text.endIndex, text[index].isLetter || text[index] == "_" else { return nil }
    var cursor = text.index(after: index)
    while cursor < text.endIndex, text[cursor].isLetter || text[cursor].isNumber || text[cursor] == "_" {
        cursor = text.index(after: cursor)
    }
    return String(text[index..<cursor])
}

private func identifierContinues(_ text: String, at index: String.Index) -> Bool {
    guard index < text.endIndex else { return false }
    return text[index].isLetter || text[index].isNumber || text[index] == "_"
}

private func endOfBrace(_ text: String, from open: String.Index) -> String.Index? {
    guard let after = skipBalancedDelimiters(text, from: open, open: "{", close: "}") else { return nil }
    return text.index(before: after)
}

private func skipBalancedDelimiters(_ text: String, from open: String.Index, open openChar: Character, close closeChar: Character) -> String.Index? {
    var depth = 0
    var index = open
    while index < text.endIndex {
        if text[index] == "/" && text.index(after: index) < text.endIndex && text[text.index(after: index)] == "/" {
            index = text[index...].firstIndex(of: "\n") ?? text.endIndex
            continue
        }
        if text[index] == "\"" {
            index = endOfStringLiteral(text, from: index)
            continue
        }
        if text[index] == openChar { depth += 1 }
        if text[index] == closeChar {
            depth -= 1
            if depth == 0 { return text.index(after: index) }
        }
        index = text.index(after: index)
    }
    return nil
}

private func endOfStringLiteral(_ text: String, from index: String.Index) -> String.Index {
    var cursor = text.index(after: index)
    while cursor < text.endIndex {
        if text[cursor] == "\\" {
            cursor = text.index(after: cursor)
            if cursor < text.endIndex { cursor = text.index(after: cursor) }
            continue
        }
        if text[cursor] == "\"" { return text.index(after: cursor) }
        if text[cursor] == "\n" { return cursor }
        cursor = text.index(after: cursor)
    }
    return text.endIndex
}

private let entryKeyProtocols = [
    "EnvironmentValues": "EnvironmentKey",
    "Transaction": "TransactionKey",
    "ContainerValues": "ContainerValueKey",
    "FocusedValues": "FocusedValueKey",
]

/// `@Entry` is implemented by the SwiftUIMacros plugin. That plugin is a Mac
/// compiler binary, so the on-device compiler cannot load it. Expand the
/// property into the key type the macro would have emitted.
private func sourcesWithoutEntryMacros(_ sources: [URL], context: DriverContext) throws -> [URL] {
    var rewritten: [URL] = []
    let directory = context.workRoot.appendingPathComponent("EntryExpanded")
    for source in sources {
        guard let text = try? String(contentsOf: source, encoding: .utf8), text.contains("@Entry") else {
            rewritten.append(source)
            continue
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let dest = directory.appendingPathComponent(shortSourceName(source))
        try writeIfChanged(expandEntryMacros(text), to: dest)
        rewritten.append(dest)
    }
    return rewritten
}

private func expandEntryMacros(_ text: String) -> String {
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    var depth = 0
    struct Frame { var bodyDepth: Int; var key: String }
    var frames: [Frame] = []
    var pendingKey: String?
    var result: [String] = []
    var keysAtDepth: [Int: [String]] = [:]
    for line in lines {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if pendingKey == nil, let name = entryExtensionName(trimmed), let key = entryKeyProtocols[name] {
            pendingKey = key
        }
        if let key = pendingKey, line.contains("{") {
            frames.append(Frame(bodyDepth: depth + 1, key: key))
            pendingKey = nil
        }
        if let entry = entryProperty(trimmed), let frame = frames.last, depth == frame.bodyDepth {
            let indent = String(line.prefix { $0 == " " || $0 == "\t" })
            let keyType = "__Key_\(entry.name)"
            result.append("""
            \(indent)var \(entry.name): \(entry.type) {
            \(indent)    get { self[\(keyType).self] }
            \(indent)    set { self[\(keyType).self] = newValue }
            \(indent)}
            """)
            keysAtDepth[frame.bodyDepth - 1, default: []].append("""
            private struct \(keyType): \(frame.key) {
                static let defaultValue: \(entry.type) = \(entry.defaultValue)
            }
            """)
        } else {
            result.append(line)
        }
        let delta = line.reduce(0) { count, character in
            if character == "{" { return count + 1 }
            if character == "}" { return count - 1 }
            return count
        }
        let newDepth = depth + delta
        if newDepth < depth {
            var closed = depth
            while closed > newDepth {
                closed -= 1
                if let structs = keysAtDepth.removeValue(forKey: closed) {
                    result.append(contentsOf: structs)
                }
            }
            frames.removeAll { $0.bodyDepth > newDepth }
        }
        depth = newDepth
    }
    return result.joined(separator: "\n")
}

private func entryExtensionName(_ line: String) -> String? {
    guard line.hasPrefix("extension ") else { return nil }
    var name = line.dropFirst("extension ".count)
    if let brace = name.firstIndex(of: "{") { name = name[..<brace] }
    if let colon = name.firstIndex(of: ":") { name = name[..<colon] }
    let trimmed = name.trimmingCharacters(in: .whitespaces)
    return trimmed.split(separator: ".").last.map(String.init)
}

private func entryProperty(_ line: String) -> (name: String, type: String, defaultValue: String)? {
    guard line.hasPrefix("@Entry") else { return nil }
    let rest = line.dropFirst("@Entry".count).trimmingCharacters(in: .whitespaces)
    guard rest.hasPrefix("var ") else { return nil }
    let declaration = rest.dropFirst("var ".count)
    guard let colon = declaration.firstIndex(of: ":"),
          let equals = declaration.firstIndex(of: "="),
          colon < equals else { return nil }
    let name = declaration[..<colon].trimmingCharacters(in: .whitespaces)
    let type = declaration[declaration.index(after: colon)..<equals].trimmingCharacters(in: .whitespaces)
    let value = declaration[declaration.index(after: equals)...].trimmingCharacters(in: .whitespaces)
    guard !name.isEmpty, !type.isEmpty, !value.isEmpty else { return nil }
    return (String(name), type, value)
}

private func shortSourceName(_ source: URL) -> String {
    var hash: UInt64 = 1469598103934665603
    for byte in normalizingDataContainerUUID(source.path).utf8 {
        hash ^= UInt64(byte)
        hash &*= 1099511628211
    }
    return String(format: "%016llx", hash) + "-" + source.lastPathComponent
}

func writeIfChanged(_ text: String, to url: URL) throws {
    let bytes = Data(text.utf8)
    if let existing = try? Data(contentsOf: url), existing == bytes {
        return
    }
    try bytes.write(to: url, options: .atomic)
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
        let slug = normalizingDataContainerUUID(source.path).replacingOccurrences(of: "/", with: "_")
        let dest = directory.appendingPathComponent(slug)
        try writeIfChanged(stripPreviewBlocks(text), to: dest)
        rewritten.append(dest)
    }
    return rewritten
}

func stripPreviewBlocks(_ text: String) -> String {
    var result = ""
    var index = text.startIndex
    while let range = text.range(of: "#Preview", range: index..<text.endIndex) {
        let lineStart = text[..<range.lowerBound].lastIndex(of: "\n").map { text.index(after: $0) } ?? text.startIndex
        if text[lineStart..<range.lowerBound].contains("//") {
            result.append(contentsOf: text[index..<range.upperBound])
            index = range.upperBound
            continue
        }
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
        index = endOfTrailingPreviewClosures(text, from: index)
    }
    result.append(contentsOf: text[index...])
    return result
}

/// Widget previews are `#Preview(...) { widget } timeline: { entries }`.
/// The first brace is only the widget. The labeled closure is still the macro.
private func endOfTrailingPreviewClosures(_ text: String, from start: String.Index) -> String.Index {
    var index = start
    while true {
        let saved = index
        index = skipPreviewSpace(text, from: index)
        guard let nameEnd = previewIdentifierEnd(text, from: index) else { return saved }
        var cursor = skipPreviewSpace(text, from: nameEnd)
        guard cursor < text.endIndex, text[cursor] == ":" else { return saved }
        cursor = skipPreviewSpace(text, from: text.index(after: cursor))
        guard cursor < text.endIndex, text[cursor] == "{" else { return saved }
        var depth = 0
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
        if !closed { return saved }
    }
}

private func skipPreviewSpace(_ text: String, from index: String.Index) -> String.Index {
    var cursor = index
    while cursor < text.endIndex, text[cursor] == " " || text[cursor] == "\n" || text[cursor] == "\t" || text[cursor] == "\r" {
        cursor = text.index(after: cursor)
    }
    return cursor
}

private func previewIdentifierEnd(_ text: String, from index: String.Index) -> String.Index? {
    guard index < text.endIndex, text[index].isLetter || text[index] == "_" else { return nil }
    var cursor = text.index(after: index)
    while cursor < text.endIndex, text[cursor].isLetter || text[cursor].isNumber || text[cursor] == "_" {
        cursor = text.index(after: cursor)
    }
    return cursor
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
        let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        // skipDescendants() on a file also skips the next directory. Excluded
        // README.md files were dropping EpoxyCore/Views on the phone.
        if isDirectory && (skip.contains(url.lastPathComponent) || isExcluded(relative, by: excluding)) {
            enumerator.skipDescendants()
            continue
        }
        if isExcluded(relative, by: excluding) { continue }
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
        queue.append(contentsOf: found.declaration.dependencies)
        guard !unit.sources.isEmpty || !unit.clang.isEmpty || !unit.headerPaths.isEmpty else { continue }
        units.append(unit)
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
        linkDependencies: declaration.dependencies,
        linkLibraries: declaration.linkLibraries,
        linkFrameworks: declaration.linkFrameworks,
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

func shouldEmitPackageModuleMap(moduleName: String, headers: [URL], binaryModules: Set<String>) -> Bool {
    if binaryModules.contains(moduleName), !headers.isEmpty, headers.allSatisfy({ $0.lastPathComponent == "dummy.h" }) {
        return false
    }
    return true
}

private func binaryModuleNames(in searchPaths: [String]) -> Set<String> {
    var names = Set<String>()
    for path in searchPaths {
        guard let children = try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: path), includingPropertiesForKeys: nil) else { continue }
        for child in children where child.pathExtension == "framework" {
            names.insert(child.deletingPathExtension().lastPathComponent)
        }
    }
    return names
}

private func writePackageModules(_ units: [PackageUnit], into root: URL, binaryModules: Set<String>) -> [String] {
    var maps: [String] = []
    for unit in units {
        let headers = unit.publicHeaders.isEmpty ? (unit.umbrellaHeader.map { [$0] } ?? []) : unit.publicHeaders
        guard !headers.isEmpty else { continue }
        let moduleName = sanitizedModule(unit.name)
        guard shouldEmitPackageModuleMap(moduleName: moduleName, headers: headers, binaryModules: binaryModules) else { continue }
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
    var linkLibraries: [String]
    var linkFrameworks: [String]
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
    var depth = 0
    while index < lines.count {
        let line = lines[index].trimmingCharacters(in: .whitespaces)
        let depthBefore = depth
        if depthBefore == 1 && line.hasPrefix(".library(") {
            let block = targetBlock(lines, from: index)
            let window = block.joined(separator: "\n")
            if let name = firstMatch(#"name:\s*"([^"]+)""#, in: window),
               let target = firstMatch(#"targets:\s*\[\s*"([^"]+)""#, in: window) {
                products[name] = target
            }
        }
        let isBinary = line.contains(".binaryTarget")
        let isTest = line.contains(".testTarget")
        let isTarget = depthBefore <= 1 && !isBinary && (line.contains(".target(") || isTest)
        if isTarget {
            let block = targetBlock(lines, from: index)
            if let declaration = declaration(in: block, isTest: isTest, constants: constants) {
                declarations.append(declaration)
            }
        }
        depth += parenDelta(lines[index])
        index += 1
    }
    let toolsMajor = Int(firstMatch(#"swift-tools-version:\s*([0-9]+)"#, in: text) ?? "") ?? 5
    return PackageManifest(declarations: declarations, products: products, toolsMajor: toolsMajor)
}

private func targetBlock(_ lines: [String], from index: Int) -> [String] {
    var block = [lines[index]]
    var depth = parenDelta(lines[index])
    if depth <= 0 { return block }
    var cursor = index + 1
    while cursor < lines.count && cursor < index + 2000 {
        let line = lines[cursor]
        depth += parenDelta(line)
        block.append(line)
        cursor += 1
        if depth <= 0 { break }
    }
    return block
}

private func parenDelta(_ line: String) -> Int {
    line.filter { $0 == "(" }.count - line.filter { $0 == ")" }.count
}

private func declaration(in block: [String], isTest: Bool, constants: [String: String]) -> PackageDeclaration? {
    let window = block.joined(separator: "\n")
    guard let name = firstMatch(#"name:\s*"([^"]+)""#, in: window) else { return nil }
    var sourceEntries: [String] = []
    var excludes: [String] = []
    var defines: [String] = []
    var linkLibraries: [String] = []
    var linkFrameworks: [String] = []
    var collectingSources = false
    var collectingExcludes = false
    for raw in block {
        let line = raw.trimmingCharacters(in: .whitespaces)
        if linksOnIOS(line), let library = firstMatch(#"linkedLibrary\(\s*"([^"]+)""#, in: line) {
            linkLibraries.append(library)
        }
        if linksOnIOS(line), let framework = firstMatch(#"linkedFramework\(\s*"([^"]+)""#, in: line) {
            linkFrameworks.append(framework)
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
        dependencies: dependencyNames(in: block),
        sourceEntries: sourceEntries,
        excludes: excludes,
        publicHeadersPath: firstMatch(#"publicHeadersPath:\s*"([^"]+)""#, in: window),
        headerSearchPaths: allMatches(#"headerSearchPath\(\s*"([^"]+)""#, in: window),
        defines: defines,
        linkLibraries: linkLibraries,
        linkFrameworks: linkFrameworks
    )
}

/// Quoted names on the `dependencies:` line and on the closing `],` line are
/// dependencies. A line that is only `"Name",` was already collected.
private func dependencyNames(in block: [String]) -> [String] {
    var names: [String] = []
    var collecting = false
    var depth = 0
    var callDepth = 0
    for raw in block {
        let line = raw.trimmingCharacters(in: .whitespaces)
        if !collecting {
            guard line.range(of: #"(^|[^\w])dependencies\s*:"#, options: .regularExpression) != nil else { continue }
            collecting = true
        }
        let startsCall = line.contains(".product(") || line.contains(".target(")
        if callDepth > 0 || startsCall {
            if let name = firstMatch(#"name:\s*"([^"]+)""#, in: line) {
                names.append(name)
            }
            callDepth += line.filter { $0 == "(" }.count - line.filter { $0 == ")" }.count
            if callDepth < 0 { callDepth = 0 }
        } else {
            names.append(contentsOf: allMatches(#""([^"]+)""#, in: line))
        }
        depth += line.filter { $0 == "[" }.count - line.filter { $0 == "]" }.count
        if depth <= 0 && line.contains("]") {
            collecting = false
            callDepth = 0
        }
    }
    return names
}

private func linksOnIOS(_ line: String) -> Bool {
    guard line.contains(".when(platforms:") else { return true }
    return line.contains(".iOS")
}

private func frameworkNames(in searchPaths: [String]) -> Set<String> {
    var names = Set<String>()
    for path in searchPaths {
        guard let children = try? FileManager.default.contentsOfDirectory(atPath: path) else { continue }
        for child in children where child.hasSuffix(".framework") {
            names.insert(String(child.dropLast(".framework".count)))
        }
    }
    return names
}

private func packageLinkExtras(from packages: [PackageUnit], frameworksOnDisk: Set<String>, alreadyLinked: Set<String>) -> (frameworks: [String], libraries: [String]) {
    var frameworks: [String] = []
    var libraries: [String] = []
    var seenFrameworks = alreadyLinked
    var seenLibraries = Set<String>()
    for package in packages {
        for library in package.linkLibraries where seenLibraries.insert(library).inserted {
            libraries.append(library)
        }
        for framework in package.linkFrameworks where seenFrameworks.insert(framework).inserted {
            frameworks.append(framework)
        }
        for dependency in package.linkDependencies where frameworksOnDisk.contains(dependency) && seenFrameworks.insert(dependency).inserted {
            frameworks.append(dependency)
        }
    }
    return (frameworks, libraries)
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
            if let name = importedModuleName(on: line) {
                names.insert(name)
            }
        }
    }
    return names
}

/// `import MapKit`, `@preconcurrency import MapKit`, and `public import MapKit`
/// all name the same module. Attribute and access-level prefixes have to be
/// stripped or a cross-import overlay is skipped for that file.
private func importedModuleName(on line: some StringProtocol) -> String? {
    var rest = line.trimmingCharacters(in: .whitespaces)
    if rest.hasPrefix("//") || rest.hasPrefix("/*") { return nil }
    while rest.hasPrefix("@") || accessLevelPrefix(rest) != nil {
        if rest.hasPrefix("@") {
            if let open = rest.firstIndex(of: "("), !rest[..<open].contains(where: { $0 == " " || $0 == "\t" }) {
                guard let close = rest[open...].firstIndex(of: ")") else { return nil }
                rest = rest[rest.index(after: close)...].trimmingCharacters(in: .whitespaces)
            } else if let space = rest.firstIndex(where: { $0 == " " || $0 == "\t" }) {
                rest = rest[rest.index(after: space)...].trimmingCharacters(in: .whitespaces)
            } else {
                return nil
            }
            continue
        }
        if let prefix = accessLevelPrefix(rest) {
            rest = rest.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
            continue
        }
        break
    }
    guard rest.hasPrefix("import ") || rest.hasPrefix("import\t") else { return nil }
    let after = rest.dropFirst("import".count).trimmingCharacters(in: .whitespaces)
    guard let token = after.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == ";" }).first else { return nil }
    if token == "class" || token == "struct" || token == "enum" || token == "func" || token == "typealias" || token == "let" || token == "var" {
        return nil
    }
    let head = token.split(separator: ".").first.map(String.init) ?? String(token)
    return head.isEmpty ? nil : head
}

private func accessLevelPrefix(_ rest: some StringProtocol) -> String? {
    for prefix in ["public", "internal", "fileprivate", "private", "package", "open"] {
        guard rest.hasPrefix(prefix) else { continue }
        let next = rest.dropFirst(prefix.count)
        if next.first == " " || next.first == "\t" { return prefix }
    }
    return nil
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

private func sanitizedModule(_ name: String) -> String {
    let scalars = name.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : "_" }
    let joined = String(scalars)
    return joined.isEmpty ? "App" : joined
}
