import AVFoundation
import ApplicationServices

/// The two system permissions voice input needs, asked for together.
///
/// macOS hands these out at the moment a feature touches the hardware, which means they arrive one at a
/// time, minutes apart, in the middle of doing something else. GM, 2026-09-27: "permissions are kinda all
/// over the place, they just stream in". So both are asked for at the same moment, the first time space is
/// held, and never again unsolicited.
public enum VoicePermission: String, Equatable, Sendable {
    case microphone
    /// For dictating into apps that are not Port42. Asked for now so the person answers once; nothing uses
    /// it until that lands.
    case accessibility

    public var label: String {
        switch self {
        case .microphone:    return "allow the microphone"
        case .accessibility: return "allow accessibility"
        }
    }
}

public struct VoicePermissions {

    public static func microphoneGranted() -> Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    /// Refused, rather than not yet asked. A refusal cannot be re-prompted: only System Settings changes it,
    /// so the indicator has to say so instead of asking again on every hold.
    public static func microphoneRefused() -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        return status == .denied || status == .restricted
    }

    public static func requestMicrophone() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    public static func accessibilityGranted() -> Bool { AXIsProcessTrusted() }

    /// Shows the system's own "open System Settings" dialog. There is no callback and no answer: the person
    /// grants it in Settings, and `accessibilityGranted()` starts returning true.
    public static func promptAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// What still has to be asked for. Microphone first, because it is the one that stops a hold working.
    public static func missing(microphone: Bool, accessibility: Bool) -> [VoicePermission] {
        var missing: [VoicePermission] = []
        if !microphone { missing.append(.microphone) }
        if !accessibility { missing.append(.accessibility) }
        return missing
    }
}
