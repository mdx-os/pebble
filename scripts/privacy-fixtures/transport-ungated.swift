// append: Packages/PebbleKit/Sources/PebbleUI/CloudHelpView.swift
// expect: a transport is made outside ModelChoice.model's cloud closure
// A transport made ahead of time, whatever the setting says.

extension CloudHelp {
    func fixtureEager() -> any CloudTransport {
        makeTransport()
    }
}
