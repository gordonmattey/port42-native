import Foundation
import AppKit

public struct ChannelInviteData {
    public let gateway: String
    public let channelId: String
    public let channelName: String
}

public enum ChannelInvite {

    /// Generate a port42://channel? invite link for sharing a channel.
    /// Prefers tunnel (ngrok) URL if available, otherwise substitutes LAN IP
    /// so the link works for other devices on the network.
    @MainActor
    public static func generateLink(channel: Channel, gatewayURL: String) -> String {
        let resolvedGW: String
        // Prefer tunnel URL for internet-accessible links
        if let tunnelURL = TunnelService.shared.publicURL {
            resolvedGW = tunnelURL
        } else if gatewayURL.contains("localhost") || gatewayURL.contains("127.0.0.1") {
            if let lanIP = localIPAddress() {
                resolvedGW = gatewayURL
                    .replacingOccurrences(of: "localhost", with: lanIP)
                    .replacingOccurrences(of: "127.0.0.1", with: lanIP)
            } else {
                resolvedGW = gatewayURL
            }
        } else {
            resolvedGW = gatewayURL
        }

        var components = URLComponents()
        components.scheme = "port42"
        components.host = "channel"
        components.queryItems = [
            URLQueryItem(name: "gateway", value: resolvedGW),
            URLQueryItem(name: "id", value: channel.id),
            URLQueryItem(name: "name", value: channel.name),
        ]
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

        return ChannelInviteData(gateway: gateway, channelId: channelId, channelName: name)
    }

    /// Build an HTTPS invite URL served by the gateway's /invite endpoint.
    @MainActor
    public static func generateInviteURL(channel: Channel) -> String? {
        // Use tunnel URL for internet-accessible invite pages
        guard let tunnelURL = TunnelService.shared.publicURL else { return nil }

        // Convert ws(s):// to https://
        let baseURL = tunnelURL
            .replacingOccurrences(of: "wss://", with: "https://")
            .replacingOccurrences(of: "ws://", with: "http://")
            .replacingOccurrences(of: "/ws", with: "")

        var components = URLComponents(string: baseURL + "/invite")
        components?.queryItems = [
            URLQueryItem(name: "id", value: channel.id),
            URLQueryItem(name: "name", value: channel.name),
        ]
        return components?.string
    }

    /// Copy an invite link to the clipboard. Prefers the landing page URL
    /// so recipients get download/connect options on the page itself.
    @MainActor
    public static func copyToClipboard(channel: Channel, gatewayURL: String, hostName: String? = nil) {
        let host = hostName ?? "Port42"
        let message: String
        if let inviteURL = generateInviteURL(channel: channel) {
            message = "Join first swimmers on \(host)'s Port42\n\(inviteURL)"
        } else {
            let deepLink = generateLink(channel: channel, gatewayURL: gatewayURL)
            guard !deepLink.isEmpty else { return }
            message = "Join first swimmers on \(host)'s Port42\n\(deepLink)"
        }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(message, forType: .string)
    }
}
