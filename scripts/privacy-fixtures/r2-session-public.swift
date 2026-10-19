// append: Packages/PebbleKit/Sources/PebbleModel/CloudModel.swift
// expect: makeSession must be internal or private
extension URLSessionCloudTransport {
    public static func makeSession() -> URLSession { fatalError() }
}
