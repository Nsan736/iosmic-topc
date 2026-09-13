import SwiftUI

@main
struct MicSenderApp: App {
    @StateObject private var streamer = AudioStreamer()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(streamer)
        }
    }
}
