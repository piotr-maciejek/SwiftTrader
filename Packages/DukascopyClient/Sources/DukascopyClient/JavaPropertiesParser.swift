import Foundation

/// Extracts the String→String entries from a Java-serialized `java.util.Properties`
/// (an `ObjectOutputStream` blob). The settings ("occasus") blob returned at auth is
/// such a Properties; we need `history.server.url` (and a few others) out of it.
///
/// This implements only the subset of the Java serialization grammar a Properties blob
/// exercises: the class-descriptor hierarchy (Properties → Hashtable), primitive field
/// values, and the `Hashtable.writeObject` annotation that holds the (key, value) pairs.
/// Non-string values (arrays, nested objects) are skipped; only entries whose key and
/// value are both strings are returned.
public enum JavaPropertiesParser {
    public enum ParseError: Error, CustomStringConvertible {
        case badMagic
        case truncated
        case unsupportedTag(UInt8)
        case badReference(Int)

        public var description: String {
            switch self {
            case .badMagic: "not a Java-serialization stream (bad magic)"
            case .truncated: "stream ended unexpectedly"
            case .unsupportedTag(let t): "unsupported type tag 0x\(String(t, radix: 16))"
            case .badReference(let h): "dangling back-reference handle \(h)"
            }
        }
    }

    public static func parse(_ blob: Data) throws -> [String: String] {
        var reader = JavaObjectReader(blob)
        try reader.readStreamHeader()
        _ = try reader.readObject()       // the root Properties; entries collected as a side effect
        return reader.entries
    }
}

// MARK: - Reader

private struct JavaObjectReader {
    // Java serialization stream constants.
    private static let magic: UInt16 = 0xACED
    private static let tcNull: UInt8 = 0x70
    private static let tcReference: UInt8 = 0x71
    private static let tcClassDesc: UInt8 = 0x72
    private static let tcObject: UInt8 = 0x73
    private static let tcString: UInt8 = 0x74
    private static let tcArray: UInt8 = 0x75
    private static let tcClass: UInt8 = 0x76
    private static let tcBlockData: UInt8 = 0x77
    private static let tcEndBlockData: UInt8 = 0x78
    private static let tcReset: UInt8 = 0x79
    private static let tcBlockDataLong: UInt8 = 0x7A
    private static let tcLongString: UInt8 = 0x7C
    private static let tcProxyClassDesc: UInt8 = 0x7D
    private static let tcEnum: UInt8 = 0x7E
    private static let baseWireHandle = 0x7E0000

    private static let scWriteMethod: UInt8 = 0x01
    private static let scSerializable: UInt8 = 0x02
    private static let scExternalizable: UInt8 = 0x04

    private let bytes: [UInt8]
    private var pos = 0
    /// newHandle() registers each object/string/classdesc in write order; TC_REFERENCE
    /// resolves back into this table.
    private var handles: [Any?] = []

    /// Accumulated String→String pairs found in Hashtable writeObject annotations.
    private(set) var entries: [String: String] = [:]

    init(_ data: Data) { self.bytes = [UInt8](data) }

    // MARK: primitives

    private mutating func u8() throws -> UInt8 {
        guard pos < bytes.count else { throw JavaPropertiesParser.ParseError.truncated }
        defer { pos += 1 }
        return bytes[pos]
    }

    private mutating func u16() throws -> Int {
        let hi = Int(try u8()), lo = Int(try u8())
        return (hi << 8) | lo
    }

    private mutating func u32() throws -> Int {
        var v = 0
        for _ in 0..<4 { v = (v << 8) | Int(try u8()) }
        return v
    }

    private mutating func u64() throws -> UInt64 {
        var v: UInt64 = 0
        for _ in 0..<8 { v = (v << 8) | UInt64(try u8()) }
        return v
    }

    private mutating func skip(_ n: Int) throws {
        guard pos + n <= bytes.count else { throw JavaPropertiesParser.ParseError.truncated }
        pos += n
    }

    private mutating func peek() throws -> UInt8 {
        guard pos < bytes.count else { throw JavaPropertiesParser.ParseError.truncated }
        return bytes[pos]
    }

