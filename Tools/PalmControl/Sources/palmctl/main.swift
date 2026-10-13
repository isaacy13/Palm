// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import PalmControl

private func usage() -> Never {
    let text = """
    usage: palmctl [--host HOST] [--port PORT] <build|build-and-run|build-run-and-tests> \\
        --branch BRANCH --project PATH --target NAME [--repository URL] [--ui ACTION:NAME] \\
        [--identity NAME] [--profile PATH] [--entitlements PATH] [--info-plist PATH]

    build stops after compile, link, and sign.
    build-and-run also launches.
    build-run-and-tests launches, then the Mac runs the --ui checks.
    On-device test targets are not compiled. Swift Testing macros ship only as a macOS plugin.
    Quickstart: Tools/PalmControl/README.md
    UI checks of a guest window need PALM_HOST_BUNDLE_ID and PALM_DEVICE_UDID.
    """
    FileHandle.standardError.write(Data((text + "\n").utf8))
    exit(2)
}

var host = "127.0.0.1"
var port: UInt16 = 8741
var args = Array(CommandLine.arguments.dropFirst())
func take(_ name: String) -> String? {
    guard let index = args.firstIndex(of: name), index + 1 < args.count else { return nil }
    let value = args[index + 1]
    args.removeSubrange(index...index + 1)
    return value
}

if let value = take("--host") { host = value }
if let value = take("--port"), let parsed = UInt16(value) { port = parsed }
let branch = take("--branch")
let project = take("--project")
let target = take("--target")
let repository = take("--repository")
let identityFlag = take("--identity")
let profileFlag = take("--profile")
let entitlementsFlag = take("--entitlements")
let infoPlistFlag = take("--info-plist")
var ui: [UICheck] = []
while let raw = take("--ui") {
    let parts = raw.split(separator: ":", maxSplits: 1).map(String.init)
    guard parts.count == 2 else { usage() }
    ui.append(UICheck(name: parts[1], action: parts[0]))
}
guard args.count == 1, let branch, let project, let target,
      let kind = ControlRequestKind(rawValue: args[0]) else { usage() }

let signing = resolveSigning(
    project: project,
    target: target,
    identity: identityFlag,
    profile: profileFlag,
    entitlements: entitlementsFlag,
    infoPlist: infoPlistFlag
)
let request = ControlRequest(
    kind: kind,
    branch: branch,
    repository: repository,
    project: project,
    target: target,
    tests: [],
    ui: ui,
    signingIdentity: signing.identity,
    provisioningProfile: signing.profile,
    signingProfileIdentifier: signing.profileIdentifier,
    signingEntitlements: signing.entitlements,
    infoPlist: signing.infoPlist
)
if let identifier = signing.profileIdentifier {
    FileHandle.standardError.write(Data("profile \(identifier)\n".utf8))
} else {
    FileHandle.standardError.write(Data("no development profile matched this bundle id\n".utf8))
}

func localProject(_ path: String) -> URL? {
    let direct = URL(fileURLWithPath: path)
    let guide = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("src/GuideAI")
        .appendingPathComponent(path)
    return [direct, guide].first { FileManager.default.fileExists(atPath: $0.path) }
}

func resolveSigning(project: String, target: String, identity: String?, profile: String?, entitlements: String?, infoPlist: String?) -> (identity: String, profile: Data?, profileIdentifier: String?, entitlements: [String: PlistValue]?, infoPlist: [String: PlistValue]?) {
    let chosenIdentity = identity ?? defaultDevelopmentIdentity
    var inputs: SigningInputs?
    if let projectURL = localProject(project) {
        inputs = try? ProjectDriver().signingInputs(project: projectURL, target: target)
    }
    let entitlementsURL = entitlements.map { URL(fileURLWithPath: $0) }
        ?? inputs?.entitlementsPath.map { URL(fileURLWithPath: $0) }
    let projectEntitlements = entitlementsURL.flatMap { try? PlistValue.read(from: $0) }
    // The driver already merges INFOPLIST_FILE with INFOPLIST_KEY_* and expands $(...).
    // Sending that file again would put the raw tokens back. --info-plist is an overlay.
    let info = infoPlist.flatMap { path -> [String: PlistValue]? in
        guard let values = try? PlistValue.read(from: URL(fileURLWithPath: path)) else { return nil }
        var variables = ["PRODUCT_MODULE_NAME": target, "TARGET_NAME": target]
        if let bundle = inputs?.bundleIdentifier {
            variables["PRODUCT_BUNDLE_IDENTIFIER"] = bundle
        }
        return expandedInfoPlist(values, variables: variables)
    }
    let loaded: LoadedProvisioningProfile?
    if let profile {
        let data = try? Data(contentsOf: URL(fileURLWithPath: profile))
        loaded = data.flatMap { bytes in
            guard let plist = decodeProvisioningProfile(bytes),
                  let summary = provisioningProfileSummary(from: plist) else { return nil }
            return LoadedProvisioningProfile(summary: summary, data: bytes, entitlements: entitlementsDictionary(from: plist))
        }
    } else if let bundle = inputs?.bundleIdentifier {
        let profiles = loadProvisioningProfiles()
        if let summary = chooseDevelopmentProfile(bundleIdentifier: bundle, profiles: profiles.map(\.summary)) {
            loaded = profiles.first { $0.summary == summary }
        } else {
            loaded = nil
        }
    } else {
        loaded = nil
    }
    let merged = mergedDictionaries(loaded?.entitlements ?? [:], overlay: projectEntitlements)
    return (
        chosenIdentity,
        loaded?.data,
        loaded?.summary.applicationIdentifier,
        merged.isEmpty ? nil : merged,
        info
    )
}

do {
    let response = try ControlClient.send(request, host: host, port: port)
    let finished = MacAgent().finish(response, request: request)
    FileHandle.standardOutput.write(Data(finished.logs.utf8))
    if finished.launched, let process = finished.process {
        let line = "running pid \(process.pid) \(process.bundleIdentifier) \(process.executablePath)\n"
        FileHandle.standardOutput.write(Data(line.utf8))
    }
    if finished.kind == .build && finished.launched {
        FileHandle.standardError.write(Data("build request launched a process\n".utf8))
        exit(1)
    }
    exit(finished.success ? 0 : 1)
} catch {
    FileHandle.standardError.write(Data((String(describing: error) + "\n").utf8))
    exit(1)
}
