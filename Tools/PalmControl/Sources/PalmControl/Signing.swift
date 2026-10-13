// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

public struct SigningInputs: Equatable {
    public var bundleIdentifier: String
    public var entitlementsPath: String?
    public var infoPlistPath: String?

    public init(bundleIdentifier: String, entitlementsPath: String?, infoPlistPath: String?) {
        self.bundleIdentifier = bundleIdentifier
        self.entitlementsPath = entitlementsPath
        self.infoPlistPath = infoPlistPath
    }
}

public struct ProvisioningProfileSummary: Equatable {
    public var name: String
    public var applicationIdentifier: String
    public var expires: Date?

    public init(name: String, applicationIdentifier: String, expires: Date? = nil) {
        self.name = name
        self.applicationIdentifier = applicationIdentifier
        self.expires = expires
    }

    /// Wildcard team profiles cannot carry HealthKit or the app's App ID.
    public var isWildcard: Bool {
        applicationIdentifier.hasSuffix(".*")
    }

    public var isAppStore: Bool {
        name.range(of: "store", options: .caseInsensitive) != nil
    }

    public var isExpired: Bool {
        guard let expires else { return false }
        return expires < Date()
    }

    public func matches(bundleIdentifier: String) -> Bool {
        applicationIdentifier == bundleIdentifier
            || applicationIdentifier.hasSuffix("." + bundleIdentifier)
    }
}

/// Prefer the development profile for this bundle id. Skip App Store, `*`, and expired profiles.
public func chooseDevelopmentProfile(
    bundleIdentifier: String,
    profiles: [ProvisioningProfileSummary]
) -> ProvisioningProfileSummary? {
    profiles
        .filter { profile in
            !profile.isWildcard && !profile.isAppStore && !profile.isExpired && profile.matches(bundleIdentifier: bundleIdentifier)
        }
        .max { ($0.expires ?? .distantPast) < ($1.expires ?? .distantPast) }
}

public func expandedInfoPlist(
    _ values: [String: PlistValue],
    variables: [String: String]
) -> [String: PlistValue] {
    values.mapValues { expandPlistVariables($0, variables: variables) }
}

public func mergedDictionaries(
    _ base: [String: PlistValue],
    overlay: [String: PlistValue]?
) -> [String: PlistValue] {
    guard let overlay else { return base }
    var merged = base
    for (key, value) in overlay {
        merged[key] = value
    }
    return merged
}

public func teamCodesignArguments(identity: String, binary: String, entitlements: String?) -> [String] {
    var arguments = ["-f", "-s", identity, "--timestamp=none", "--generate-entitlement-der"]
    if let entitlements {
        arguments.append(contentsOf: ["--entitlements", entitlements])
    }
    arguments.append(binary)
    return arguments
}

public let defaultDevelopmentIdentity = "Apple Development: Isaac Yeang (AT4W55YC44)"

public func applySigning(_ request: ControlRequest, to plan: inout BuildPlan) {
    plan.infoPlist = mergedDictionaries(plan.infoPlist, overlay: request.infoPlist)
    if let entitlements = request.signingEntitlements {
        plan.entitlements = entitlements
        plan.entitlementKeys = entitlements.keys.sorted()
    }
    plan.provisioningProfile = request.provisioningProfile
    plan.signingProfileIdentifier = request.signingProfileIdentifier
}

public func provisioningProfileSummary(from plist: [String: Any]) -> ProvisioningProfileSummary? {
    guard let name = plist["Name"] as? String,
          let entitlements = plist["Entitlements"] as? [String: Any],
          let applicationIdentifier = entitlements["application-identifier"] as? String else {
        return nil
    }
    return ProvisioningProfileSummary(
        name: name,
        applicationIdentifier: applicationIdentifier,
        expires: plist["ExpirationDate"] as? Date
    )
}

public func entitlementsDictionary(from plist: [String: Any]) -> [String: PlistValue] {
    guard let entitlements = plist["Entitlements"] as? [String: Any] else { return [:] }
    return entitlements.mapValues(PlistValue.init(any:))
}

public struct LoadedProvisioningProfile {
    public var summary: ProvisioningProfileSummary
    public var data: Data
    public var entitlements: [String: PlistValue]

    public init(summary: ProvisioningProfileSummary, data: Data, entitlements: [String: PlistValue]) {
        self.summary = summary
        self.data = data
        self.entitlements = entitlements
    }
}

#if os(macOS)
public func loadProvisioningProfiles(in directory: URL = defaultProvisioningProfileDirectory) -> [LoadedProvisioningProfile] {
    let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
    return urls.compactMap { url in
        guard url.pathExtension == "mobileprovision" else { return nil }
        guard let data = try? Data(contentsOf: url),
              let plist = decodeProvisioningProfile(data),
              let summary = provisioningProfileSummary(from: plist) else { return nil }
        return LoadedProvisioningProfile(summary: summary, data: data, entitlements: entitlementsDictionary(from: plist))
    }
}

public let defaultProvisioningProfileDirectory = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Developer/Xcode/UserData/Provisioning Profiles")

public func decodeProvisioningProfile(_ data: Data) -> [String: Any]? {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("palm-profile-\(UUID().uuidString).mobileprovision")
    do {
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["cms", "-D", "-i", url.path]
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let decoded = pipe.fileHandleForReading.readDataToEndOfFile()
        let object = try PropertyListSerialization.propertyList(from: decoded, options: [], format: nil)
        return object as? [String: Any]
    } catch {
        return nil
    }
}
#endif
