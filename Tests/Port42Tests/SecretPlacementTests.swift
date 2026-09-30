import Testing
import Foundation
@testable import Port42Lib

// #225: a new user added an ElevenLabs key so his agents could speak, and it failed. ElevenLabs wants
// the key in an `xi-api-key` header. A "Header" secret took its header name inside the value
// ("xi-api-key: sk_..."), with nothing saying so; a bare key went out as `Authorization: <key>`, and the
// user saw only ElevenLabs' refusal. Any API can want its key in a header of its own or in a query
// parameter, so a secret now says where it goes, rest.call puts it there, and a refusal says where
// Port42 sent it.

/// Answers requests to *.p42test hosts itself, recording each one, with the status the test sets.
final class RecordingProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requests: [URLRequest] = []
    nonisolated(unsafe) static var status = 200
    private static let lock = NSLock()

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host?.hasSuffix(".p42test") == true
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); Self.requests.append(request); let status = Self.status; Self.lock.unlock()
        let body = Data(#"{"detail":{"status":"invalid_api_key"}}"#.utf8)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite("A secret goes where its API wants it (#225)", .serialized)
@MainActor
struct SecretPlacementTests {

    @Test("each kind of secret goes in its place; a header or query secret names its own")
    func placements() {
        typealias S = Port42AuthStore
        #expect(S.placement(type: .bearerToken, field: nil, value: "k") == .header(name: "Authorization", value: "Bearer k"))
        #expect(S.placement(type: .apiKey, field: nil, value: "k") == .header(name: "x-api-key", value: "k"))
        #expect(S.placement(type: .header, field: "xi-api-key", value: "sk_1") == .header(name: "xi-api-key", value: "sk_1"))
        #expect(S.placement(type: .header, field: "api-key", value: "a") == .header(name: "api-key", value: "a"))
        #expect(S.placement(type: .query, field: "key", value: "g") == .query(name: "key", value: "g"))
        #expect(S.placement(type: .query, field: " ", value: "g") == nil, "a query secret with no parameter name has nowhere to go")
        // A header secret saved before #225 carries its name in its value, and still works.
        #expect(S.placement(type: .header, field: nil, value: "xi-api-key: sk_2") == .header(name: "xi-api-key", value: "sk_2"))
    }

    /// Save a secret the way the Secrets settings do, call ElevenLabs' voices endpoint with it as the
    /// person would (no grant needed), and return what went over the wire and what came back.
    func callWith(type: Port42AuthStore.SecretType, field: String?, value: String, status: Int,
                  url: String = "https://api.elevenlabs.p42test/v1/voices") async throws -> (URLRequest, [String: Any]) {
        let w = try makeParityWorld()
        let name = "eleven-\(UUID().uuidString.prefix(8).lowercased())"
        Port42AuthStore.shared.saveSecret(name: name, type: type, value: value, field: field)
        defer { Port42AuthStore.shared.deleteSecret(name: name) }
        URLProtocol.registerClass(RecordingProtocol.self)
        defer { URLProtocol.unregisterClass(RecordingProtocol.self) }
        RecordingProtocol.requests = []; RecordingProtocol.status = status

        let method = try #require(w.registry["rest.call"])
        let me = Principal.human(id: "u1", displayName: "Gordon's brother", spaceId: w.space.id)
        let out = try await method.run(me, BridgeArgs(["url": url, "secret": name]))
        let sent = try #require(RecordingProtocol.requests.last)
        return (sent, try #require(out.toJSONObject() as? [String: Any]))
    }

    @Test("an ElevenLabs key saved as a header secret named xi-api-key reaches ElevenLabs in xi-api-key")
    func elevenLabsHeader() async throws {
        let (sent, out) = try await callWith(type: .header, field: "xi-api-key", value: "sk_eleven", status: 200)
        #expect(sent.value(forHTTPHeaderField: "xi-api-key") == "sk_eleven")
        #expect(sent.value(forHTTPHeaderField: "Authorization") == nil, "the key also went out as Authorization")
        #expect(out["status"] as? Int == 200)
        #expect(out["hint"] == nil)
    }

    @Test("a query secret is added to the URL, replacing one of the same name")
    func querySecret() async throws {
        let (sent, _) = try await callWith(type: .query, field: "key", value: "g_1", status: 200,
                                           url: "https://maps.p42test/v1/geo?q=soho&key=placeholder")
        let items = URLComponents(url: try #require(sent.url), resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(items.filter { $0.name == "key" }.map(\.value) == ["g_1"])
        #expect(items.contains(URLQueryItem(name: "q", value: "soho")))
        #expect(sent.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test("a refused key says where Port42 sent it and how to change that, never the key")
    func refusalSaysWhere() async throws {
        let (_, out) = try await callWith(type: .bearerToken, field: nil, value: "sk_secret_value", status: 401)
        let hint = try #require(out["hint"] as? String, "a 401 on a secret came back with nothing saying what was sent")
        #expect(hint.contains("Authorization header (Bearer)"))
        #expect(hint.contains("Settings → Secrets"))
        #expect(!hint.contains("sk_secret_value"), "the hint leaked the key")
        #expect(out["status"] as? Int == 401)
    }
}
