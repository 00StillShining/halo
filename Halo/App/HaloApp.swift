import SwiftUI

@main
struct HaloApp: App {
    @State private var model = HaloAppModel()

    var body: some Scene {
        WindowGroup {
            HaloRootView()
                .environment(model)
                .frame(minWidth: 1180, minHeight: 720)
        }
        .defaultSize(width: 1440, height: 900)
        .windowStyle(.hiddenTitleBar)
    }
}
