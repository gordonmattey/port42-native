import Testing
import Foundation
@testable import Port42Lib

@Suite("Port AI Handler")
struct PortAITests {

    // MARK: - PortAIHandler Init

    @Test("handler stores callId")
    @MainActor func handlerStoresCallId() {
        let bridge = PortBridge(appState: NSObject(), channelId: nil)
        let handler = PortAIHandler(callId: 123, bridge: bridge)
        #expect(handler.callId == 123)
    }

    @Test("handler creates engine")
    @MainActor func handlerCreatesEngine() {
        let bridge = PortBridge(appState: NSObject(), channelId: nil)
        let handler = PortAIHandler(callId: 1, bridge: bridge)
        #expect(handler.engine is LLMEngine)
    }

    // MARK: - PortBridge Stream Management

    @Test("activeStreams tracks handlers by callId")
    @MainActor func activeStreamsTracking() {
        let bridge = PortBridge(appState: NSObject(), channelId: nil)
        let handler = PortAIHandler(callId: 42, bridge: bridge)
        bridge.activeStreams[42] = handler
        #expect(bridge.activeStreams[42] != nil)
        #expect(bridge.activeStreams[42]?.callId == 42)
    }

    @Test("removeStream cleans up handler")
    @MainActor func removeStreamCleanup() {
        let bridge = PortBridge(appState: NSObject(), channelId: nil)
        let handler = PortAIHandler(callId: 5, bridge: bridge)
        bridge.activeStreams[5] = handler
        bridge.removeStream(5)
        #expect(bridge.activeStreams[5] == nil)
    }

    @Test("multiple streams can coexist")
    @MainActor func multipleStreams() {
        let bridge = PortBridge(appState: NSObject(), channelId: nil)
        let h1 = PortAIHandler(callId: 1, bridge: bridge)
        let h2 = PortAIHandler(callId: 2, bridge: bridge)
        let h3 = PortAIHandler(callId: 3, bridge: bridge)
        bridge.activeStreams[1] = h1
        bridge.activeStreams[2] = h2
        bridge.activeStreams[3] = h3
        #expect(bridge.activeStreams.count == 3)
    }

    @Test("removing one stream does not affect others")
    @MainActor func removeOneStream() {
        let bridge = PortBridge(appState: NSObject(), channelId: nil)
        let h1 = PortAIHandler(callId: 1, bridge: bridge)
        let h2 = PortAIHandler(callId: 2, bridge: bridge)
        bridge.activeStreams[1] = h1
        bridge.activeStreams[2] = h2
        bridge.removeStream(1)
        #expect(bridge.activeStreams[1] == nil)
        #expect(bridge.activeStreams[2] != nil)
    }

    // MARK: - Permission Integration

    @Test("ai.complete and companions.invoke share same permission")
    func sharedAIPermission() {
        let aiPerm = PortPermission.permissionForMethod("ai.complete")
        let invokePerm = PortPermission.permissionForMethod("companions.invoke")
        #expect(aiPerm == invokePerm)
        #expect(aiPerm == .ai)
    }

    @Test("granting .ai permission covers both ai.complete and companions.invoke")
    func grantCoversAll() {
        let bridge = PortBridge(appState: NSObject(), channelId: nil)
        bridge.grantedPermissions.insert(.ai)
        // Both methods map to .ai
        let p1 = PortPermission.permissionForMethod("ai.complete")
        let p2 = PortPermission.permissionForMethod("companions.invoke")
        #expect(p1 != nil && bridge.grantedPermissions.contains(p1!))
        #expect(p2 != nil && bridge.grantedPermissions.contains(p2!))
    }
}