    /// Reads a modified-UTF-8 string of the given byte length. ASCII (our keys/URLs)
    /// decodes identically; fall back to lenient UTF-8 for anything else.
    private mutating func utf(_ length: Int) throws -> String {
        guard pos + length <= bytes.count else { throw JavaPropertiesParser.ParseError.truncated }
        let slice = bytes[pos..<pos + length]
        pos += length
        return String(decoding: slice, as: UTF8.self)
    }

    private mutating func newHandle(_ value: Any?) -> Int {
        handles.append(value)
        return Self.baseWireHandle + handles.count - 1
    }

    private mutating func setHandle(_ handle: Int, _ value: Any?) {
        let idx = handle - Self.baseWireHandle
        if idx >= 0 && idx < handles.count { handles[idx] = value }
    }

    // MARK: stream

    mutating func readStreamHeader() throws {
        let m = try u16()
        let ver = try u16()
        guard m == Int(Self.magic), ver == 0x0005 else { throw JavaPropertiesParser.ParseError.badMagic }
    }

    /// Reads one content element. Returns a decoded String for string tags (so callers
    /// can pair Hashtable keys/values), or nil for null/objects/arrays/blocks.
    mutating func readObject() throws -> String? {
        let tag = try u8()
        switch tag {
        case Self.tcNull:
            return nil
        case Self.tcString:
            let len = try u16()
            let s = try utf(len)
            _ = newHandle(s)
            return s
        case Self.tcLongString:
            let len = Int(try u64())
            let s = try utf(len)
            _ = newHandle(s)
            return s
        case Self.tcReference:
            let handle = try u32()
            let idx = handle - Self.baseWireHandle
            guard idx >= 0 && idx < handles.count else { throw JavaPropertiesParser.ParseError.badReference(handle) }
            return handles[idx] as? String
        case Self.tcObject:
            try readNewObject()
            return nil
        case Self.tcArray:
            try readNewArray()
            return nil
        case Self.tcEnum:
            try readNewEnum()
            return nil
        case Self.tcClass:
            _ = try readClassDesc()
            _ = newHandle(nil)
            return nil
        case Self.tcBlockData:
            let len = Int(try u8())
            try skip(len)
            return nil
        case Self.tcBlockDataLong:
            let len = try u32()
            try skip(len)
            return nil
        case Self.tcReset:
            handles.removeAll()
            return try readObject()
        default:
            throw JavaPropertiesParser.ParseError.unsupportedTag(tag)
        }
    }

    // MARK: class descriptors

    private struct FieldDesc { let type: Character; let name: String }
    private final class ClassDesc {
        var name = ""
        var flags: UInt8 = 0
        var fields: [FieldDesc] = []
        var superClass: ClassDesc?
    }

    private mutating func readClassDesc() throws -> ClassDesc? {
        let tag = try u8()
        switch tag {
        case Self.tcNull:
            return nil
        case Self.tcReference:
            let handle = try u32()
            let idx = handle - Self.baseWireHandle
            guard idx >= 0 && idx < handles.count else { throw JavaPropertiesParser.ParseError.badReference(handle) }
            return handles[idx] as? ClassDesc
        case Self.tcClassDesc:
            let desc = ClassDesc()
            let nameLen = try u16()
            desc.name = try utf(nameLen)
            try skip(8)                       // serialVersionUID
            _ = newHandle(desc)               // classdesc gets a handle BEFORE its fields
            desc.flags = try u8()
            let fieldCount = try u16()
            for _ in 0..<fieldCount {
                let typeCode = Character(UnicodeScalar(try u8()))
                let fnLen = try u16()
                let fieldName = try utf(fnLen)
                if typeCode == "[" || typeCode == "L" {
                    // field's class name: a string object (TC_STRING or TC_REFERENCE)
                    _ = try readObject()
                }
                desc.fields.append(FieldDesc(type: typeCode, name: fieldName))
            }
            try readClassAnnotation()         // usually just TC_ENDBLOCKDATA
            desc.superClass = try readClassDesc()
            return desc
        case Self.tcProxyClassDesc:
            // Not expected in a Properties blob; walk past interfaces + annotation + super.
            let desc = ClassDesc()
            _ = newHandle(desc)
            let count = try u32()
            for _ in 0..<count { let l = try u16(); _ = try utf(l) }
            try readClassAnnotation()
            desc.superClass = try readClassDesc()
            return desc
        default:
            throw JavaPropertiesParser.ParseError.unsupportedTag(tag)
        }
    }

