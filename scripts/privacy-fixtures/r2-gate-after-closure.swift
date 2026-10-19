// append: Packages/PebbleKit/Sources/PebbleUI/CloudHelpView.swift
// expect: a transport is made outside ModelChoice.model's cloud closure
func escape() {
 _ = ModelChoice.model(settings: settings, endpoint: endpoint, local: local) { _ in local }
 _ = makeTransport()
}
