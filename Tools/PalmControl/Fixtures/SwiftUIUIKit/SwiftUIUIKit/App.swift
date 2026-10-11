import SwiftUI

@main
struct SwiftUIUIKitApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

struct ContentView: View {
    var body: some View {
        KitLabel(text: "Palm")
    }
}
