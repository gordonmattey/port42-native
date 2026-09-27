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

    /// This instance's seed, base64 of 32 bytes. Created on first use; nil when the Keychain holds one
    /// that could not be read, so this launch runs without an identity (no sharing) rather than
    /// replacing it and orphaning everything keyed on it.
    @MainActor
    static func seed(instance: String = ClientRegistry.currentInstance) -> String? {
        // A test never touches the Keychain: the seed is per process and in memory, as the root
        // secret's is (ClientRegistry.rootSecret).
        if ClientRegistry.isTestProcess {
            if let cached = testSeeds[instance] { return cached }
            let fresh = ClientRegistry.randomSecret()
            testSeeds[instance] = fresh
            return fresh
        }
        switch KeptSecret.resolve(Port42AuthStore.shared.readPeerSeed(instance: instance),
                                  make: ClientRegistry.randomSecret,
                                  save: { Port42AuthStore.shared.savePeerSeed($0, instance: instance) }) {
        case .kept(let v), .made(let v): return v
        case .unreadable(let status):
            p42log("[identity] this instance's key is in the Keychain but could not be read (status %d); "
                   + "running without sharing rather than replacing it", Int(status))
            unreadableStatus = status
            return nil
        }
    }

    @MainActor private static var testSeeds: [String: String] = [:]
    /// Set when this launch could not read the instance's key (for Settings to say so).
    @MainActor static var unreadableStatus: OSStatus?
}
