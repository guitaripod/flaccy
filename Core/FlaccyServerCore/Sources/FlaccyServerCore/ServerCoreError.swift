public enum ServerCoreError: Error, Equatable, Sendable {
    case core(String)
    case internalFailure(String)
    case malformedResponse(String)
}
