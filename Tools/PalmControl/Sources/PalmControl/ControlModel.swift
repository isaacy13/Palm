// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// The control channel accepts one of these three requests.
/// A later stage runs only when the request names it.
public enum ControlRequestKind: String, Codable, Equatable {
    case build
    case buildAndRun = "build-and-run"
    case buildRunAndTests = "build-run-and-tests"
}

public enum ControlStage: String, Codable, Equatable, CaseIterable {
    case pull
    case compile
    case link
    case sign
    case launch
    case test
}

public struct UICheck: Codable, Equatable {
    public var name: String
    public var action: String

    public init(name: String, action: String) {
        self.name = name
        self.action = action
    }
}

public struct ControlRequest: Codable, Equatable {
    public var kind: ControlRequestKind
    public var branch: String
    public var repository: String?
    public var project: String
    public var target: String
    public var tests: [String]
    public var ui: [UICheck]
    /// Compile width. Nil uses every performance core on the phone.
    public var threads: Int?

    public init(kind: ControlRequestKind,
                branch: String,
                repository: String? = nil,
                project: String,
                target: String,
                tests: [String] = [],
                ui: [UICheck] = [],
                threads: Int? = nil) {
        self.kind = kind
        self.branch = branch
        self.repository = repository
        self.project = project
        self.target = target
        self.tests = tests
        self.ui = ui
        self.threads = threads
    }

    /// Stages this request is allowed to start, in order.
    public var allowedStages: [ControlStage] {
        switch kind {
        case .build:
            return [.pull, .compile, .link, .sign]
        case .buildAndRun:
            return [.pull, .compile, .link, .sign, .launch]
        case .buildRunAndTests:
            return [.pull, .compile, .link, .sign, .launch, .test]
        }
    }

    public var requestsLaunch: Bool {
        allowedStages.contains(.launch)
    }

    public var requestsTests: Bool {
        allowedStages.contains(.test)
    }
}

extension ControlRequestKind {
    public var requestsLaunch: Bool {
        switch self {
        case .build:
            return false
        case .buildAndRun, .buildRunAndTests:
            return true
        }
    }

    public var requestsTests: Bool {
        self == .buildRunAndTests
    }
}

/// Width of an on-device compile. A missing or non-positive request uses every
/// performance core. A larger request clamps to that maximum.
public func compileThreadCount(requested: Int?, cores: Int) -> Int {
    let maximum = max(cores, 1)
    guard let requested, requested > 0 else { return maximum }
    return min(requested, maximum)
}

public struct RunningProcess: Codable, Equatable {
    public var pid: Int32
    public var bundleIdentifier: String
    public var executablePath: String

    public init(pid: Int32, bundleIdentifier: String, executablePath: String) {
        self.pid = pid
        self.bundleIdentifier = bundleIdentifier
        self.executablePath = executablePath
    }
}

public struct ControlResponse: Codable, Equatable {
    public var success: Bool
    public var kind: ControlRequestKind
    public var stagesRun: [ControlStage]
    public var failedStage: ControlStage?
    public var logs: String
    public var launched: Bool
    public var process: RunningProcess?

    public init(success: Bool,
                kind: ControlRequestKind,
                stagesRun: [ControlStage],
                failedStage: ControlStage?,
                logs: String,
                launched: Bool,
                process: RunningProcess?) {
        self.success = success
        self.kind = kind
        self.stagesRun = stagesRun
        self.failedStage = failedStage
        self.logs = logs
        self.launched = launched
        self.process = process
    }
}

public enum ControlError: Error, Equatable, CustomStringConvertible {
    case stageNotRequested(ControlStage)
    case missingProject(String)
    case missingTarget(String)
    case gitFailed(String)
    case compileFailed(String)
    case linkFailed(String)
    case signFailed(String)
    case launchFailed(String)
    case testFailed(String)
    case malformedChannel
    case channel(String)

    public var description: String {
        switch self {
        case .stageNotRequested(let stage):
            return "stage \(stage.rawValue) was not requested"
        case .missingProject(let path):
            return "project not found at \(path)"
        case .missingTarget(let name):
            return "target \(name) not found"
        case .gitFailed(let message):
            return message
        case .compileFailed(let message):
            return message
        case .linkFailed(let message):
            return message
        case .signFailed(let message):
            return message
        case .launchFailed(let message):
            return message
        case .testFailed(let message):
            return message
        case .malformedChannel:
            return "control channel message was not a single JSON request"
        case .channel(let message):
            return message
        }
    }
}

public final class ControlLog {
    public private(set) var text: String = ""
    /// Host UI mirror. The control response still carries the full log.
    public static var mirror: ((String) -> Void)?

    public init() {}

    public func append(_ line: String) {
        if text.isEmpty {
            text = line
        } else if text.hasSuffix("\n") {
            text += line
        } else {
            text += "\n" + line
        }
        if !text.hasSuffix("\n") {
            text += "\n"
        }
        ControlLog.mirror?(line)
    }
}
