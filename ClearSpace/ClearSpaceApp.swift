import SwiftUI

@main
struct ClearSpaceApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environmentObject(model)
        }
    }
}
