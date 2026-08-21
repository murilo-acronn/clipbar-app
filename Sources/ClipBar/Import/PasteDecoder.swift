import Compression
import Foundation

/// Reads the payload format Paste writes into its Core Data store.
///
/// There are three encodings in the wild — presumably successive versions of
/// the app — plus an out-of-line variant for anything large:
///
///   0x01 + "bplist…"  binary plist
///   0x01 + "bvx…"     LZFSE, wrapping the same structure
///   0x01 + <other>    raw DEFLATE of JSON
///   0x02 + <uuid>     the bytes live in .db_SUPPORT/_EXTERNAL_DATA/<uuid>
///
/// All of them decode to the same shape: an array of pasteboard items, each
/// mapping UTI → contents.
enum PasteDecoder {
    struct Payload {
        /// UTI → raw bytes, merged across the pasteboard items.
        var byType: [String: Data]
    }

    static func decode(_ raw: Data, externalRoot: URL) -> Payload? {
        guard let items = rawItems(raw, externalRoot: externalRoot) else { return nil }

        var byType: [String: Data] = [:]
        for item in items {
            guard let dict = item["dataByType"] as? [String: Any] else { continue }
            for (uti, value) in dict where byType[uti] == nil {
                if let data = decodeValue(value) { byType[uti] = data }
            }
        }
        return byType.isEmpty ? nil : Payload(byType: byType)
    }

    private static func rawItems(_ raw: Data, externalRoot: URL) -> [[String: Any]]? {
        guard let marker = raw.first else { return nil }

        if marker == 0x02 {
            let uuid = String(decoding: raw.dropFirst(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let outOfLine = try? Data(contentsOf: externalRoot.appendingPathComponent(uuid)) else {
                return nil
            }
            // Out-of-line files carry no marker byte — they start straight at
            // the payload, so they must not be shifted like inline blobs.
            return parse(outOfLine)
        }

        return parse(Data(raw.dropFirst()))
    }

    private static func parse(_ body: Data) -> [[String: Any]]? {
        let decoded: Data?
        if body.starts(with: Array("bplist".utf8)) {
            decoded = body
        } else if body.starts(with: Array("bvx".utf8)) {
            decoded = decompress(body, COMPRESSION_LZFSE)
        } else {
            decoded = decompress(body, COMPRESSION_ZLIB)
        }
        guard let data = decoded else { return nil }

        if let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] { return json }
        if let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) {
            if let array = plist as? [[String: Any]] { return array }
            if let dict = plist as? [String: Any] { return [dict] }
        }
        return nil
    }

    /// JSON carries the bytes base64-encoded; plists carry them as Data.
    private static func decodeValue(_ value: Any) -> Data? {
        if let data = value as? Data { return data }
        if let string = value as? String { return Data(base64Encoded: string) ?? Data(string.utf8) }
        return nil
    }

    private static func decompress(_ body: Data, _ algorithm: compression_algorithm) -> Data? {
        let capacity = max(body.count * 64, 1 << 21)
        var out = Data(count: capacity)
        let written = out.withUnsafeMutableBytes { destination -> Int in
            body.withUnsafeBytes { source -> Int in
                compression_decode_buffer(
                    destination.bindMemory(to: UInt8.self).baseAddress!, capacity,
                    source.bindMemory(to: UInt8.self).baseAddress!, body.count,
                    nil, algorithm
                )
            }
        }
        return written > 0 ? out.prefix(written) : nil
    }
}
