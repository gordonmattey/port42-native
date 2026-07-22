import Testing
import Foundation
import CoreGraphics
@testable import Port42Lib

// RecordFraming — the pure union-bbox + aspect/fit math for screen.record (Step 2). Headless.
@Suite("RecordFraming")
struct RecordFramingTests {

    // MARK: - unionBBox

    @Test("unionBBox of empty is nil")
    func unionEmpty() {
        #expect(RecordFraming.unionBBox([], padding: 0) == nil)
    }

    @Test("unionBBox of one rect + padding inflates on all sides")
    func unionOne() {
        let r = CGRect(x: 100, y: 100, width: 200, height: 100)
        let box = RecordFraming.unionBBox([r], padding: 10)
        #expect(box == CGRect(x: 90, y: 90, width: 220, height: 120))
    }

    @Test("unionBBox of two rects spans both + padding")
    func unionTwo() {
        let a = CGRect(x: 0, y: 0, width: 100, height: 100)
        let b = CGRect(x: 200, y: 150, width: 100, height: 100)
        let box = RecordFraming.unionBBox([a, b], padding: 0)
        #expect(box == CGRect(x: 0, y: 0, width: 300, height: 250))
    }

    @Test("unionBBox of N rects spans the extremes")
    func unionN() {
        let rects = [
            CGRect(x: 50, y: 50, width: 10, height: 10),
            CGRect(x: 400, y: 20, width: 10, height: 10),
            CGRect(x: 100, y: 300, width: 10, height: 10)
        ]
        let box = RecordFraming.unionBBox(rects, padding: 5)
        // x: 50..410, y: 20..310, then inset by -5
        #expect(box == CGRect(x: 45, y: 15, width: 370, height: 300))
    }

    // MARK: - parseAspect

    @Test("parseAspect parses W:H")
    func aspectParse() {
        #expect(RecordFraming.parseAspect("16:9") == 16.0 / 9.0)
        #expect(RecordFraming.parseAspect("1:1") == 1.0)
    }

    @Test("parseAspect returns nil for malformed input")
    func aspectMalformed() {
        #expect(RecordFraming.parseAspect(nil) == nil)
        #expect(RecordFraming.parseAspect("169") == nil)
        #expect(RecordFraming.parseAspect("16:0") == nil)
        #expect(RecordFraming.parseAspect("a:b") == nil)
    }

    // MARK: - evenInt

    @Test("evenInt rounds up odd to even, floors at 2")
    func even() {
        #expect(RecordFraming.evenInt(1079) == 1080)
        #expect(RecordFraming.evenInt(1078) == 1078)
        #expect(RecordFraming.evenInt(0) == 2)
        #expect(RecordFraming.evenInt(1) == 2)
    }

    // MARK: - resolve: no mismatch collapses to the box

    @Test("no aspect/dims → sourceRect is the box, dims = box × scale (even)")
    func resolveNoRequest() throws {
        let box = CGRect(x: 0, y: 0, width: 800, height: 450)
        let r = try RecordFraming.resolve(bbox: box, aspect: nil, fit: .contain,
                                          width: nil, height: nil, scale: 2.0)
        #expect(r.sourceRect == box)
        #expect(r.width == 1600)
        #expect(r.height == 900)
    }

    @Test("aspect equal to box aspect does not error even with fit:contain")
    func resolveMatchingAspect() throws {
        let box = CGRect(x: 0, y: 0, width: 1600, height: 900)   // 16:9
        let r = try RecordFraming.resolve(bbox: box, aspect: "16:9", fit: .contain,
                                          width: nil, height: nil, scale: 1.0)
        #expect(r.sourceRect == box)
        #expect(r.width == 1600)
        #expect(r.height == 900)
    }

    // MARK: - resolve: mismatch

    @Test("fit:contain with an aspect mismatch throws containNotSupported")
    func resolveContainThrows() {
        let box = CGRect(x: 0, y: 0, width: 800, height: 600)    // 4:3
        #expect(throws: RecordFramingError.containNotSupported) {
            _ = try RecordFraming.resolve(bbox: box, aspect: "16:9", fit: .contain,
                                          width: nil, height: nil, scale: 1.0)
        }
    }

    @Test("fit:exact keeps the box as sourceRect and stretches into the aspect")
    func resolveExact() throws {
        let box = CGRect(x: 10, y: 20, width: 800, height: 600)  // 4:3
        let r = try RecordFraming.resolve(bbox: box, aspect: "16:9", fit: .exact,
                                          width: 1920, height: 1080, scale: 1.0)
        #expect(r.sourceRect == box)          // no crop, stretched
        #expect(r.width == 1920)
        #expect(r.height == 1080)
    }

    @Test("fit:cover widens the sourceRect to a wider aspect, centered")
    func resolveCoverWiden() throws {
        let box = CGRect(x: 0, y: 0, width: 600, height: 600)    // 1:1
        let r = try RecordFraming.resolve(bbox: box, aspect: "2:1", fit: .cover,
                                          width: nil, height: nil, scale: 1.0)
        // target 2:1 > 1:1 → widen: newW = 600 * 2 = 1200, centered about midX=300
        #expect(r.sourceRect == CGRect(x: -300, y: 0, width: 1200, height: 600))
    }

    @Test("fit:cover heightens the sourceRect for a taller aspect, centered")
    func resolveCoverHeighten() throws {
        let box = CGRect(x: 0, y: 0, width: 600, height: 600)    // 1:1
        let r = try RecordFraming.resolve(bbox: box, aspect: "1:2", fit: .cover,
                                          width: nil, height: nil, scale: 1.0)
        // target 1:2 < 1:1 → heighten: newH = 600 / 0.5 = 1200, centered about midY=300
        #expect(r.sourceRect == CGRect(x: 0, y: -300, width: 600, height: 1200))
    }

    @Test("explicit width alone derives height from the output aspect")
    func resolveWidthOnly() throws {
        let box = CGRect(x: 0, y: 0, width: 1000, height: 500)   // 2:1, matches
        let r = try RecordFraming.resolve(bbox: box, aspect: "2:1", fit: .cover,
                                          width: 1280, height: nil, scale: 1.0)
        #expect(r.width == 1280)
        #expect(r.height == 640)
    }
}
