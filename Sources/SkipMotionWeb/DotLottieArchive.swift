// Copyright 2023–2026 Skip
#if !SKIP
/// Reads the animation out of a dotLottie file (https://dotlottie.io): a ZIP archive that holds `manifest.json` and the
/// compositions under `animations/`, each stored as is or compressed with DEFLATE. `LottieContainer(data:)` uses it on
/// iOS and in the browser, so both read the archive in memory with no temporary files; Android hands the archive to
/// lottie-android, which reads ZIPs itself. Built from bytes only, with no Foundation, for the Embedded browser build.
enum DotLottieArchive {
    enum Failure: Error {
        case notAnArchive, noAnimation, unsupportedCompression, corrupt
    }

    /// True when the bytes start like a ZIP archive (a local file header), which a Lottie JSON text never does.
    static func isArchive(_ bytes: [UInt8]) -> Bool {
        bytes.count >= 4 && bytes[0] == 0x50 && bytes[1] == 0x4B && bytes[2] == 0x03 && bytes[3] == 0x04
    }

    /// The JSON of the archive's first animation: the first `animations/….json` entry in the central directory.
    static func animationJSON(_ bytes: [UInt8]) throws -> [UInt8] {
        let entries = try centralDirectory(bytes)
        guard let entry = entries.first(where: isAnimation)
        else { throw Failure.noAnimation }
        return try contents(of: entry, in: bytes)
    }

    /// An entry under `animations/` whose name ends in `.json`, compared byte by byte: the Embedded build has no Unicode
    /// tables for `String.hasPrefix`.
    static func isAnimation(_ entry: Entry) -> Bool {
        let prefix = Array("animations/".utf8)
        let suffix = Array(".json".utf8)
        let name = entry.name
        return name.count > prefix.count + suffix.count && Array(name[0 ..< prefix.count]) == prefix
            && Array(name[(name.count - suffix.count)...]) == suffix
    }

    struct Entry {
        var name: [UInt8]
        var method: Int
        var compressedSize: Int
        var size: Int
        var localHeader: Int
    }

    /// The entries listed by the central directory, which records each entry's sizes even when the local header leaves
    /// them to a data descriptor written after the data.
    static func centralDirectory(_ bytes: [UInt8]) throws -> [Entry] {
        guard isArchive(bytes) else { throw Failure.notAnArchive }
        // The end-of-central-directory record is the last 22 bytes, unless a comment (up to 65 535 bytes) follows it.
        var end = bytes.count - 22
        let lowest = max(0, bytes.count - 22 - 65_535)
        while end >= lowest, readUInt32(bytes, end) != 0x0605_4B50 {
            end -= 1
        }
        guard end >= lowest else { throw Failure.corrupt }
        let count = readUInt16(bytes, end + 10)
        var offset = readUInt32(bytes, end + 16)
        var entries: [Entry] = []
        for _ in 0 ..< count {
            guard offset + 46 <= bytes.count, readUInt32(bytes, offset) == 0x0201_4B50 else { throw Failure.corrupt }
            let nameLength = readUInt16(bytes, offset + 28)
            let extraLength = readUInt16(bytes, offset + 30)
            let commentLength = readUInt16(bytes, offset + 32)
            guard offset + 46 + nameLength <= bytes.count else { throw Failure.corrupt }
            entries.append(Entry(
                name: Array(bytes[(offset + 46) ..< (offset + 46 + nameLength)]),
                method: readUInt16(bytes, offset + 10),
                compressedSize: readUInt32(bytes, offset + 20),
                size: readUInt32(bytes, offset + 24),
                localHeader: readUInt32(bytes, offset + 42)
            ))
            offset += 46 + nameLength + extraLength + commentLength
        }
        return entries
    }

    static func contents(of entry: Entry, in bytes: [UInt8]) throws -> [UInt8] {
        let header = entry.localHeader
        guard header + 30 <= bytes.count, readUInt32(bytes, header) == 0x0403_4B50 else { throw Failure.corrupt }
        let start = header + 30 + readUInt16(bytes, header + 26) + readUInt16(bytes, header + 28)
        guard start + entry.compressedSize <= bytes.count else { throw Failure.corrupt }
        let data = Array(bytes[start ..< (start + entry.compressedSize)])
        switch entry.method {
        case 0:
            return data
        case 8:
            var inflater = Inflater(input: data, expectedSize: entry.size)
            return try inflater.run()
        default:
            throw Failure.unsupportedCompression
        }
    }

    static func readUInt16(_ bytes: [UInt8], _ offset: Int) -> Int {
        Int(bytes[offset]) | Int(bytes[offset + 1]) << 8
    }

    static func readUInt32(_ bytes: [UInt8], _ offset: Int) -> Int {
        guard offset >= 0, offset + 4 <= bytes.count else { return -1 }
        return readUInt16(bytes, offset) | readUInt16(bytes, offset + 2) << 16
    }
}

/// A DEFLATE decoder (RFC 1951) after Mark Adler's puff: canonical Huffman codes decoded bit by bit, which is short and
/// plenty fast for an animation of a few hundred kilobytes.
struct Inflater {
    private let input: [UInt8]
    private var position = 0
    private var bitBuffer = 0
    private var bitCount = 0
    private var output: [UInt8] = []

