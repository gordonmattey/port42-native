import Foundation
import AppKit

public struct SpaceInviteData {
    public let gateway: String
    public let spaceId: String
    public let spaceName: String
    public let encryptionKey: String?
    public let token: String?
    public let hostName: String?
}

public enum SpaceInvite {

    /// Generate a port42://space? invite link for sharing a space.
    /// Uses the gateway this user is actually connected to. If connected to
    /// a remote gateway (joined from someone else's invite), the link points
    /// back to that original host so new peers join the same gateway.
    @MainActor
    public static func generateLink(space: Space, syncGatewayURL: String? = nil, token: String? = nil) -> String {
        let resolvedGW: String

        // If connected to a remote gateway, use that
        if let gw = syncGatewayURL, !gw.contains("localhost"), !gw.contains("127.0.0.1") {
            resolvedGW = gw
        } else if let tunnelURL = TunnelService.shared.publicURL {
            // Host with tunnel: use the public tunnel URL
            resolvedGW = tunnelURL
        } else {
            // No tunnel: use localhost (same machine only)
            resolvedGW = GatewayProcess.shared.localURL
        }

        var components = URLComponents()
        components.scheme = "port42"
        components.host = "channel"
        var items = [
            URLQueryItem(name: "gateway", value: resolvedGW),
            URLQueryItem(name: "id", value: space.id),
            URLQueryItem(name: "name", value: space.name),
        ]
        if let key = space.encryptionKey {
            // URLComponents leaves `+` unencoded in query values (ambiguous in form encoding),
            // but base64 decoders (e.g. Python's b64decode) interpret `+` as space, corrupting the key.
            let encodedKey = key.replacingOccurrences(of: "+", with: "%2B")
            items.append(URLQueryItem(name: "key", value: encodedKey))
        }
        if let token {
            items.append(URLQueryItem(name: "token", value: token))
        }
        components.queryItems = items
        return components.string ?? ""
    }


/// Parse a port42://channel? invite link.
    public static func parse(url: URL) -> SpaceInviteData? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == "port42",
              components.host == "channel" else {
            return nil
        }

        let items = components.queryItems ?? []
        let dict = Dictionary(items.compactMap { item in
            item.value.map { (item.name, $0) }
        }, uniquingKeysWith: { _, last in last })

        guard let gateway = dict["gateway"],
              let spaceId = dict["id"],
              let name = dict["name"] else {
            return nil
        }

        return SpaceInviteData(gateway: gateway, spaceId: spaceId, spaceName: name, encryptionKey: dict["key"], token: dict["token"], hostName: dict["host"])
    }

    /// Build an HTTPS invite URL on port42.ai that constructs the deep link
    /// client-side. The gateway WSS address is passed as a query param so the
    /// page can build the port42:// link without hosting its own gateway.
    @MainActor
    public static func generateInviteURL(space: Space, hostName: String? = nil, syncGatewayURL: String? = nil, token: String? = nil) -> String? {
        let gatewayWSS: String
        if let gw = syncGatewayURL, !gw.contains("localhost"), !gw.contains("127.0.0.1") {
            gatewayWSS = gw.replacingOccurrences(of: "/ws", with: "")
        } else if let tunnelURL = TunnelService.shared.publicURL {
            // Tunnel URLs are HTTPS; convert to WSS for the gateway param
            gatewayWSS = tunnelURL
                .replacingOccurrences(of: "https://", with: "wss://")
                .replacingOccurrences(of: "http://", with: "ws://")
                .replacingOccurrences(of: "/ws", with: "")
        } else {
            return nil
        }

        var components = URLComponents(string: "https://port42.ai/invite.html")
        var items = [
            URLQueryItem(name: "gateway", value: gatewayWSS),
            URLQueryItem(name: "id", value: space.id),
            URLQueryItem(name: "name", value: space.name),
        ]
        if let key = space.encryptionKey {
            let encodedKey = key.replacingOccurrences(of: "+", with: "%2B")
            items.append(URLQueryItem(name: "key", value: encodedKey))
        }
        if let token {
            items.append(URLQueryItem(name: "token", value: token))
        }
        if let hostName, !hostName.isEmpty {
            items.append(URLQueryItem(name: "host", value: hostName))
        }
        components?.queryItems = items
        return components?.string
    }

    /// Copy an invite link to the clipboard. Prefers the landing page URL
    /// so recipients get download/connect options on the page itself.
    @MainActor
    public static func copyToClipboard(space: Space, hostName: String? = nil, syncGatewayURL: String? = nil, token: String? = nil) {
        let host = hostName ?? "Port42"
        let message: String
        if let inviteURL = generateInviteURL(space: space, hostName: hostName, syncGatewayURL: syncGatewayURL, token: token) {
            message = "Join first companions on \(host)'s Port42\n\(inviteURL)"
        } else {
            let deepLink = generateLink(space: space, syncGatewayURL: syncGatewayURL, token: token)
            guard !deepLink.isEmpty else { return }
            message = "Join first companions on \(host)'s Port42\n\(deepLink)"
        }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(message, forType: .string)
        Analytics.shared.inviteSent()
    }
}
