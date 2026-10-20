// into: Packages/PebbleKit/Sources/PebbleCore
// remove-category: NSPrivacyAccessedAPICategoryDiskSpace
// expect: required-reason API (NSPrivacyAccessedAPICategoryDiskSpace)
let x = statfs
 (path, &info)
