import SwiftUI

@main
struct QuickLook3DApp: App {
    @StateObject private var library = LibraryModel()
    var body: some Scene {
        WindowGroup("Quick Look 3D") {
            ContentView().environmentObject(library).onOpenURL { library.openFile($0) }
        }
    }
}
