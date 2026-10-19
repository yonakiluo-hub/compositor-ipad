import Foundation

public enum ProjectArchiveError: LocalizedError {
    case unsafePath, unsupportedEntry, tooLarge, tooManyEntries, unreadable
    public var errorDescription: String? {
        switch self {
        case .unsafePath: "工程归档包含不安全或重复的文件路径。"
        case .unsupportedEntry: "工程归档只能包含普通文件，不能包含链接。"
        case .tooLarge: "工程快照超过服务允许的大小；本地工程仍然保留。"
        case .tooManyEntries: "工程快照超过服务允许的文件数量。"
        case .unreadable: "无法读取完整工程快照。"
        }
    }
}

/// Small dependency-free ZIP writer for immutable .comp backups. PNG assets are already
/// compressed, so Stored entries avoid extra CPU and give deterministic bytes. Callers must
/// still persist the first archive for each revision and reuse it for every network retry.
public enum ProjectArchive {
    public static let maximumArchiveBytes = 64 * 1024 * 1024
    public static let maximumEntries = 2_000

    public static func zip(contentsOf packageURL: URL, maximumBytes: Int = maximumArchiveBytes) throws -> Data {
        let limit = min(maximumBytes, maximumArchiveBytes)
        guard limit >= 22 else { throw ProjectArchiveError.tooLarge }
        // Never back up an unsupported or damaged editing document as if it were valid.
        _ = try DocumentStore.load(from: packageURL)
        var coordinationError: NSError?
        var result: Result<Data, Error>?
        NSFileCoordinator().coordinate(readingItemAt: packageURL, options: .withoutChanges, error: &coordinationError) { source in
            result = Result { try encodePackage(source, maximumBytes: limit) }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw ProjectArchiveError.unreadable }
        return try result.get()
    }

    private struct File {
        let url: URL
        let name: Data
        let size: Int
    }
    private struct Entry {
        let name: Data
        let size: UInt32
        let crc: UInt32
        let offset: UInt32
    }

