import Foundation

// MARK: - InstanceKey
//
// The instance's Ed25519 key (nautilus Phase 4, step 4.2; docs/design-phase4-relay.md "Identity").
//
// One per INSTANCE, never per person: two Macs of one person are two peers, and Port42 and Port42Dev2
// on one Mac are two peers, so every grant keyed on a peer names one machine's one app. The public key
// is the peer id in `port42://<peer>/<portId>`; the gateway derives it from the seed handed over on
// stdin and tells the app, so the encoding lives in one place.
//
// The seed is made at first need and kept in the Keychain under the instance name, beside the gateway
// root secret. Rotating it would orphan every grant keyed on it, so nothing rotates it.

enum InstanceKey {

    /// This instance's seed, base64 of 32 bytes. Created on first use.
    @MainActor
    static func seed(instance: String = ClientRegistry.currentInstance) -> String {
        // A test never touches the Keychain: the seed is per process and in memory, as the root
        // secret's is (ClientRegistry.rootSecret).
        if ClientRegistry.isTestProcess {
            if let cached = testSeeds[instance] { return cached }
            let fresh = ClientRegistry.randomSecret()
            testSeeds[instance] = fresh
            return fresh
        }
        if let existing = Port42AuthStore.shared.peerSeed(instance: instance) { return existing }
        let fresh = ClientRegistry.randomSecret()
        Port42AuthStore.shared.savePeerSeed(fresh, instance: instance)
        return fresh
    }

    @MainActor private static var testSeeds: [String: String] = [:]
}
