// into: Packages/PebbleKit/Sources/PebbleCore
// remove-category: NSPrivacyAccessedAPICategoryFileTimestamp
// expect: required-reason API (NSPrivacyAccessedAPICategoryFileTimestamp)
let x = fstat
 (fd, &info)
