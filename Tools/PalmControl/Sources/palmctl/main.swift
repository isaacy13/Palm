// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import PalmControl

private func usage() -> Never {
    let text = """
    usage: palmctl [--host HOST] [--port PORT] <build|build-and-run|build-run-and-tests> \\
        --branch BRANCH --project PATH --target NAME [--repository URL] [--ui ACTION:NAME]

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
var ui: [UICheck] = []
while let raw = take("--ui") {
    let parts = raw.split(separator: ":", maxSplits: 1).map(String.init)
    guard parts.count == 2 else { usage() }
    ui.append(UICheck(name: parts[1], action: parts[0]))
}
guard args.count == 1, let branch, let project, let target,
      let kind = ControlRequestKind(rawValue: args[0]) else { usage() }

let request = ControlRequest(
    kind: kind,
    branch: branch,
    repository: repository,
    project: project,
    target: target,
    tests: [],
    ui: ui
)

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
