import Testing
import Foundation
@testable import Port42Lib

// MARK: - ServiceManifestSpikeTests (Spike D)
//
// The architecture test: can a service declared purely as DATA (a manifest) plus ONE generic proxy
// body register into the one registry and be reachable, gated, and schema-generated, with zero
// method-specific code? Proven on a hypothetical EXTERNAL plugin first, so the manifest shape cannot be
// warped by in-process assumptions. If this holds, Keeper and ai (in-process) are the easy direction:
// same manifest, closure body instead of a proxy.

@Suite("Service manifest (Spike D) — an external plugin from pure data")
@MainActor
struct ServiceManifestSpikeTests {

    /// A hypothetical third-party plugin. No Swift anywhere knows what "weather" means; this is data.
    /// `weather.forecast` renames its surface to `forecasts.get`, which exercises the derived name-map.
    static func weatherManifest() -> ServiceManifest {
        ServiceManifest(service: "weather", methods: [
            ManifestMethod(
                canonical: "weather.today",
                paramNames: ["city"],
                description: "Current conditions for a city.",
                inputSchema: [
                    "type": "object",
                    "properties": ["city": ["type": "string", "description": "City name."] as [String: Any]],
                    "required": ["city"]
                ],
                permission: nil
            ),
            ManifestMethod(
                canonical: "weather.forecast",
                surface: "forecasts.get",
                paramNames: ["city", "days"],
                description: "N-day forecast for a city.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "city": ["type": "string"] as [String: Any],
                        "days": ["type": "integer"] as [String: Any]
                    ],
                    "required": ["city"]
                ],
                permission: .rest
            ),
        ])
    }

    @Test("a manifest registers dispatchable methods with schema + permission, no per-method code")
    func manifestDrivesRegistration() async throws {
        var registry: BridgeRegistry = [:]
        var received: [(canonical: String, city: String?)] = []

        // The single generic backend a third party would supply (here a stub for the external endpoint).
        let nameMap = registerManifest(Self.weatherManifest(), into: &registry) { canonical, _, args in
            received.append((canonical, args.string("city")))
            return .object(["service": .string("weather"), "method": .string(canonical)])
        }

        // Both methods registered.
        #expect(registry["weather.today"] != nil)
        #expect(registry["weather.forecast"] != nil)

        // Permission carried straight from the manifest.
        #expect(registry["weather.today"]?.permission == nil)
        #expect(registry["weather.forecast"]?.permission == .rest)

        // Name-map derived: only the renamed method appears (surface != canonical).
        #expect(nameMap == ["forecasts.get": "weather.forecast"])

        // Dispatch reaches the generic backend with the canonical name and the args, no method-specific code.
        let principal = Principal(id: "peer-1", displayName: "peer", spaceId: nil, kind: .peer)
        let value = try await registry["weather.forecast"]!.run(principal, BridgeArgs(["city": "Lisbon", "days": 3]))
        #expect(received.count == 1)
        #expect(received.first?.canonical == "weather.forecast")
        #expect(received.first?.city == "Lisbon")
        guard case let .object(o) = value, case let .string(method)? = o["method"] else {
            Issue.record("expected an object with a method field, got \(value)"); return
        }
        #expect(method == "weather.forecast")
    }

    @Test("the tool schema regenerates from the manifest for every method")
    func schemaFromManifest() throws {
        var registry: BridgeRegistry = [:]
        _ = registerManifest(Self.weatherManifest(), into: &registry) { c, _, _ in .object(["method": .string(c)]) }

        let schema = anthropicToolSchema(canonical: "weather.forecast", method: registry["weather.forecast"]!)
        #expect(schema["name"] as? String == "weather_forecast")          // snake of the canonical name
        #expect(schema["description"] as? String == "N-day forecast for a city.")
        let input = try #require(schema["input_schema"] as? [String: Any])
        #expect(input["type"] as? String == "object")
        let props = try #require(input["properties"] as? [String: Any])
        #expect(props["city"] != nil && props["days"] != nil)
    }

    @Test("paramNames flow through for the port-JS positional surface")
    func paramNamesFlow() throws {
        var registry: BridgeRegistry = [:]
        _ = registerManifest(Self.weatherManifest(), into: &registry) { c, _, _ in .object(["method": .string(c)]) }
        #expect(registry["weather.today"]?.paramNames == ["city"])
        #expect(registry["weather.forecast"]?.paramNames == ["city", "days"])
    }
}