    private static func encodePackage(_ packageURL: URL, maximumBytes: Int) throws -> Data {
        let root = packageURL.resolvingSymlinksInPath().standardizedFileURL
        let rootPath = root.path + "/"
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        var enumerationError: Error?
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(keys),
                                                              errorHandler: { _, error in enumerationError = error; return false })
        else { throw ProjectArchiveError.unreadable }
        var files: [File] = [], seen: Set<String> = [], expectedBytes = 22
        for case let file as URL in enumerator {
            let values = try file.resourceValues(forKeys: keys)
            guard values.isSymbolicLink != true else { throw ProjectArchiveError.unsupportedEntry }
            guard file.standardizedFileURL.path.hasPrefix(rootPath), file.resolvingSymlinksInPath().path.hasPrefix(rootPath)
            else { throw ProjectArchiveError.unsafePath }
            let relative = String(file.standardizedFileURL.path.dropFirst(rootPath.count))
            try validatePath(relative)
            let canonical = relative.precomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            guard seen.insert(canonical).inserted else { throw ProjectArchiveError.unsafePath }
            if values.isDirectory == true { continue }
            guard values.isRegularFile == true, let size = values.fileSize, size >= 0 else { throw ProjectArchiveError.unsupportedEntry }
            let name = Data(relative.utf8)
            // Local header (30) + central-directory header (46) + two copies of the name.
            let overhead = 76 + 2 * name.count
            guard overhead <= maximumBytes - expectedBytes, size <= maximumBytes - expectedBytes - overhead
            else { throw ProjectArchiveError.tooLarge }
            expectedBytes += overhead + size
            files.append(File(url: file, name: name, size: size))
            guard files.count <= maximumEntries else { throw ProjectArchiveError.tooManyEntries }
        }
        if let enumerationError { throw enumerationError }
        guard !files.isEmpty else { throw ProjectArchiveError.unreadable }
        files.sort { $0.name.lexicographicallyPrecedes($1.name) }
        var archive = Data(), entries: [Entry] = []
        archive.reserveCapacity(expectedBytes)
        for file in files {
            let bytes = try Data(contentsOf: file.url)
            guard bytes.count == file.size else { throw ProjectArchiveError.unreadable }
            let entry = Entry(name: file.name, size: UInt32(bytes.count), crc: crc32(bytes), offset: UInt32(archive.count))
            entries.append(entry)
            archive.appendLE(UInt32(0x04034b50)) // Local file header.
            archive.appendLE(UInt16(20))         // ZIP 2.0 reader.
            archive.appendLE(UInt16(0x0800))     // UTF-8 names; no encryption or data descriptor.
            archive.appendLE(UInt16(0))          // Stored.
            archive.appendLE(UInt16(0))          // 00:00:00.
            archive.appendLE(UInt16(0x0021))     // 1980-01-01, independent of filesystem time.
            archive.appendLE(entry.crc)
            archive.appendLE(entry.size); archive.appendLE(entry.size)
            archive.appendLE(UInt16(entry.name.count)); archive.appendLE(UInt16(0))
            archive.append(entry.name); archive.append(bytes)
        }
        let centralOffset = UInt32(archive.count)
        for entry in entries {
            archive.appendLE(UInt32(0x02014b50)) // Central directory.
            archive.appendLE(UInt16(0x0314))     // UNIX, ZIP 2.0.
            archive.appendLE(UInt16(20)); archive.appendLE(UInt16(0x0800)); archive.appendLE(UInt16(0))
            archive.appendLE(UInt16(0)); archive.appendLE(UInt16(0x0021))
            archive.appendLE(entry.crc); archive.appendLE(entry.size); archive.appendLE(entry.size)
            archive.appendLE(UInt16(entry.name.count))
            archive.appendLE(UInt16(0)); archive.appendLE(UInt16(0)); archive.appendLE(UInt16(0))
            archive.appendLE(UInt16(0)); archive.appendLE(UInt32(0o100644 << 16))
            archive.appendLE(entry.offset); archive.append(entry.name)
        }
        let centralSize = UInt32(archive.count) - centralOffset
        archive.appendLE(UInt32(0x06054b50)) // End of central directory, single disk, no comment.
        archive.appendLE(UInt16(0)); archive.appendLE(UInt16(0))
        archive.appendLE(UInt16(entries.count)); archive.appendLE(UInt16(entries.count))
        archive.appendLE(centralSize); archive.appendLE(centralOffset); archive.appendLE(UInt16(0))
        guard archive.count == expectedBytes, archive.count <= maximumBytes else { throw ProjectArchiveError.tooLarge }
        return archive
    }

    private static func validatePath(_ path: String) throws {
        guard !path.isEmpty, path.utf8.count <= 65_535, !path.contains("\\") else { throw ProjectArchiveError.unsafePath }
        for part in path.split(separator: "/", omittingEmptySubsequences: false) {
            guard !part.isEmpty, part != ".", part != "..", !part.hasSuffix("."), !part.hasSuffix(" "),
                  !part.unicodeScalars.contains(where: { $0.value < 32 }),
                  part.rangeOfCharacter(from: CharacterSet(charactersIn: ":<>\"|?*")) == nil,
                  part.range(of: "^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(\\..*)?$", options: [.regularExpression, .caseInsensitive]) == nil
            else { throw ProjectArchiveError.unsafePath }
        }
    }

    private static let crcTable: [UInt32] = (0..<256).map { value in
        var crc = UInt32(value)
        for _ in 0..<8 { crc = (crc & 1) == 0 ? crc >> 1 : 0xedb88320 ^ (crc >> 1) }
        return crc
    }
    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffffffff
        for byte in data { crc = crcTable[Int((crc ^ UInt32(byte)) & 0xff)] ^ (crc >> 8) }
        return crc ^ 0xffffffff
    }
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }
}
