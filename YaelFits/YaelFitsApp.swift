import SwiftUI

@main
struct YaelFitsApp: App {
    @State private var outfitStore = OutfitStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(outfitStore)
        }
    }
}
