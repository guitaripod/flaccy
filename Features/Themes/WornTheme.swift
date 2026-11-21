import FlaccyCore
import Foundation

/// The look the app is wearing, asked the same way on iPhone, iPad and Mac by
/// the code the three share.
@MainActor
enum WornTheme {

    /// Posted after the look changed and was applied.
    static let didChange = Notification.Name("FlaccyThemeDidChange")

    static var look: ThemeLook {
        #if canImport(UIKit)
        AppTheme.shared.look
        #else
        MacTheme.shared.look
        #endif
    }

    /// Switches the worn theme's Albums view and remembers it with the theme.
    static func showAlbums(as view: ThemePack.AlbumsView) {
        #if canImport(UIKit)
        AppTheme.shared.edit { $0.show(albumsAs: view.id) }
        #else
        MacTheme.shared.edit { $0.show(albumsAs: view.id) }
        #endif
    }
}
