// into: App/Sources
// remove-category: NSPrivacyAccessedAPICategoryFileTimestamp
// expect: App/Sources/Fixturer2reasonstatspace.swift:4: required-reason API (NSPrivacyAccessedAPICategoryFileTimestamp)
let result = stat (path, &info)
