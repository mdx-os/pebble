// append: Packages/PebbleKit/Sources/PebbleUI/CloudHelpView.swift
// expect: a transport is made outside ModelChoice.model's cloud closure
// A capture list runs when the closure is made, before consent is checked.
let fixtureEager = ModelChoice.model(settings: settings, endpoint: endpoint, local: local) { [transport = URLSessionCloudTransport()] url in
    CloudModel(endpoint: url, transport: transport)
}
