import Foundation

// MARK: - ServiceManifest (Spike D — the plugin declaration)
//
// A service declared as DATA, not code. This is the plugin architecture's central artifact: a third
// party integrates by shipping a manifest (namespace + methods + schema + permission + surface names),
// and our own in-process services (Keeper, ai, storage) are describable by the same shape. See
// `docs/bridge-architecture-and-mcp.md` §6.
//
// The manifest is transport-agnostic and serializable — an external plugin could ship it as JSON. The
// one thing it cannot carry is a Swift closure, so it declares the CONTRACT and the body is bound
// separately: an external plugin declares a backend the generic proxy forwards to; an in-process
// service binds a closure per canonical name. Only the body binding differs; the manifest is identical.
//
// The name-map (a service's DSL surface vs its canonical methods, e.g. Keeper's plural `creases` over
// singular `crease`) is NOT a separate table. It falls out of each method declaring both its canonical
// name and its surface name; `nameMap` derives the entries where they differ.

/// One method a service declares. Pure data: the contract, never the body.
public struct ManifestMethod {
    /// The one true name (dotted), the registry key, e.g. `weather.forecast`.
    public let canonical: String
    /// The name callers use on the JS/DSL surface, e.g. `forecasts.get`. Equal to `canonical` when the
    /// service does not rename it.
    public let surface: String
    /// Positional parameter names for the port-JS surface (empty for named-args-only methods).
    public let paramNames: [String]
    public let description: String
    public let inputSchema: [String: Any]
    public let permission: PortPermission?

    public init(canonical: String,
                surface: String? = nil,
                paramNames: [String] = [],
                description: String = "",
                inputSchema: [String: Any] = [:],
                permission: PortPermission? = nil) {
        self.canonical = canonical
        self.surface = surface ?? canonical
        self.paramNames = paramNames
        self.description = description
        self.inputSchema = inputSchema
        self.permission = permission
    }
}

/// A service declared as data.
public struct ServiceManifest {
    public let service: String
    public let methods: [ManifestMethod]

    public init(service: String, methods: [ManifestMethod]) {
        self.service = service
        self.methods = methods
    }

    /// surface -> canonical, only where they differ. Derived, never hand-written. This is what the
    /// alias resolver consumes; it subsumes the `files.* -> fs.*` table into the general mechanism.
    public var nameMap: [String: String] {
        var m: [String: String] = [:]
        for method in methods where method.surface != method.canonical {
            m[method.surface] = method.canonical
        }
        return m
    }
}

/// The in-app services declared as manifests. Their name-maps merge into `AppState.bridgeAliases`, and
/// the manifest-consistency runtime probe iterates this list. A new manifest service is added here.
@MainActor
func appManifestServices() -> [ServiceManifest] {
    [keeperManifest(), storageManifest()]
}

/// Register a manifest's methods into the registry. Each method becomes a `BridgeMethod` carrying the
/// manifest's schema + permission, its body a GENERIC proxy that forwards `(canonical, principal, args)`
/// to `body`. Returns the derived surface->canonical name-map for the alias resolver.
///
/// The body is generic on purpose: it knows nothing about any method's semantics. An external plugin
/// ships only this manifest plus one backend, and every method it declares becomes reachable on all
/// surfaces with schema + gating, no per-method code. An in-process service passes a `body` that
/// dispatches by canonical name to its Swift closures.
@MainActor
@discardableResult
public func registerManifest(
    _ manifest: ServiceManifest,
    into r: inout BridgeRegistry,
    body: @escaping @MainActor (_ canonical: String, _ principal: Principal, _ args: BridgeArgs) async throws -> BridgeValue
) -> [String: String] {
    for method in manifest.methods {
        let canonical = method.canonical
        r[canonical] = BridgeMethod(
            permission: method.permission,
            paramNames: method.paramNames,
            description: method.description,
            inputSchema: method.inputSchema
        ) { principal, args in
            try await body(canonical, principal, args)
        }
    }
    return manifest.nameMap
}
