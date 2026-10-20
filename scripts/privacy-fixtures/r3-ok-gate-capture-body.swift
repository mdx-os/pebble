// append: Packages/PebbleKit/Sources/PebbleUI/CloudHelpView.swift
// expect: ok
// A capture list that makes nothing, with the transport made in the body.
let fixtureLazy = ModelChoice.model(settings: settings, endpoint: endpoint, local: local) { [settings] url in
    CloudModel(endpoint: url, transport: URLSessionCloudTransport(), settings: settings)
}
