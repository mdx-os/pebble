// append: Packages/PebbleKit/Sources/PebbleModel/CloudModel.swift
// expect: encryption or certificate pinning needs a fresh export review
// Pinning inside the cloud client, the one file allowed network code.

extension RefusesRedirects {
    public func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge)
        async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard let trust = challenge.protectionSpace.serverTrust else { return (.cancelAuthenticationChallenge, nil) }
        return (.useCredential, URLCredential(trust: trust))
    }
}
