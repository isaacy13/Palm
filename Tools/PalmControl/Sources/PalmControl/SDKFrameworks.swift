// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// Frameworks GuideAI imports that a Nyxian SDK slice has to expose,
/// plus the entitlements the signed launch needs.
public enum SDKFrameworks {
    public static let guideAIGaps = [
        "MapKit",
        "WeatherKit",
        "HealthKit",
        "EventKit",
        "CoreLocation",
        "ActivityKit",
        "WidgetKit",
        "CarPlay",
        "Messages",
        "WatchConnectivity",
    ]

    /// Imported names that are not passed to the linker as `-framework`.
    public static let notLinked: Set<String> = [
        "Foundation",
        "Combine",
        "os",
        "Darwin",
        "simd",
        "Synchronization",
        "Testing",
        "XCTest",
        "PackageDescription",
        "CoreFoundation",
        "Swift",
    ]

    public static func linkable(_ imported: Set<String>) -> [String] {
        imported
            .filter { !notLinked.contains($0) }
            .filter { $0.first?.isUppercase == true }
            .sorted()
    }

    public static func isPresent(named name: String, sdkRoot: URL) -> Bool {
        let fileManager = FileManager.default
        let candidates = [
            sdkRoot.appendingPathComponent("System/Library/Frameworks/\(name).framework"),
            sdkRoot.appendingPathComponent("System/Library/Frameworks/\(name).framework/Modules/\(name).swiftmodule"),
            sdkRoot.appendingPathComponent("usr/lib/swift/iphoneos/\(name).swiftmodule"),
        ]
        return candidates.contains { fileManager.fileExists(atPath: $0.path) }
    }

    public static func missing(named names: [String], sdkRoot: URL) -> [String] {
        names.filter { !isPresent(named: $0, sdkRoot: sdkRoot) }
    }

    /// Point clang at a header the on-device SDK already has, under an extra
    /// framework search path. Does not copy Apple SDK text into the tree.
    public static func writeOverlays(for names: [String], sdkRoot: URL, overlayRoot: URL) throws -> [String] {
        let fileManager = FileManager.default
        var written: [String] = []
        for name in names {
            guard let header = umbrellaHeader(named: name, sdkRoot: sdkRoot) else { continue }
            let framework = overlayRoot.appendingPathComponent("\(name).framework")
            let modules = framework.appendingPathComponent("Modules")
            try fileManager.createDirectory(at: modules, withIntermediateDirectories: true)
            let moduleMap = """
            framework module \(name) [system] {
              header "\(header.path)"
              export *
              link framework "\(name)"
            }
            """
            try moduleMap.write(to: modules.appendingPathComponent("module.modulemap"), atomically: true, encoding: .utf8)
            written.append(name)
        }
        return written.sorted()
    }

    private static func umbrellaHeader(named name: String, sdkRoot: URL) -> URL? {
        let candidates = [
            sdkRoot.appendingPathComponent("System/Library/Frameworks/\(name).framework/Headers/\(name).h"),
            sdkRoot.appendingPathComponent("\(name).framework/Headers/\(name).h"),
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }
}

/// Swift Testing for iOS arm64. Xcode ships it under the iPhoneOS platform,
/// not in `usr/lib/swift/iphoneos`. The on-device resource dir is `Documents/swift`,
/// and swiftc looks in `<resource-dir>/iphoneos` plus any `-I` path for
/// `Testing.swiftmodule`.
public enum SwiftTestingModule {
    public static let slices = [
        "arm64-apple-ios.swiftinterface",
        "arm64-apple-ios.swiftdoc",
        "arm64e-apple-ios.swiftinterface",
        "arm64e-apple-ios.swiftdoc",
    ]

    public static func searchDirectory(swiftResourceDir: URL) -> URL {
        swiftResourceDir.appendingPathComponent("iphoneos")
    }

    public static func moduleURL(developerDir: URL) -> URL {
        developerDir.appendingPathComponent(
            "Platforms/iPhoneOS.platform/Developer/Library/Frameworks/Testing.framework/Modules/Testing.swiftmodule"
        )
    }

    /// Copy the arm64 iOS interface into the Swift resource dir. Skips macOS plugins.
    @discardableResult
    public static func stage(into swiftResourceDir: URL) throws -> URL {
        let search = searchDirectory(swiftResourceDir: swiftResourceDir)
        let destination = search.appendingPathComponent("Testing.swiftmodule")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let marker = destination.appendingPathComponent("arm64-apple-ios.swiftinterface")
        if FileManager.default.fileExists(atPath: marker.path) {
            return search
        }
        guard let source = installedModules().first(where: {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("arm64-apple-ios.swiftinterface").path)
        }) else {
            return search
        }
        for name in slices where !name.contains("SwiftUIMacros") {
            let from = source.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: from.path) else { continue }
            try FileManager.default.copyItem(at: from, to: destination.appendingPathComponent(name))
        }
        return search
    }

    private static func installedModules() -> [URL] {
        var directories: [String] = []
        if let developer = ProcessInfo.processInfo.environment["DEVELOPER_DIR"], !developer.isEmpty {
            directories.append(developer)
        }
        directories.append("/var/db/xcode_select_link")
        directories.append("/Applications/Xcode-beta.app/Contents/Developer")
        directories.append("/Applications/Xcode.app/Contents/Developer")
        var modules = directories.map { moduleURL(developerDir: URL(fileURLWithPath: $0)) }
        modules.append(Bundle.main.bundleURL.appendingPathComponent("swift/iphoneos/Testing.swiftmodule"))
        return modules
    }
}

public enum PlistValue: Codable, Equatable {
    case string(String)
    case bool(Bool)
    case number(Double)
    case array([PlistValue])
    case dictionary([String: PlistValue])

    public var propertyListObject: Any {
        switch self {
        case .string(let value):
            return value
        case .bool(let value):
            return value
        case .number(let value):
            return value
        case .array(let values):
            return values.map(\.propertyListObject)
        case .dictionary(let values):
            return values.mapValues(\.propertyListObject)
        }
    }

    public static func read(from url: URL) throws -> [String: PlistValue] {
        let data = try Data(contentsOf: url)
        let object = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        guard let dictionary = object as? [String: Any] else {
            throw ControlError.channel("entitlements plist is not a dictionary")
        }
        return dictionary.mapValues(PlistValue.init(any:))
    }

    init(any value: Any) {
        switch value {
        case let string as String:
            self = .string(string)
        case let bool as Bool:
            self = .bool(bool)
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else {
                self = .number(number.doubleValue)
            }
        case let array as [Any]:
            self = .array(array.map(PlistValue.init(any:)))
        case let dictionary as [String: Any]:
            self = .dictionary(dictionary.mapValues(PlistValue.init(any:)))
        default:
            self = .string(String(describing: value))
        }
    }
}
