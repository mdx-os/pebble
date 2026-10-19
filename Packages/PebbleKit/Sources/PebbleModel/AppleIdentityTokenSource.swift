#if canImport(AuthenticationServices)
import AuthenticationServices
import Foundation
import PebbleCore
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Sign in with Apple, as the identity token source. Built in every
/// configuration, and offered only when the build setting
/// `PEBBLE_SIGN_IN = apple` (`IdentitySignIn.offered`).
///
/// It runs Apple's own sheet through `ASAuthorizationController`, with the
/// request `AppleCloudAuth.appleIDRequest(nonceSha256:)` makes: no scopes,
/// so Apple shares neither the person's email nor their name, and the
/// SHA-256 of the nonce for this one sign-in. Only the credential's
/// identity token is read from Apple's answer. Nothing goes to the cloud's
/// address from here.
///
/// A build without the Sign in with Apple entitlement can't use it: Apple
/// answers with an unknown error, and the refusal says in plain words that
/// signing in with Apple isn't set up in this build yet.
public struct AppleIdentityTokenSource: IdentityTokenSource {
    public init() {}

    public var kind: IdentitySourceKind { .apple }

    public func identityToken(nonceSha256: String) async -> IdentityTokenAnswer {
        await AppleSignInRun().run(nonceSha256: nonceSha256)
    }

    /// What Apple's answer comes to: the identity token from an Apple ID
    /// credential, and nothing else from it.
    static func answer(for authorization: ASAuthorization) -> IdentityTokenAnswer {
        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
              let token = credential.identityToken, !token.isEmpty else {
            return .refused(CloudWords.appleSignInFailed)
        }
        return .token(token)
    }

    /// What an error from Apple's sheet says. Unknown is what a build
    /// without the entitlement gets.
    static func answer(for error: any Error) -> IdentityTokenAnswer {
        guard let error = error as? ASAuthorizationError else { return .refused(CloudWords.appleSignInFailed) }
        return switch error.code {
        case .canceled: .refused(CloudWords.appleSignInCancelled)
        case .unknown: .refused(CloudWords.appleSignInNotSetUp)
        default: .refused(CloudWords.appleSignInFailed)
        }
    }
}

/// One run of Apple's sheet, kept alive until Apple answers.
@MainActor
private final class AppleSignInRun: NSObject, ASAuthorizationControllerDelegate,
    ASAuthorizationControllerPresentationContextProviding {
    private var finish: CheckedContinuation<IdentityTokenAnswer, Never>?
    private var controller: ASAuthorizationController?

    func run(nonceSha256: String) async -> IdentityTokenAnswer {
        let controller = ASAuthorizationController(authorizationRequests: [AppleCloudAuth.appleIDRequest(nonceSha256: nonceSha256)])
        controller.delegate = self
        controller.presentationContextProvider = self
        self.controller = controller
        return await withCheckedContinuation { continuation in
            finish = continuation
            controller.performRequests()
        }
    }

    private func end(_ answer: IdentityTokenAnswer) {
        finish?.resume(returning: answer)
        finish = nil
        controller = nil
    }

    func authorizationController(controller: ASAuthorizationController,
                                 didCompleteWithAuthorization authorization: ASAuthorization) {
        end(AppleIdentityTokenSource.answer(for: authorization))
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: any Error) {
        end(AppleIdentityTokenSource.answer(for: error))
    }

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        #if canImport(UIKit)
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        if let window = windows.first(where: \.isKeyWindow) ?? windows.first { return window }
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        return scene.map { UIWindow(windowScene: $0) } ?? ASPresentationAnchor()
        #else
        NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first ?? ASPresentationAnchor()
        #endif
    }
}
#endif