    init(input: [UInt8], expectedSize: Int) {
        self.input = input
        output.reserveCapacity(expectedSize)
    }

    mutating func run() throws -> [UInt8] {
        var last = false
        while !last {
            last = try bits(1) == 1
            switch try bits(2) {
            case 0: try stored()
            case 1: try codes(Inflater.fixedLengths, Inflater.fixedDistances)
            case 2: try dynamic()
            default: throw DotLottieArchive.Failure.corrupt
            }
        }
        return output
    }

    private mutating func bits(_ need: Int) throws -> Int {
        var value = bitBuffer
        while bitCount < need {
            guard position < input.count else { throw DotLottieArchive.Failure.corrupt }
            value |= Int(input[position]) << bitCount
            position += 1
            bitCount += 8
        }
        bitBuffer = value >> need
        bitCount -= need
        return value & ((1 << need) - 1)
    }

    private mutating func stored() throws {
        bitBuffer = 0
        bitCount = 0
        guard position + 4 <= input.count else { throw DotLottieArchive.Failure.corrupt }
        let length = Int(input[position]) | Int(input[position + 1]) << 8
        let complement = Int(input[position + 2]) | Int(input[position + 3]) << 8
        position += 4
        guard length == ~complement & 0xFFFF, position + length <= input.count else {
            throw DotLottieArchive.Failure.corrupt
        }
        output.append(contentsOf: input[position ..< (position + length)])
        position += length
    }

    struct Huffman {
        var count = [Int](repeating: 0, count: 16)
        var symbol: [Int]

        init(lengths: [Int]) {
            symbol = [Int](repeating: 0, count: lengths.count)
            for length in lengths {
                count[length] += 1
            }
            var offsets = [Int](repeating: 0, count: 16)
            for length in 1 ..< 15 {
                offsets[length + 1] = offsets[length] + count[length]
            }
            for (value, length) in lengths.enumerated() where length != 0 {
                symbol[offsets[length]] = value
                offsets[length] += 1
            }
        }
    }

    private mutating func decode(_ huffman: Huffman) throws -> Int {
        var code = 0
        var first = 0
        var index = 0
        for length in 1 ..< 16 {
            code |= try bits(1)
            let count = huffman.count[length]
            if code - count < first {
                return huffman.symbol[index + (code - first)]
            }
            index += count
            first = (first + count) << 1
            code <<= 1
        }
        throw DotLottieArchive.Failure.corrupt
    }

    private static let lengthBase = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258]
    private static let lengthExtra = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0]
    private static let distanceBase = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577]
    private static let distanceExtra = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13]

    private static let fixedLengths = Huffman(lengths: [Int](repeating: 8, count: 144) + [Int](repeating: 9, count: 112)
        + [Int](repeating: 7, count: 24) + [Int](repeating: 8, count: 8))
    private static let fixedDistances = Huffman(lengths: [Int](repeating: 5, count: 30))

    private mutating func codes(_ lengths: Huffman, _ distances: Huffman) throws {
        while true {
            let symbol = try decode(lengths)
            if symbol < 256 {
                output.append(UInt8(symbol))
            } else if symbol == 256 {
                return
            } else {
                let index = symbol - 257
                guard index < 29 else { throw DotLottieArchive.Failure.corrupt }
                let length = Inflater.lengthBase[index] + (try bits(Inflater.lengthExtra[index]))
                let code = try decode(distances)
                guard code < 30 else { throw DotLottieArchive.Failure.corrupt }
                let distance = Inflater.distanceBase[code] + (try bits(Inflater.distanceExtra[code]))
                guard distance <= output.count else { throw DotLottieArchive.Failure.corrupt }
                let from = output.count - distance
                for offset in 0 ..< length {
                    output.append(output[from + offset])
                }
            }
        }
    }

    private static let codeLengthOrder = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]

    private mutating func dynamic() throws {
        let lengthCount = try bits(5) + 257
        let distanceCount = try bits(5) + 1
        let codeCount = try bits(4) + 4
        guard lengthCount <= 286, distanceCount <= 30 else { throw DotLottieArchive.Failure.corrupt }
        var codeLengths = [Int](repeating: 0, count: 19)
        for index in 0 ..< codeCount {
            codeLengths[Inflater.codeLengthOrder[index]] = try bits(3)
        }
        let codeLengthCode = Huffman(lengths: codeLengths)
        var lengths: [Int] = []
        lengths.reserveCapacity(lengthCount + distanceCount)
        while lengths.count < lengthCount + distanceCount {
            let symbol = try decode(codeLengthCode)
            if symbol < 16 {
                lengths.append(symbol)
                continue
            }
            var repeated = 0
            var times: Int
            switch symbol {
            case 16:
                guard let previous = lengths.last else { throw DotLottieArchive.Failure.corrupt }
                repeated = previous
                times = 3 + (try bits(2))
            case 17:
                times = 3 + (try bits(3))
            default:
                times = 11 + (try bits(7))
            }
            guard lengths.count + times <= lengthCount + distanceCount else { throw DotLottieArchive.Failure.corrupt }
            lengths.append(contentsOf: [Int](repeating: repeated, count: times))
        }
        try codes(Huffman(lengths: Array(lengths[0 ..< lengthCount])),
                  Huffman(lengths: Array(lengths[lengthCount...])))
    }
}
#endif
