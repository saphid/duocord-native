import Foundation

nonisolated struct GuildFolder: Hashable, Sendable, Codable {
    var id: Int64?
    var name: String?
    var color: UInt64?
    var guildIDs: [Snowflake]
}

/// Reads the two fields Duocord needs from Discord's protobuf user settings
/// (PreloadedUserSettings): guild_folders (field 14) → folders (1) and
/// guild_positions (2). Everything else is skipped by wire type.
nonisolated enum ProtoSettings {
    struct Folders: Sendable {
        var folders: [GuildFolder]
        var positions: [Snowflake]
    }

    static func guildFolders(base64: String) -> Folders? {
        guard let data = Data(base64Encoded: base64) else { return nil }
        var reader = ProtoReader(data)
        var result: Folders?
        while let (field, wire) = reader.tag() {
            if field == 14, wire == 2, let bytes = reader.bytes() {
                result = parseGuildFolders(bytes)
            } else if !reader.skip(wire) {
                break
            }
        }
        return result
    }

    private static func parseGuildFolders(_ data: Data) -> Folders {
        var reader = ProtoReader(data)
        var folders: [GuildFolder] = []
        var positions: [Snowflake] = []
        while let (field, wire) = reader.tag() {
            switch (field, wire) {
            case (1, 2):
                if let bytes = reader.bytes() { folders.append(parseFolder(bytes)) }
            case (2, 2):
                if let bytes = reader.bytes() { positions += fixed64s(bytes) }
            case (2, 1):
                if let value = reader.fixed64() { positions.append(Snowflake(value)) }
            default:
                if !reader.skip(wire) { return Folders(folders: folders, positions: positions) }
            }
        }
        return Folders(folders: folders, positions: positions)
    }

    private static func parseFolder(_ data: Data) -> GuildFolder {
        var reader = ProtoReader(data)
        var folder = GuildFolder(guildIDs: [])
        while let (field, wire) = reader.tag() {
            switch (field, wire) {
            case (1, 2):
                if let bytes = reader.bytes() { folder.guildIDs += fixed64s(bytes) }
            case (1, 1):
                if let value = reader.fixed64() { folder.guildIDs.append(Snowflake(value)) }
            case (2, 2): // Int64Value wrapper
                if let bytes = reader.bytes() { folder.id = wrappedVarint(bytes).map { Int64(bitPattern: $0) } }
            case (3, 2): // StringValue wrapper
                if let bytes = reader.bytes() { folder.name = wrappedString(bytes) }
            case (4, 2): // UInt64Value wrapper
                if let bytes = reader.bytes() { folder.color = wrappedVarint(bytes) }
            default:
                if !reader.skip(wire) { return folder }
            }
        }
        return folder
    }

    private static func fixed64s(_ data: Data) -> [Snowflake] {
        var reader = ProtoReader(data)
        var values: [Snowflake] = []
        while let value = reader.fixed64() { values.append(Snowflake(value)) }
        return values
    }

    private static func wrappedVarint(_ data: Data) -> UInt64? {
        var reader = ProtoReader(data)
        while let (field, wire) = reader.tag() {
            if field == 1, wire == 0 { return reader.varint() }
            if !reader.skip(wire) { break }
        }
        return nil
    }

    private static func wrappedString(_ data: Data) -> String? {
        var reader = ProtoReader(data)
        while let (field, wire) = reader.tag() {
            if field == 1, wire == 2, let bytes = reader.bytes() { return String(data: bytes, encoding: .utf8) }
            if !reader.skip(wire) { break }
        }
        return nil
    }
}

/// Minimal protobuf wire-format reader.
nonisolated struct ProtoReader {
    private let buffer: [UInt8]
    private var index = 0

    init(_ data: Data) { buffer = [UInt8](data) }

    mutating func varint() -> UInt64? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while index < buffer.count, shift < 64 {
            let byte = buffer[index]
            index += 1
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
        }
        return nil
    }

    mutating func tag() -> (Int, Int)? {
        guard index < buffer.count, let key = varint() else { return nil }
        return (Int(key >> 3), Int(key & 7))
    }

    mutating func fixed64() -> UInt64? {
        guard index + 8 <= buffer.count else { return nil }
        var value: UInt64 = 0
        for offset in 0..<8 { value |= UInt64(buffer[index + offset]) << (8 * UInt64(offset)) }
        index += 8
        return value
    }

    mutating func bytes() -> Data? {
        guard let length = varint(), index + Int(length) <= buffer.count else { return nil }
        let slice = Data(buffer[index..<(index + Int(length))])
        index += Int(length)
        return slice
    }

    mutating func skip(_ wire: Int) -> Bool {
        switch wire {
        case 0: return varint() != nil
        case 1: guard index + 8 <= buffer.count else { return false }; index += 8; return true
        case 2: return bytes() != nil
        case 5: guard index + 4 <= buffer.count else { return false }; index += 4; return true
        default: return false
        }
    }
}
