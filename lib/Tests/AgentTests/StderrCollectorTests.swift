import Foundation
import Testing
@testable import Agent

@Suite("StderrCollector")
struct StderrCollectorTests {
    @Test func underCapPreservesVerbatim() {
        var c = StderrCollector(cap: 64)
        c.append(Data("hello world".utf8))
        #expect(c.tail == "hello world")
    }

    @Test func exactCapPreservesVerbatim() {
        var c = StderrCollector(cap: 8)
        c.append(Data("12345678".utf8))
        #expect(c.tail == "12345678")
    }

    @Test func overCapDropsOldest() {
        var c = StderrCollector(cap: 8)
        c.append(Data("AAAAAAAA".utf8))
        c.append(Data("BBBB".utf8))
        #expect(c.tail == "AAAABBBB")
    }

    @Test func manySmallChunksRoundTrip() {
        let payload = Data("AAAABBBBCCCCDDDDEEEE".utf8) // 20 bytes, over cap of 16
        var once = StderrCollector(cap: 16)
        once.append(payload)
        var chunked = StderrCollector(cap: 16)
        for byte in payload {
            chunked.append(Data([byte]))
        }
        #expect(once.tail == chunked.tail)
        #expect(once.tail == "BBBBCCCCDDDDEEEE")
    }
}
