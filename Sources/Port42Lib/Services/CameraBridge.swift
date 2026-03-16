import Foundation
import AVFoundation
import AppKit

// MARK: - Camera Bridge (P-503)

/// Bridges port42.camera.* calls to AVCaptureSession.
/// Supports single frame capture and continuous streaming with frame events.
@MainActor
public final class CameraBridge: NSObject {

    private weak var bridge: PortBridge?

    private var captureSession: AVCaptureSession?
    private var videoOutput: AVCaptureVideoDataOutput?
    private var isStreaming = false
    private var streamScale: CGFloat = 0.5
    private let delegateQueue = DispatchQueue(label: "com.port42.camera", qos: .userInitiated)

    /// Thread-safe state shared with the delegate callback.
    private let frameHandler = FrameHandler()

    public init(bridge: PortBridge? = nil) {
        self.bridge = bridge
    }

    // MARK: - Setup

    private func setupSession() async -> [String: Any]? {
        guard captureSession == nil else { return nil }

        let session = AVCaptureSession()
        session.sessionPreset = .high

        guard let device = AVCaptureDevice.default(for: .video) else {
            return ["error": "No camera available"]
        }

        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else {
                return ["error": "Cannot add camera input"]
            }
            session.addInput(input)
        } catch {
            return ["error": "Camera access denied: \(error.localizedDescription)"]
        }

        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.setSampleBufferDelegate(frameHandler, queue: delegateQueue)
        output.alwaysDiscardsLateVideoFrames = true

        guard session.canAddOutput(output) else {
            return ["error": "Cannot add video output"]
        }
        session.addOutput(output)

        captureSession = session
        videoOutput = output
        return nil
    }

    // MARK: - Capture (single frame)

    /// Capture a single camera frame. Returns base64 PNG image.
    func capture(opts: [String: Any]) async -> [String: Any] {
        let scale = opts["scale"] as? Double ?? 0.5

        if let err = await setupSession() { return err }

        let clampedScale = CGFloat(min(max(scale, 0.1), 2.0))
        frameHandler.scale = clampedScale

        let result = await withCheckedContinuation { continuation in
            self.frameHandler.captureContinuation = continuation

            // Start session briefly to grab one frame
            self.captureSession?.startRunning()
        }

        // Stop session after single capture so camera LED turns off
        if !isStreaming {
            captureSession?.stopRunning()
        }

        return result
    }

    // MARK: - Stream

    /// Start continuous camera streaming. Frames pushed as camera.frame events.
    func stream(opts: [String: Any]) async -> [String: Any] {
        if isStreaming { return ["error": "Already streaming"] }

        let scale = opts["scale"] as? Double ?? 0.25
        let clampedScale = CGFloat(min(max(scale, 0.1), 2.0))
        frameHandler.scale = clampedScale
        frameHandler.bridge = bridge
        frameHandler.isStreaming = true

        if let err = await setupSession() { return err }

        isStreaming = true
        captureSession?.startRunning()

        return ["ok": true]
    }

    /// Stop camera streaming.
    func stopStream() -> [String: Any] {
        guard isStreaming else { return ["error": "Not streaming"] }
        isStreaming = false
        frameHandler.isStreaming = false
        captureSession?.stopRunning()
        return ["ok": true]
    }

    // MARK: - Cleanup

    public func cleanup() {
        isStreaming = false
        frameHandler.isStreaming = false
        frameHandler.captureContinuation = nil
        captureSession?.stopRunning()
        captureSession = nil
        videoOutput = nil
    }
}

// MARK: - Frame Handler (delegate, runs on background queue)

/// Separate class for the delegate to avoid MainActor isolation issues.
/// All frame processing happens on the delegateQueue (background).
private final class FrameHandler: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {

    var scale: CGFloat = 0.5
    var isStreaming = false
    var streamFPS: Double = 4.0  // Target frames per second for streaming
    weak var bridge: PortBridge?
    var captureContinuation: CheckedContinuation<[String: Any], Never>?
    private var lastFrameTime: CFAbsoluteTime = 0

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        // Throttle streaming frames to target FPS
        if isStreaming && captureContinuation == nil {
            let now = CFAbsoluteTimeGetCurrent()
            let minInterval = 1.0 / streamFPS
            guard now - lastFrameTime >= minInterval else { return }
            lastFrameTime = now
        }

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let context = CIContext()

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        let currentScale = scale
        let scaledWidth = Int(CGFloat(width) * currentScale)
        let scaledHeight = Int(CGFloat(height) * currentScale)

        let scaleTransform = CGAffineTransform(scaleX: currentScale, y: currentScale)
        let scaledImage = ciImage.transformed(by: scaleTransform)

        guard let cgImage = context.createCGImage(scaledImage, from: CGRect(x: 0, y: 0, width: scaledWidth, height: scaledHeight)) else { return }

        let bitmapRep = NSBitmapImageRep(cgImage: cgImage)
        guard let pngData = bitmapRep.representation(using: .png, properties: [:]) else { return }

        let base64 = pngData.base64EncodedString()
        let frameData: [String: Any] = [
            "image": base64,
            "width": scaledWidth,
            "height": scaledHeight
        ]

        // Single capture mode: resume continuation and stop
        if let continuation = captureContinuation {
            captureContinuation = nil
            continuation.resume(returning: frameData)
            return
        }

        // Streaming mode: push event to JS
        if isStreaming {
            let bridgeRef = bridge
            Task { @MainActor in
                bridgeRef?.pushEvent("camera.frame", data: frameData)
            }
        }
    }
}
