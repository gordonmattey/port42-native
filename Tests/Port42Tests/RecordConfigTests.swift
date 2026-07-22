import Testing
import Foundation
@testable import Port42Lib

// RecordConfig.from(sourceSize:displayScale:opts:) — the pure options→config derivation for
// screen.record (docs/plan-screen-record.md Step 1). Headless: no ScreenCaptureKit, no display.
@Suite("RecordConfig")
struct RecordConfigTests {

    private let source = CGSize(width: 1728, height: 1079)

    @Test("default scale = display scale when no scale/dimensions given")
    func defaultScale() {
        let c = RecordConfig.from(sourceSize: source, displayScale: 2.0, opts: [:])
        #expect(c.width == 3456)
        #expect(c.height == 2158)
    }

    @Test("scale:1 yields the point size (the scale fix)")
    func scaleOne() {
        let c = RecordConfig.from(sourceSize: source, displayScale: 2.0, opts: ["scale": 1.0])
        #expect(c.width == 1728)
        #expect(c.height == 1079)
    }

    @Test("scale:2 doubles the point size")
    func scaleTwo() {
        let c = RecordConfig.from(sourceSize: source, displayScale: 1.0, opts: ["scale": 2.0])
        #expect(c.width == 3456)
        #expect(c.height == 2158)
    }

    @Test("explicit width/height override scale")
    func explicitDimensions() {
        let c = RecordConfig.from(sourceSize: source, displayScale: 2.0,
                                  opts: ["width": 1920, "height": 1080, "scale": 3.0])
        #expect(c.width == 1920)
        #expect(c.height == 1080)
    }

    @Test("fps defaults to 30, honored when given")
    func fps() {
        #expect(RecordConfig.from(sourceSize: source, displayScale: 1.0, opts: [:]).fps == 30)
        #expect(RecordConfig.from(sourceSize: source, displayScale: 1.0, opts: ["fps": 60]).fps == 60)
    }

    @Test("fps floors at 1")
    func fpsFloor() {
        #expect(RecordConfig.from(sourceSize: source, displayScale: 1.0, opts: ["fps": 0]).fps == 1)
    }

    @Test("cursor defaults off, honored when set")
    func cursor() {
        #expect(RecordConfig.from(sourceSize: source, displayScale: 1.0, opts: [:]).showsCursor == false)
        #expect(RecordConfig.from(sourceSize: source, displayScale: 1.0, opts: ["cursor": true]).showsCursor == true)
    }

    @Test("audio:none captures neither system nor mic")
    func audioNone() {
        let c = RecordConfig.from(sourceSize: source, displayScale: 1.0, opts: [:])
        #expect(c.capturesAudio == false)
        #expect(c.captureMicrophone == false)
    }

    @Test("audio:system captures system only")
    func audioSystem() {
        let c = RecordConfig.from(sourceSize: source, displayScale: 1.0, opts: ["audio": "system"])
        #expect(c.capturesAudio == true)
        #expect(c.captureMicrophone == false)
    }

    @Test("audio:mic captures mic only")
    func audioMic() {
        let c = RecordConfig.from(sourceSize: source, displayScale: 1.0, opts: ["audio": "mic"])
        #expect(c.capturesAudio == false)
        #expect(c.captureMicrophone == true)
    }

    @Test("audio:both captures system and mic")
    func audioBoth() {
        let c = RecordConfig.from(sourceSize: source, displayScale: 1.0, opts: ["audio": "both"])
        #expect(c.capturesAudio == true)
        #expect(c.captureMicrophone == true)
    }

    @Test("format defaults to mov; mp4 selects mp4 file type")
    func format() {
        #expect(RecordConfig.from(sourceSize: source, displayScale: 1.0, opts: [:]).fileType == .mov)
        #expect(RecordConfig.from(sourceSize: source, displayScale: 1.0, opts: ["format": "mp4"]).fileType == .mp4)
        #expect(RecordConfig.from(sourceSize: source, displayScale: 1.0, opts: ["format": "mp4"]).avFileType == .mp4)
    }

    @Test("integer scale value is accepted (JSON may send Int)")
    func intScale() {
        let c = RecordConfig.from(sourceSize: source, displayScale: 2.0, opts: ["scale": 1])
        #expect(c.width == 1728)
    }
}
