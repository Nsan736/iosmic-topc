import SwiftUI

@main
struct MicSenderApp: App {
    @StateObject private var audio = AudioStreamer()
    @StateObject private var camera = CameraStreamer()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(audio)
                .environmentObject(camera)
        }
    }
}
