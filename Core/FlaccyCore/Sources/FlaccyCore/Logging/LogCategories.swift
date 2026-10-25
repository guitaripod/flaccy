import MidgarCore

/// The log streams of the Flaccy clients, shared by the iOS, macOS and watchOS apps and by FlaccyCore itself.
extension MidgarLog.Category {
    public static let auth = MidgarLog.Category("auth")
    public static let connectivity = MidgarLog.Category("connectivity")
    public static let content = MidgarLog.Category("content")
    public static let database = MidgarLog.Category("database")
    public static let performance = MidgarLog.Category("performance")
    public static let playback = MidgarLog.Category("playback")
    public static let purchases = MidgarLog.Category("purchases")
    public static let remote = MidgarLog.Category("remote")
    public static let sync = MidgarLog.Category("sync")
    public static let watch = MidgarLog.Category("watch")
}
