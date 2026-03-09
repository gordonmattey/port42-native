import AuthenticationServices
import CryptoKit
import AppKit

public enum AppleAuthError: Error, LocalizedError {
    case noIdentityToken
    case tokenNotUTF8
    case credentialRevoked
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .noIdentityToken: return "Apple did not return an identity token"
        case .tokenNotUTF8: return "Identity token is not valid UTF-8"
        case .credentialRevoked: return "Apple credential has been revoked"
        case .cancelled: return "Apple sign-in was cancelled"
        }
    }
}

/// Hashes a nonce string with SHA256 and returns the hex-encoded result.
/// Apple expects the hashed nonce in the authorization request.
public func hashNonce(_ nonce: String) -> String {
    SHA256.hash(data: Data(nonce.utf8))
        .map { String(format: "%02x", $0) }
        .joined()
}

@MainActor
public final class AppleAuthService: NSObject, ObservableObject {

    /// Authenticate with Apple, showing the sign-in sheet if needed.
    /// Returns the identity token JWT string and the opaque Apple user ID.
    public func authenticate(nonce: String) async throws -> (identityToken: String, appleUserID: String) {
        let hashedNonce = hashNonce(nonce)

        let provider = ASAuthorizationAppleIDProvider()
        let request = provider.createRequest()
        request.requestedScopes = [] // no email, no name
        request.nonce = hashedNonce

        let controller = ASAuthorizationController(authorizationRequests: [request])
        let delegate = AuthDelegate()
        controller.delegate = delegate
        controller.presentationContextProvider = self

        controller.performRequests()

        let credential = try await delegate.result()

        guard let tokenData = credential.identityToken else {
            throw AppleAuthError.noIdentityToken
        }
        guard let token = String(data: tokenData, encoding: .utf8) else {
            throw AppleAuthError.tokenNotUTF8
        }

        return (identityToken: token, appleUserID: credential.user)
    }

    /// Silent re-auth for subsequent gateway connects.
    /// Checks credential state first, then requests a fresh token without UI.
    public func silentAuth(appleUserID: String, nonce: String) async throws -> String {
        // Verify the credential is still valid
        let state = try await ASAuthorizationAppleIDProvider().credentialState(forUserID: appleUserID)
        guard state == .authorized else {
            throw AppleAuthError.credentialRevoked
        }

        let hashedNonce = hashNonce(nonce)

        let provider = ASAuthorizationAppleIDProvider()
        let request = provider.createRequest()
        request.requestedScopes = []
        request.nonce = hashedNonce

        let controller = ASAuthorizationController(authorizationRequests: [request])
        let delegate = AuthDelegate()
        controller.delegate = delegate
        controller.presentationContextProvider = self

        controller.performRequests()

        let credential = try await delegate.result()

        guard let tokenData = credential.identityToken else {
            throw AppleAuthError.noIdentityToken
        }
        guard let token = String(data: tokenData, encoding: .utf8) else {
            throw AppleAuthError.tokenNotUTF8
        }

        return token
    }
}

// MARK: - Presentation Context

extension AppleAuthService: ASAuthorizationControllerPresentationContextProviding {
    public func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        NSApplication.shared.keyWindow ?? ASPresentationAnchor()
    }
}

// MARK: - Delegate

/// Bridges the ASAuthorizationController delegate callbacks to async/await.
private final class AuthDelegate: NSObject, ASAuthorizationControllerDelegate {
    private var continuation: CheckedContinuation<ASAuthorizationAppleIDCredential, Error>?

    func result() async throws -> ASAuthorizationAppleIDCredential {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    func authorizationController(controller: ASAuthorizationController,
                                 didCompleteWithAuthorization authorization: ASAuthorization) {
        if let credential = authorization.credential as? ASAuthorizationAppleIDCredential {
            continuation?.resume(returning: credential)
        } else {
            continuation?.resume(throwing: AppleAuthError.noIdentityToken)
        }
        continuation = nil
    }

    func authorizationController(controller: ASAuthorizationController,
                                 didCompleteWithError error: Error) {
        if let authError = error as? ASAuthorizationError,
           authError.code == .canceled {
            continuation?.resume(throwing: AppleAuthError.cancelled)
        } else {
            continuation?.resume(throwing: error)
        }
        continuation = nil
    }
}
