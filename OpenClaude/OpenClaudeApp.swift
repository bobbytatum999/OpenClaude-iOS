import SwiftUI
import SwiftData

@main
struct OpenClaudeApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .modelContainer(for: [Conversation.self, Message.self, DownloadedModel.self])
        }
    }
}
