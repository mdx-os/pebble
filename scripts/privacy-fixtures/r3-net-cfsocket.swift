// into: Packages/PebbleKit/Sources/PebbleCore
// expect: network code outside the opt-in cloud client
let fixtureSocket = CFSocketCreate(nil, PF_INET, SOCK_STREAM, IPPROTO_TCP, 0, nil, nil)
