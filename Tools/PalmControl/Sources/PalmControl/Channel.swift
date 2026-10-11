// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Network

public enum TeamSigner {
    public static var sign: ((Data) throws -> Data)?

    public static func request(_ bytes: Data) throws -> Data {
        guard let sign else {
            throw ControlError.signFailed("team signature is unavailable")
        }
        return try sign(bytes)
    }
}

private struct WireSign: Codable {
    var op: String
    var bytes: String
}

public final class ControlServer {
    private let handler: (ControlRequest) -> ControlResponse
    private let queue = DispatchQueue(label: "palm.control.server")
    private let work = DispatchQueue(label: "palm.control.work")
    private var listener: NWListener?
    private var connections: [NWConnection] = []

    public init(handler: @escaping (ControlRequest) -> ControlResponse) {
        self.handler = handler
    }

    public func start(port: UInt16) throws -> UInt16 {
        let endpoint = NWEndpoint.Port(rawValue: port) ?? .any
        let listener = try NWListener(using: .tcp, on: endpoint)
        let ready = DispatchSemaphore(value: 0)
        var failed: Error?
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                ready.signal()
            case .failed(let error):
                failed = error
                ready.signal()
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
        ready.wait()
        if let failed {
            throw ControlError.channel(failed.localizedDescription)
        }
        self.listener = listener
        return listener.port?.rawValue ?? port
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        for connection in connections {
            connection.cancel()
        }
        connections.removeAll()
    }

    private func accept(_ connection: NWConnection) {
        connections.append(connection)
        connection.stateUpdateHandler = { [weak self] state in
            if case .ready = state {
                self?.receive(connection, buffer: Data())
            }
        }
        connection.start(queue: queue)
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1024 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var next = buffer
            if let data { next.append(data) }
            if let newline = next.firstIndex(of: 0x0A) {
                let line = next.prefix(upTo: newline)
                self.reply(connection, line: Data(line))
                return
            }
            if error != nil || isComplete {
                connection.cancel()
                return
            }
            self.receive(connection, buffer: next)
        }
    }

    private func reply(_ connection: NWConnection, line: Data) {
        let queue = self.queue
        work.async { [handler, queue] in
            let response: ControlResponse
            TeamSigner.sign = { bytes in
                try Self.exchangeSignature(connection, bytes: bytes, queue: queue)
            }
            defer { TeamSigner.sign = nil }
            if let request = try? JSONDecoder().decode(ControlRequest.self, from: line) {
                response = handler(request)
            } else {
                response = ControlResponse(
                    success: false,
                    kind: .build,
                    stagesRun: [],
                    failedStage: nil,
                    logs: "malformed request\n",
                    launched: false,
                    process: nil
                )
            }
            var body = (try? JSONEncoder().encode(response)) ?? Data()
            body.append(0x0A)
            connection.send(content: body, completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }

    private static func exchangeSignature(_ connection: NWConnection, bytes: Data, queue: DispatchQueue) throws -> Data {
        var request = try JSONEncoder().encode(WireSign(op: "sign", bytes: bytes.base64EncodedString()))
        request.append(0x0A)
        let done = DispatchSemaphore(value: 0)
        var reply = Data()
        var failure: Error?
        queue.async {
            connection.send(content: request, completion: .contentProcessed { error in
                if let error {
                    failure = error
                    done.signal()
                    return
                }
                func read() {
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 8 * 1024 * 1024) { data, _, isComplete, error in
                        if let data { reply.append(data) }
                        if reply.contains(0x0A) || isComplete || error != nil {
                            if let error { failure = error }
                            done.signal()
                            return
                        }
                        read()
                    }
                }
                read()
            })
        }
        done.wait()
        if let failure, reply.isEmpty {
            throw ControlError.signFailed(failure.localizedDescription)
        }
        guard let newline = reply.firstIndex(of: 0x0A),
              let wire = try? JSONDecoder().decode(WireSign.self, from: reply.prefix(upTo: newline)),
              wire.op == "signed",
              let signed = Data(base64Encoded: wire.bytes) else {
            throw ControlError.signFailed("team signature reply was unusable")
        }
        return signed
    }
}

public enum ControlClient {
    public static func send(_ request: ControlRequest, host: String, port: UInt16) throws -> ControlResponse {
        let connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        let queue = DispatchQueue(label: "palm.control.client")
        let ready = DispatchSemaphore(value: 0)
        var failure: Error?
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                ready.signal()
            case .failed(let error):
                failure = error
                ready.signal()
            default:
                break
            }
        }
        connection.start(queue: queue)
        ready.wait()
        if let failure {
            connection.cancel()
            throw ControlError.channel(failure.localizedDescription)
        }
        var body = try JSONEncoder().encode(request)
        body.append(0x0A)
        let sent = DispatchSemaphore(value: 0)
        connection.send(content: body, completion: .contentProcessed { error in
            if let error { failure = error }
            sent.signal()
        })
        sent.wait()
        if let failure {
            connection.cancel()
            throw ControlError.channel(failure.localizedDescription)
        }
        while true {
            let received = DispatchSemaphore(value: 0)
            var payload = Data()
            func read() {
                connection.receive(minimumIncompleteLength: 1, maximumLength: 8 * 1024 * 1024) { data, _, isComplete, error in
                    if let data { payload.append(data) }
                    if payload.contains(0x0A) || isComplete || error != nil {
                        if let error { failure = error }
                        received.signal()
                        return
                    }
                    read()
                }
            }
            read()
            received.wait()
            if let failure, payload.isEmpty {
                connection.cancel()
                throw ControlError.channel(failure.localizedDescription)
            }
            guard let newline = payload.firstIndex(of: 0x0A) else {
                connection.cancel()
                throw ControlError.malformedChannel
            }
            let line = payload.prefix(upTo: newline)
            if let wire = try? JSONDecoder().decode(WireSign.self, from: line), wire.op == "sign" {
                let signed = try teamSign(wire.bytes)
                var reply = try JSONEncoder().encode(WireSign(op: "signed", bytes: signed))
                reply.append(0x0A)
                let sentBack = DispatchSemaphore(value: 0)
                connection.send(content: reply, completion: .contentProcessed { error in
                    if let error { failure = error }
                    sentBack.signal()
                })
                sentBack.wait()
                continue
            }
            connection.cancel()
            return try JSONDecoder().decode(ControlResponse.self, from: line)
        }
    }

    #if os(macOS)
    private static func runCodesign(_ arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = arguments
        process.standardError = pipe
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (process.terminationStatus, output.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    #endif

    private static func teamSign(_ encoded: String) throws -> String {
        #if os(macOS)
        guard let bytes = Data(base64Encoded: encoded) else {
            throw ControlError.signFailed("sign request was not base64")
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("palm-\(UUID().uuidString)")
        try bytes.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let removed = try runCodesign(["--remove-signature", url.path])
        if removed.status != 0 {
            throw ControlError.signFailed("remove signature \(removed.status) \(removed.output)")
        }
        let signed = try runCodesign(["-f", "-s", "Apple Development: Isaac Yeang (AT4W55YC44)", url.path])
        guard signed.status == 0 else {
            throw ControlError.signFailed("codesign \(signed.status) \(signed.output)")
        }
        return try Data(contentsOf: url).base64EncodedString()
        #else
        throw ControlError.signFailed("codesign runs on the Mac")
        #endif
    }
}
