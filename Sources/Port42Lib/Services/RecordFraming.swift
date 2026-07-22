import Foundation
import CoreGraphics

// MARK: - Screen Recorder framing math (screen.record, docs/plan-screen-record.md — Step 2)

/// Pure framing math for `screen.record`: the union bounding box over port tile rects, and the
/// aspect/fit derivation from a content box to a `sourceRect` + output dimensions. No ScreenCaptureKit
/// and no shell state, so it is fully headless-unit-testable — it is the risky part of Step 2.
///
/// Coordinate space: all rects are window-relative POINTS, top-left origin (Spike C). Output width and
/// height are pixels. `contain` (letterbox) is Step 6; v1 supports `cover` and `exact`, and a
/// `contain` request whose aspect differs from the box returns `.containNotSupported` (a legible
/// refusal rather than a silently wrong frame).
public enum RecordFit: String { case contain, cover, exact }

public enum RecordFramingError: Error, Equatable {
    case containNotSupported
    case emptyTargets
}

public struct RecordFraming {

    public struct Result: Equatable {
        public var sourceRect: CGRect
        public var width: Int
        public var height: Int
    }

    /// Bounding box of `rects`, inflated by `padding` on every side. nil if empty.
    public static func unionBBox(_ rects: [CGRect], padding: CGFloat) -> CGRect? {
        guard let first = rects.first else { return nil }
        var box = first
        for r in rects.dropFirst() { box = box.union(r) }
        return box.insetBy(dx: -padding, dy: -padding)
    }

    /// Parse "W:H" → aspect ratio (w/h). nil if malformed (a malformed aspect is treated as "no
    /// aspect" by the caller, not an error).
    public static func parseAspect(_ s: String?) -> Double? {
        guard let s, s.contains(":") else { return nil }
        let parts = s.split(separator: ":")
        guard parts.count == 2,
              let w = Double(parts[0]), let h = Double(parts[1]),
              w > 0, h > 0 else { return nil }
        return w / h
    }

    /// Round to the nearest even integer (>= 2). H264/HEVC require even dimensions; an odd request is
    /// silently rounded by the encoder otherwise (the 1079→1078 case from Step 1).
    public static func evenInt(_ v: Double) -> Int {
        let i = max(2, Int(v.rounded()))
        return i % 2 == 0 ? i : i + 1
    }

    private static let aspectEpsilon = 0.01

    /// Resolve a content box + options into the `sourceRect` to capture and the output pixel size.
    /// `fit` defaults to `.contain` per the spec; with no aspect/dims requested every fit collapses to
    /// the box (no crop, no bars), so the default is only refused on a genuine aspect mismatch.
    public static func resolve(bbox: CGRect, aspect: String?, fit: RecordFit,
                               width: Int?, height: Int?, scale: Double) throws -> Result {
        let bboxAR = bbox.height > 0 ? bbox.width / bbox.height : 1

        // Requested output aspect: explicit dims win, then an aspect string, else the box's own aspect.
        let requestedAR: Double? = {
            if let w = width, let h = height, h > 0 { return Double(w) / Double(h) }
            return parseAspect(aspect)
        }()
        let outputAR = requestedAR ?? bboxAR
        let mismatch = requestedAR != nil && abs(outputAR - bboxAR) > aspectEpsilon

        // sourceRect per fit.
        let sourceRect: CGRect
        if !mismatch {
            sourceRect = bbox
        } else {
            switch fit {
            case .contain:
                throw RecordFramingError.containNotSupported
            case .exact:
                sourceRect = bbox                      // stretched into the output aspect
            case .cover:
                sourceRect = cropToFill(bbox, toAspect: outputAR, bboxAR: bboxAR)
            }
        }

        // Output dimensions (px). Explicit dims win; else derive from the box width + output aspect.
        let outW: Double
        let outH: Double
        if let w = width, let h = height {
            outW = Double(w); outH = Double(h)
        } else if let w = width {
            outW = Double(w); outH = Double(w) / outputAR
        } else if let h = height {
            outH = Double(h); outW = Double(h) * outputAR
        } else {
            // Base on the captured rect (the cropped rect for cover, the box for exact/no-mismatch).
            outW = sourceRect.width * scale
            outH = outW / outputAR
        }

        return Result(sourceRect: sourceRect, width: evenInt(outW), height: evenInt(outH))
    }

    /// Crop a box to `targetAR` about its center (cover: fill the frame, crop the overflow axis, no
    /// distortion). The cropped rect is always WITHIN the box, so a window/display target gains no
    /// transparent bars. To keep everything visible at a fixed aspect, use `contain` (letterbox).
    private static func cropToFill(_ box: CGRect, toAspect targetAR: Double, bboxAR: Double) -> CGRect {
        if targetAR > bboxAR {
            // Target wider than the box → box is too tall → crop height, keep width.
            let newH = box.width / targetAR
            return CGRect(x: box.origin.x, y: box.midY - newH / 2, width: box.width, height: newH)
        } else {
            // Target narrower than the box → box is too wide → crop width, keep height.
            let newW = box.height * targetAR
            return CGRect(x: box.midX - newW / 2, y: box.origin.y, width: newW, height: box.height)
        }
    }
}
