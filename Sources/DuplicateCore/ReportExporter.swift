import Foundation

public enum ReportExporter {
    public static func json(_ result: ScanResult) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(result)
    }
    public static func csv(_ result: ScanResult) -> String {
        var rows = ["group_hash,path,size_bytes,modified_at,network_volume"]
        let iso = ISO8601DateFormatter()
        for group in result.groups {
            for file in group.files {
                let path = "\"" + file.url.path.replacingOccurrences(of: "\"", with: "\"\"") + "\""
                rows.append("\(group.hash),\(path),\(file.size),\(file.modifiedAt.map(iso.string) ?? ""),\(file.isNetworkVolume)")
            }
        }
        return rows.joined(separator: "\n")
    }
}
