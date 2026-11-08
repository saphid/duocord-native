import Foundation

/// Strict, lossless wire envelope used only for folder writes. Unknown fields
/// are retained verbatim. No unrelated top-level settings are sent in PATCH.
/// Writes replace only the guild-folders section and require its data version.
nonisolated struct GuildFolderSettings: Sendable {
    let base64: String
    let dataVersion: UInt32?
    let folders: [GuildFolder]
    private let fields: [FolderProtoField]
    private let section: [FolderProtoField]
    private let records: [(GuildFolder, [FolderProtoField])]

    init(base64: String) throws {
        guard base64.count <= 5_242_880, let data = Data(base64Encoded: base64) else { throw GuildOrganizationError.malformed }
        let fields = try FolderProtoField.parse(data)
        let versions = try Self.singular(fields, 1)
        if let versions {
            let v = try FolderProtoField.parse(try versions.bytes())
            if let value = try Self.singular(v, 3) {
                guard value.wire == 0, let raw = value.integer, raw <= UInt32.max else { throw GuildOrganizationError.malformed }
                dataVersion = UInt32(raw)
            } else { dataVersion = 0 }
        } else { dataVersion = nil }
        let section = try Self.singular(fields, 14).map { try FolderProtoField.parse($0.bytes()) } ?? []
        var records: [(GuildFolder, [FolderProtoField])] = []
        for field in section where field.number == 1 {
            let raw = try FolderProtoField.parse(field.bytes())
            var ids: [Snowflake] = []
            for value in raw where value.number == 1 {
                switch value.wire {
                case 1: ids.append(Snowflake(try Self.fixed64(value.payload)))
                case 2:
                    guard value.payload.count % 8 == 0 else { throw GuildOrganizationError.malformed }
                    for offset in stride(from: 0, to: value.payload.count, by: 8) {
                        ids.append(Snowflake(try Self.fixed64(Data(value.payload.dropFirst(offset).prefix(8)))))
                    }
                default: throw GuildOrganizationError.malformed
                }
            }
            let id = try Self.wrapper(raw, 2).map { try Self.wrappedInteger($0) }.map { Int64(bitPattern: $0) }
            let name = try Self.wrapper(raw, 3).map { wrapper -> String in
                let bytes = try Self.singular(wrapper, 1)?.bytes() ?? Data()
                guard let name = String(data: bytes, encoding: .utf8) else { throw GuildOrganizationError.malformed }
                return name
            }
            let color = try Self.wrapper(raw, 4).map { try Self.wrappedInteger($0) }
            records.append((GuildFolder(id: id, name: name, color: color, guildIDs: ids), raw))
        }
        // Validate known positions even though deprecated; they must not hide
        // malformed input that a later serialization would accidentally repair.
        for position in section where position.number == 2 {
            guard (position.wire == 1 && position.payload.count == 8)
                || (position.wire == 2 && position.payload.count % 8 == 0) else { throw GuildOrganizationError.malformed }
        }
        self.base64 = base64; self.fields = fields; self.section = section
        self.records = records; self.folders = records.map { $0.0 }
    }

    func patch(for organization: GuildOrganization) throws -> GuildFolderPatch {
        guard let dataVersion else { throw GuildOrganizationError.missingVersion }
        let section = try encodedSection(for: organization)
        return GuildFolderPatch(settings: FolderProtoField.message(14, section).base64EncodedString(), requiredDataVersion: dataVersion)
    }

    /// Offline mock only: models the documented top-level replacement and
    /// server-owned version increment. Never used to manufacture live success.
    func replacingFolders(with organization: GuildOrganization, version: UInt32) throws -> Self {
        let oldVersions = try Self.singular(fields, 1).map { try FolderProtoField.parse($0.bytes()) } ?? []
        let versions = oldVersions.filter { $0.number != 3 }.reduce(into: Data()) { $0 += $1.raw }
            + FolderProtoField.scalar(3, UInt64(version))
        let other = fields.filter { ![1, 14].contains($0.number) }.reduce(into: Data()) { $0 += $1.raw }
        return try Self(base64: (other + FolderProtoField.message(1, versions)
            + FolderProtoField.message(14, try encodedSection(for: organization))).base64EncodedString())
    }

    private func encodedSection(for organization: GuildOrganization) throws -> Data {
        var data = section.filter { ![1, 2].contains($0.number) }.reduce(into: Data()) { $0 += $1.raw }
        for folder in organization.rows {
            let previous = records.first { record in
                if let id = folder.id { return record.0.id == id }
                return record.0.id == nil && record.0.guildIDs == folder.guildIDs
            }
            let original = previous?.1 ?? []
            var record = original.filter { ![1, 2, 3, 4].contains($0.number) }.reduce(into: Data()) { $0 += $1.raw }
            var guilds = Data()
            for id in folder.guildIDs { for shift in 0..<8 { guilds.append(UInt8(truncatingIfNeeded: id.raw >> (shift * 8))) } }
            record += FolderProtoField.message(1, guilds)
            // Wrapper unknown fields survive value changes; unchanged wrappers
            // survive byte-for-byte, including explicitly-present default values.
            if let id = folder.id { record += try Self.encodeWrapper(original, 2, value: FolderProtoField.scalar(1, UInt64(bitPattern: id)), unchanged: previous?.0.id == id) }
            if let name = folder.name { record += try Self.encodeWrapper(original, 3, value: FolderProtoField.message(1, Data(name.utf8)), unchanged: previous?.0.name == name) }
            if let color = folder.color { record += try Self.encodeWrapper(original, 4, value: FolderProtoField.scalar(1, color), unchanged: previous?.0.color == color) }
            data += FolderProtoField.message(1, record)
        }
        // Keep the deprecated compatibility order consistent with folder order.
        var positions = Data()
        for id in organization.positions { for shift in 0..<8 { positions.append(UInt8(truncatingIfNeeded: id.raw >> (shift * 8))) } }
        data += FolderProtoField.message(2, positions)
        return data
    }

    private static func encodeWrapper(_ fields: [FolderProtoField], _ number: Int, value: Data, unchanged: Bool) throws -> Data {
        if let old = try singular(fields, number) {
            if unchanged { return old.raw }
            let unknown = try FolderProtoField.parse(old.bytes()).filter { $0.number != 1 }.reduce(into: Data()) { $0 += $1.raw }
            return FolderProtoField.message(number, unknown + value)
        }
        return FolderProtoField.message(number, value)
    }
    private static func singular(_ fields: [FolderProtoField], _ number: Int) throws -> FolderProtoField? {
        let matches = fields.filter { $0.number == number }
        guard matches.count <= 1 else { throw GuildOrganizationError.malformed }
        return matches.first
    }
    private static func wrapper(_ fields: [FolderProtoField], _ number: Int) throws -> [FolderProtoField]? {
        try singular(fields, number).map { try FolderProtoField.parse($0.bytes()) }
    }
    private static func wrappedInteger(_ fields: [FolderProtoField]) throws -> UInt64 {
        guard let field = try singular(fields, 1) else { return 0 }
        guard field.wire == 0, let value = field.integer else { throw GuildOrganizationError.malformed }
        return value
    }
    private static func fixed64(_ data: Data) throws -> UInt64 {
        guard data.count == 8 else { throw GuildOrganizationError.malformed }
        return data.enumerated().reduce(0) { $0 | UInt64($1.element) << ($1.offset * 8) }
    }
}

