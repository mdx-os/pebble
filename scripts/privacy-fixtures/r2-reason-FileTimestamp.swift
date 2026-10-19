// into: Packages/PebbleKit/Sources/PebbleCore
// remove-category: NSPrivacyAccessedAPICategoryFileTimestamp
// expect: PebbleCore/Fixturer2reasonFileTimestamp.swift:4: required-reason API (NSPrivacyAccessedAPICategoryFileTimestamp)
let x = fstat
 (fd, &info)
