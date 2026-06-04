import Foundation
import Testing

import Transcript

@Suite("ResultDecoder")
struct ResultDecoderTests {

    @Test func successfulResultYieldsText() {
        let json = #"{"type":"result","subtype":"success","is_error":false,"result":"hello world","session_id":"abc"}"#
        let result = decodeHarnessResult(Data(json.utf8))
        #expect(result?.text == "hello world")
        #expect(result?.isError == false)
    }

    @Test func errorResultIsFlagged() {
        let json = #"{"type":"result","subtype":"error_max_turns","is_error":true,"result":"","session_id":"abc"}"#
        let result = decodeHarnessResult(Data(json.utf8))
        #expect(result?.text == "")
        #expect(result?.isError == true)
    }

    @Test func missingResultFieldReturnsNil() {
        let json = #"{"type":"result","is_error":false,"session_id":"abc"}"#
        let result = decodeHarnessResult(Data(json.utf8))
        #expect(result == nil)
    }

    @Test func malformedJsonReturnsNil() {
        let result = decodeHarnessResult(Data("not valid json".utf8))
        #expect(result == nil)
    }

    @Test func nonResultTypeReturnsNil() {
        let json = #"{"type":"message_start","message":{"id":"msg_abc"}}"#
        let result = decodeHarnessResult(Data(json.utf8))
        #expect(result == nil)
    }
}
