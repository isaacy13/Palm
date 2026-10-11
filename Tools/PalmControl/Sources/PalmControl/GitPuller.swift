// SPDX-License-Identifier: AGPL-3.0-or-later

import Darwin
import Foundation

enum CommandRunner {
    static func run(executable: String, arguments: [String], currentDirectory: URL?) throws -> (status: Int32, output: String) {
        var pipeFds = [Int32](repeating: 0, count: 2)
        guard pipe(&pipeFds) == 0 else {
            throw ControlError.gitFailed("pipe failed")
        }
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        let previousDirectory = FileManager.default.currentDirectoryPath
        if let currentDirectory {
            guard FileManager.default.changeCurrentDirectoryPath(currentDirectory.path) else {
                throw ControlError.gitFailed("cannot enter \(currentDirectory.path)")
            }
        }
        defer {
            if currentDirectory != nil {
                FileManager.default.changeCurrentDirectoryPath(previousDirectory)
            }
        }
        posix_spawn_file_actions_adddup2(&actions, pipeFds[1], STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, pipeFds[1], STDERR_FILENO)
        posix_spawn_file_actions_addclose(&actions, pipeFds[0])
        posix_spawn_file_actions_addclose(&actions, pipeFds[1])

        let argv = [executable] + arguments
        let cStrings: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) }
        defer { for pointer in cStrings { free(pointer) } }
        var cArgv = cStrings
        cArgv.append(nil)
        var pid: pid_t = 0
        let spawnResult = cArgv.withUnsafeMutableBufferPointer { buffer -> Int32 in
            posix_spawn(&pid, executable, &actions, nil, buffer.baseAddress, environ)
        }
        close(pipeFds[1])
        guard spawnResult == 0 else {
            close(pipeFds[0])
            throw ControlError.gitFailed("failed to run \(executable): \(String(cString: strerror(spawnResult)))")
        }
        let handle = FileHandle(fileDescriptor: pipeFds[0], closeOnDealloc: true)
        let data = handle.readDataToEndOfFile()
        var status: Int32 = 0
        waitpid(pid, &status, 0)
        let output = String(data: data, encoding: .utf8) ?? ""
        let code = (status & 0xff) == 0 ? (status >> 8) & 0xff : status
        return (Int32(code), output)
    }
}

public enum GitPuller {
    public static func pull(repository: String?, branch: String, into destination: URL) throws {
        let git = "/usr/bin/git"
        let fileManager = FileManager.default
        if let repository {
            if fileManager.fileExists(atPath: destination.appendingPathComponent(".git").path) {
                let fetch = try CommandRunner.run(executable: git, arguments: ["fetch", "origin", branch], currentDirectory: destination)
                guard fetch.status == 0 else { throw ControlError.gitFailed(fetch.output) }
                let checkout = try CommandRunner.run(executable: git, arguments: ["checkout", branch], currentDirectory: destination)
                guard checkout.status == 0 else { throw ControlError.gitFailed(checkout.output) }
                let pull = try CommandRunner.run(executable: git, arguments: ["pull", "--ff-only", "origin", branch], currentDirectory: destination)
                guard pull.status == 0 else { throw ControlError.gitFailed(pull.output) }
                return
            }
            try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            let clone = try CommandRunner.run(
                executable: git,
                arguments: ["clone", "--branch", branch, "--single-branch", repository, destination.path],
                currentDirectory: nil
            )
            guard clone.status == 0 else { throw ControlError.gitFailed(clone.output) }
            return
        }
        guard fileManager.fileExists(atPath: destination.path) else {
            throw ControlError.gitFailed("no repository to pull and \(destination.path) is missing")
        }
        if fileManager.fileExists(atPath: destination.appendingPathComponent(".git").path) {
            let checkout = try CommandRunner.run(executable: git, arguments: ["checkout", branch], currentDirectory: destination)
            guard checkout.status == 0 else { throw ControlError.gitFailed(checkout.output) }
        }
    }
}
