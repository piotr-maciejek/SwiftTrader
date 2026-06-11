import Foundation
import Testing
@testable import DukascopyClient

@Suite("History chunk assembly")
struct ChunkAssemblyTests {

    @Test("Contiguous chunks assemble in index order")
    func contiguousAssembles() throws {
        let chunks: [Int32: String] = [0: "a", 1: "b", 2: "c"]
        let out = try DukascopySession.orderedChunks(chunks, maxOrder: 2)
        #expect(out == ["a", "b", "c"])
    }

    @Test("A missing middle chunk fails assembly instead of returning partial data")
    func missingMiddleThrows() {
        let chunks: [Int32: String] = [0: "a", 2: "c"]
        #expect(throws: DukascopySession.SessionError.self) {
            _ = try DukascopySession.orderedChunks(chunks, maxOrder: 2)
        }
    }

    @Test("A request that finished with no chunks assembles to empty")
    func noChunksIsEmpty() throws {
        let out = try DukascopySession.orderedChunks([Int32: String](), maxOrder: -1)
        #expect(out.isEmpty)
    }

    @Test("An empty payload at a seen index is complete, not a hole")
    func emptyPayloadCounts() throws {
        let chunks: [Int32: Data] = [0: Data("x".utf8), 1: Data()]
        let out = try DukascopySession.orderedChunks(chunks, maxOrder: 1)
        #expect(out.count == 2)
        #expect(out[1].isEmpty)
    }

    @Test("Chunk index bounds: negatives and oversized indices are rejected, the cap itself is not")
    func chunkIndexBounds() {
        #expect(!DukascopySession.validChunkIndex(-1))
        #expect(!DukascopySession.validChunkIndex(Int32.max))
        #expect(!DukascopySession.validChunkIndex(DukascopySession.maxChunkOrder + 1))
        #expect(DukascopySession.validChunkIndex(0))
        #expect(DukascopySession.validChunkIndex(DukascopySession.maxChunkOrder))
    }

    @Test("Assembly at the cap stays fast even when almost every index is missing")
    func cappedAssemblyIsBounded() {
        // One chunk at index 0, finished flag claiming the cap as maxOrder: the
        // completeness check must fail in bounded time rather than spin.
        let chunks: [Int32: String] = [0: "a"]
        let t0 = Date()
        #expect(throws: DukascopySession.SessionError.self) {
            _ = try DukascopySession.orderedChunks(chunks, maxOrder: DukascopySession.maxChunkOrder)
        }
        #expect(Date().timeIntervalSince(t0) < 1.0)
    }
}
