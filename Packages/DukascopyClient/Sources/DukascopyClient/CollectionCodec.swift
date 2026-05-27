import Foundation

/// Classes the wire protocol references by their canonical-name hashCode.
public enum WireType {
    public static let setClass     = "java.util.Set"
    public static let hashSetClass = "java.util.HashSet"
    public static let stringClass  = "java.lang.String"
    public static let listClass    = "java.util.List"
    public static let arrayListClass = "java.util.ArrayList"
}

public extension BinaryWriter {
    /// Encodes a `Set<String>` exactly like the Java client's `CollectionCodec`:
    /// `classId(collectionType) + varLen(size) + size * [classId(String) + varLen(byteLen) + bytes]`.
    mutating func writeStringSet(_ values: Set<String>, declaredType: String = WireType.setClass) {
        writeInt32BE(javaStringHashCode(declaredType))
        writeVarLen(values.count)
        let stringClassId = javaStringHashCode(WireType.stringClass)
        for v in values {
            writeInt32BE(stringClassId)
            writeString(v)
        }
    }
}

public extension BinaryReader {
    /// Inverse of `writeStringSet`. Ignores element class ids since we know
    /// every element must be a String for these fields.
    mutating func readStringList() throws -> [String] {
        _ = try readInt32BE()  // declared collection type — ignored
        let size = try readVarLen()
        var out: [String] = []
        out.reserveCapacity(size)
        for _ in 0..<size {
            _ = try readInt32BE()  // element class id — must be String
            out.append(try readString())
        }
        return out
    }
}