    private mutating func readClassAnnotation() throws {
        while true {
            if try peek() == Self.tcEndBlockData { pos += 1; return }
            _ = try readObject()
        }
    }

    // MARK: object / array / enum bodies

    private mutating func readNewObject() throws {
        guard let desc = try readClassDesc() else { return }
        _ = newHandle(nil)                    // the object instance handle
        // Walk the class hierarchy top-down (super first) reading each level's data.
        var chain: [ClassDesc] = []
        var c: ClassDesc? = desc
        while let cls = c { chain.append(cls); c = cls.superClass }
        for cls in chain.reversed() {
            try readClassData(cls)
        }
    }

    private mutating func readClassData(_ cls: ClassDesc) throws {
        guard (cls.flags & Self.scSerializable) != 0 else {
            // Externalizable or no data — best effort: stop here.
            return
        }
        for field in cls.fields { try readFieldValue(field) }
        if (cls.flags & Self.scWriteMethod) != 0 {
            try readWriteMethodAnnotation(for: cls)
        }
    }

    /// Reads the bytes for one serializable field value. Primitives are inline; object
    /// fields recurse through readObject. We only retain strings (in entries via the
    /// Hashtable path); here object field values are read and discarded.
    private mutating func readFieldValue(_ field: FieldDesc) throws {
        switch field.type {
        case "B", "Z": try skip(1)
        case "C", "S": try skip(2)
        case "I", "F": try skip(4)
        case "J", "D": try skip(8)
        case "L", "[": _ = try readObject()
        default: throw JavaPropertiesParser.ParseError.unsupportedTag(UInt8(field.type.asciiValue ?? 0))
        }
    }

    /// The writeObject annotation. For Hashtable this carries the entries: a block-data
    /// header (capacity, size) followed by `size` (key, value) object pairs, then
    /// TC_ENDBLOCKDATA. We special-case Hashtable to pair keys/values; for any other
    /// class we just walk to the end-block.
    private mutating func readWriteMethodAnnotation(for cls: ClassDesc) throws {
        if cls.name == "java.util.Hashtable" {
            // Leading block-data: [int capacity][int size].
            let tag = try u8()
            var size = 0
            if tag == Self.tcBlockData {
                let len = Int(try u8())
                let start = pos
                _ = try u32()                 // capacity
                size = try u32()
                // Tolerate any extra block bytes beyond the 8 we expect.
                let consumed = pos - start
                if consumed < len { try skip(len - consumed) }
            } else if tag == Self.tcBlockDataLong {
                let len = try u32()
                let start = pos
                _ = try u32()
                size = try u32()
                let consumed = pos - start
                if consumed < len { try skip(len - consumed) }
            } else {
                pos -= 1                       // not a block; bail to generic walk
            }
            for _ in 0..<size {
                let key = try readObject()
                let value = try readObject()
                if let key, let value { entries[key] = value }
            }
        }
        // Consume any trailing annotation content up to and including TC_ENDBLOCKDATA.
        while true {
            if pos >= bytes.count { return }
            if try peek() == Self.tcEndBlockData { pos += 1; return }
            _ = try readObject()
        }
    }

    private mutating func readNewArray() throws {
        guard let desc = try readClassDesc() else { return }
        _ = newHandle(nil)
        let size = try u32()
        // Component type is the second char of the array class name, e.g. "[I" → 'I'.
        let comp = desc.name.count >= 2 ? Array(desc.name)[1] : "L"
        for _ in 0..<size {
            switch comp {
            case "B", "Z": try skip(1)
            case "C", "S": try skip(2)
            case "I", "F": try skip(4)
            case "J", "D": try skip(8)
            default: _ = try readObject()
            }
        }
    }

    private mutating func readNewEnum() throws {
        _ = try readClassDesc()
        _ = newHandle(nil)
        _ = try readObject()                   // the constant name (string)
    }
}
