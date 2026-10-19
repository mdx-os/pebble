// append: Packages/PebbleKit/Sources/PebbleUI/CloudHelpView.swift
// expect: a transport is made outside ModelChoice.model's cloud closure
let x = ModelChoice.model(settings: settings, endpoint: endpoint, local: { makeTransport() }()) { _ in local }
