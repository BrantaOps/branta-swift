/// SDK identity sent on `POST /v2/payments` as `X-Branta-SDK`.
/// Swift Package Manager resolves versions from git tags, so there is no version file.
/// Bump `version` to match the release tag (and the CHANGELOG heading) when releasing.
enum SDKInfo {
    static let language = "swift"
    static let version = "4.4.0"
    static var headerValue: String { "\(language)/\(version)" }
}
