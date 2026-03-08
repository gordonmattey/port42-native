import Foundation
import AppKit

public struct ChannelInviteData {
    public let gateway: String
    public let channelId: String
    public let channelName: String
    public let encryptionKey: String?
}

public enum ChannelInvite {

    /// Generate a port42://channel? invite link for sharing a channel.
    /// Uses the gateway this user is actually connected to. If connected to
    /// a remote gateway (joined from someone else's invite), the link points
    /// back to that original host so new peers join the same gateway.
    @MainActor
    public static func generateLink(channel: Channel, syncGatewayURL: String? = nil) -> String {
        let resolvedGW: String

        // If connected to a remote gateway, use that
        if let gw = syncGatewayURL, !gw.contains("localhost"), !gw.contains("127.0.0.1") {
            resolvedGW = gw
        } else if let tunnelURL = TunnelService.shared.publicURL {
            // Host with tunnel: use the public tunnel URL
            resolvedGW = tunnelURL
        } else {
            // No tunnel: fall back to LAN IP
            let localGW = GatewayProcess.shared.localURL
            if let lanIP = localIPAddress() {
                resolvedGW = localGW
                    .replacingOccurrences(of: "localhost", with: lanIP)
                    .replacingOccurrences(of: "127.0.0.1", with: lanIP)
            } else {
                resolvedGW = localGW
            }
        }

        var components = URLComponents()
        components.scheme = "port42"
        components.host = "channel"
        var items = [
            URLQueryItem(name: "gateway", value: resolvedGW),
            URLQueryItem(name: "id", value: channel.id),
            URLQueryItem(name: "name", value: channel.name),
        ]
        if let key = channel.encryptionKey {
            items.append(URLQueryItem(name: "key", value: key))
        }
        components.queryItems = items
        return components.string ?? ""
    }

    /// Get the first non-loopback IPv4 address (LAN IP).
    private static func localIPAddress() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let sa = ptr.pointee.ifa_addr.pointee
            guard sa.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: ptr.pointee.ifa_name)
            guard name.hasPrefix("en") else { continue }

            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(ptr.pointee.ifa_addr, socklen_t(sa.sa_len),
                           &hostname, socklen_t(hostname.count),
                           nil, 0, NI_NUMERICHOST) == 0 {
                address = String(cString: hostname)
                break
            }
        }
        return address
    }

    /// Parse a port42://channel? invite link.
    public static func parse(url: URL) -> ChannelInviteData? {
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
              let channelId = dict["id"],
              let name = dict["name"] else {
            return nil
        }

        return ChannelInviteData(gateway: gateway, channelId: channelId, channelName: name, encryptionKey: dict["key"])
    }

    /// Build an HTTPS invite URL served by the gateway's /invite endpoint.
    /// If connected to a remote gateway, the invite URL points to that host's
    /// landing page so the link always leads back to the channel's origin.
    @MainActor
    public static func generateInviteURL(channel: Channel, syncGatewayURL: String? = nil) -> String? {
        // If connected to a remote gateway, build the invite URL from that
        let baseURL: String
        if let gw = syncGatewayURL, !gw.contains("localhost"), !gw.contains("127.0.0.1") {
            baseURL = gw
                .replacingOccurrences(of: "wss://", with: "https://")
                .replacingOccurrences(of: "ws://", with: "http://")
                .replacingOccurrences(of: "/ws", with: "")
        } else if let tunnelURL = TunnelService.shared.publicURL {
            baseURL = tunnelURL
                .replacingOccurrences(of: "wss://", with: "https://")
                .replacingOccurrences(of: "ws://", with: "http://")
                .replacingOccurrences(of: "/ws", with: "")
        } else {
            return nil
        }

        var components = URLComponents(string: baseURL + "/invite")
        var items = [
            URLQueryItem(name: "id", value: channel.id),
            URLQueryItem(name: "name", value: channel.name),
        ]
        if let key = channel.encryptionKey {
            items.append(URLQueryItem(name: "key", value: key))
        }
        components?.queryItems = items
        return components?.string
    }

    /// Copy an invite link to the clipboard. Prefers the landing page URL
    /// so recipients get download/connect options on the page itself.
    @MainActor
    public static func copyToClipboard(channel: Channel, hostName: String? = nil, syncGatewayURL: String? = nil) {
        let host = hostName ?? "Port42"
        let message: String
        if let inviteURL = generateInviteURL(channel: channel, syncGatewayURL: syncGatewayURL) {
            message = "Join first swimmers on \(host)'s Port42\n\(inviteURL)"
        } else {
            let deepLink = generateLink(channel: channel, syncGatewayURL: syncGatewayURL)
            guard !deepLink.isEmpty else { return }
            message = "Join first swimmers on \(host)'s Port42\n\(deepLink)"
        }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(message, forType: .string)
    }
}