nonisolated struct GuildFolderPatch: Equatable, Sendable {
    let settings: String
    let requiredDataVersion: UInt32
    fileprivate init(settings: String, requiredDataVersion: UInt32) {
        self.settings = settings; self.requiredDataVersion = requiredDataVersion
    }
}

nonisolated struct GuildFolderSaveResponse: Codable, Sendable {
    let settings: String
    let outOfDate: Bool?
    enum CodingKeys: String, CodingKey { case settings; case outOfDate = "out_of_date" }
}

/// Separate from the permissive display reader. Rejects truncation, invalid
/// tags, overflow and unsupported group wire types rather than emitting a
/// partially decoded settings replacement.
nonisolated struct FolderProtoField: Sendable {
    let number: Int
    let wire: Int
    let payload: Data
    let integer: UInt64?
    let raw: Data

    func bytes() throws -> Data {
        guard wire == 2 else { throw GuildOrganizationError.malformed }
        return payload
    }
    static func parse(_ data: Data) throws -> [Self] {
        let buffer = [UInt8](data)
        var index = 0, result: [Self] = []
        func varint(_ index: inout Int) throws -> UInt64 {
            var value: UInt64 = 0
            for offset in 0..<10 {
                guard index < buffer.count else { throw GuildOrganizationError.malformed }
                let byte = buffer[index]; index += 1
                if offset == 9 && byte > 1 { throw GuildOrganizationError.malformed }
                value |= UInt64(byte & 127) << (offset * 7)
                if byte & 128 == 0 { return value }
            }
            throw GuildOrganizationError.malformed
        }
        while index < buffer.count {
            let start = index, tag = try varint(&index)
            let number = tag >> 3, wire = Int(tag & 7)
            guard number > 0, number <= 0x1FFF_FFFF else { throw GuildOrganizationError.malformed }
            var integer: UInt64?
            let payloadStart: Int, length: Int
            switch wire {
            case 0:
                payloadStart = index; integer = try varint(&index); length = index - payloadStart
            case 1, 5:
                payloadStart = index; length = wire == 1 ? 8 : 4
                guard length <= buffer.count - index else { throw GuildOrganizationError.malformed }
                index += length
            case 2:
                let size = try varint(&index)
                guard size <= UInt64(buffer.count - index) else { throw GuildOrganizationError.malformed }
                payloadStart = index; length = Int(size); index += length
            default: throw GuildOrganizationError.malformed
            }
            result.append(Self(number: Int(number), wire: wire, payload: Data(buffer[payloadStart..<(payloadStart + length)]), integer: integer, raw: Data(buffer[start..<index])))
        }
        return result
    }
    static func varint(_ value: UInt64) -> Data {
        var value = value, data = Data()
        repeat { var byte = UInt8(value & 127); value >>= 7; if value != 0 { byte |= 128 }; data.append(byte) } while value != 0
        return data
    }
    static func message(_ number: Int, _ bytes: Data) -> Data { varint(UInt64(number << 3 | 2)) + varint(UInt64(bytes.count)) + bytes }
    static func scalar(_ number: Int, _ value: UInt64) -> Data { varint(UInt64(number << 3)) + varint(value) }
}
