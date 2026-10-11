// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

enum PbxValue {
    case string(String)
    case array([PbxValue])
    case object([String: PbxValue])

    var string: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var object: [String: PbxValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    var array: [PbxValue]? {
        if case .array(let value) = self { return value }
        return nil
    }
}

enum PbxParser {
    static func objects(in text: String) throws -> [String: PbxValue] {
        var parser = Parser(text: text)
        let root = try parser.parseValue()
        guard let objects = root.object?["objects"]?.object else {
            throw ControlError.channel("pbxproj has no objects dictionary")
        }
        return objects
    }
}

private struct Parser {
    let text: String
    var index: String.Index

    init(text: String) {
        self.text = text
        self.index = text.startIndex
    }

    mutating func parseValue() throws -> PbxValue {
        skipNoise()
        guard index < text.endIndex else {
            throw ControlError.channel("unexpected end of pbxproj")
        }
        let character = text[index]
        if character == "\"" {
            return .string(try parseQuoted())
        }
        if character == "{" {
            return .object(try parseObject())
        }
        if character == "(" {
            return .array(try parseArray())
        }
        return .string(parseBare())
    }

    mutating func parseObject() throws -> [String: PbxValue] {
        skipNoise()
        guard take("{") else { throw ControlError.channel("expected {") }
        var fields: [String: PbxValue] = [:]
        while true {
            skipNoise()
            if take("}") { break }
            let key = try parseKey()
            skipNoise()
            guard take("=") else { throw ControlError.channel("expected = after \(key)") }
            let value = try parseValue()
            skipNoise()
            if !take(";") {
                throw ControlError.channel("expected ; after \(key)")
            }
            fields[key] = value
        }
        return fields
    }

    mutating func parseArray() throws -> [PbxValue] {
        skipNoise()
        guard take("(") else { throw ControlError.channel("expected (") }
        var values: [PbxValue] = []
        while true {
            skipNoise()
            if take(")") { break }
            values.append(try parseValue())
            skipNoise()
            _ = take(",")
        }
        return values
    }

    mutating func parseKey() throws -> String {
        skipNoise()
        if peek("\"") {
            return try parseQuoted()
        }
        let start = index
        while index < text.endIndex {
            let character = text[index]
            if character.isLetter || character.isNumber || character == "_" || character == "." || character == "/" || character == "+" || character == "-" {
                index = text.index(after: index)
            } else {
                break
            }
        }
        guard start != index else { throw ControlError.channel("expected key") }
        return String(text[start..<index])
    }

    mutating func parseQuoted() throws -> String {
        guard take("\"") else { throw ControlError.channel("expected quote") }
        var result = ""
        while index < text.endIndex {
            let character = text[index]
            index = text.index(after: index)
            if character == "\\" {
                guard index < text.endIndex else { break }
                result.append(text[index])
                index = text.index(after: index)
            } else if character == "\"" {
                return result
            } else {
                result.append(character)
            }
        }
        throw ControlError.channel("unterminated string")
    }

    mutating func parseBare() -> String {
        skipNoise()
        let start = index
        while index < text.endIndex {
            let character = text[index]
            if character == ";" || character == "," || character == ")" || character == "}" || character.isNewline || character == " " || character == "\t" {
                break
            }
            index = text.index(after: index)
        }
        return String(text[start..<index])
    }

    mutating func skipNoise() {
        while index < text.endIndex {
            let character = text[index]
            if character == " " || character == "\t" || character == "\n" || character == "\r" {
                index = text.index(after: index)
                continue
            }
            if character == "/" {
                let next = text.index(after: index)
                if next < text.endIndex && text[next] == "*" {
                    index = text.index(next, offsetBy: 1)
                    while index < text.endIndex {
                        if text[index] == "*" {
                            let after = text.index(after: index)
                            if after < text.endIndex && text[after] == "/" {
                                index = text.index(after: after)
                                break
                            }
                        }
                        index = text.index(after: index)
                    }
                    continue
                }
                if next < text.endIndex && text[next] == "/" {
                    while index < text.endIndex && !text[index].isNewline {
                        index = text.index(after: index)
                    }
                    continue
                }
            }
            break
        }
    }

    func peek(_ token: Character) -> Bool {
        index < text.endIndex && text[index] == token
    }

    mutating func take(_ token: Character) -> Bool {
        skipNoise()
        guard peek(token) else { return false }
        index = text.index(after: index)
        return true
    }
}
