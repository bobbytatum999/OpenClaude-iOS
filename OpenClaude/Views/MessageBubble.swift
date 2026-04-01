import SwiftUI

struct MessageBubble: View {
    let message: Message
    @State private var isCopied = false

    var body: some View {
        HStack {
            if message.isUser { Spacer(minLength: 60) }
            VStack(alignment: message.isUser ? .trailing : .leading, spacing: 4) {
                contentView
                if let toolResults = message.toolResults, !toolResults.isEmpty {
                    ForEach(toolResults, id: \.toolCallId) { result in ToolResultView(result: result) }
                }
                HStack(spacing: 8) {
                    Text(message.timestamp, style: .time).font(.caption2).foregroundStyle(.secondary)
                    if let model = message.model { Text("• \(model)").font(.caption2).foregroundStyle(.secondary) }
                    if message.isAssistant {
                        Button(action: copyToClipboard) { Image(systemName: isCopied ? "checkmark" : "doc.on.doc").font(.caption) }
                            .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(backgroundColor)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .contextMenu {
                Button(action: copyToClipboard) { Label("Copy", systemImage: "doc.on.doc") }
                if message.isUser { Button(action: {}) { Label("Edit", systemImage: "pencil") } }
                Divider()
                Button(role: .destructive, action: {}) { Label("Delete", systemImage: "trash") }
            }
            if message.isAssistant { Spacer(minLength: 60) }
        }
    }

    @ViewBuilder
    private var contentView: some View {
        if message.isStreaming && message.content.isEmpty {
            HStack(spacing: 4) { Text("Thinking").foregroundStyle(.secondary); AnimatedDots() }
        } else {
            if message.isError { Text(message.content).foregroundStyle(Color.red) }
            else { Text(message.content) }
        }
    }

    private var backgroundColor: Color {
        if message.isUser { return Color.accentColor.opacity(0.15) }
        else if message.isSystem { return Color(.systemGray5) }
        else if message.isError { return Color.red.opacity(0.1) }
        else { return Color(.systemGray6) }
    }

    private func copyToClipboard() {
        UIPasteboard.general.string = message.content
        isCopied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { isCopied = false }
    }
}

struct AnimatedDots: View {
    @State private var phase = 0
    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<3, id: \.self) { index in
                Circle().fill(.secondary).frame(width: 3, height: 3).opacity(phase == index ? 1 : 0.3)
            }
        }
        .onReceive(Timer.publish(every: 0.3, on: .main, in: .common).autoconnect()) { _ in
            phase = (phase + 1) % 3
        }
    }
}

struct ToolResultView: View {
    let result: Message.ToolResult
    @State private var isExpanded = false
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: result.isError ? "exclamationmark.triangle" : "hammer").foregroundStyle(result.isError ? Color.red : Color.accentColor)
                Text(result.isError ? "Tool Error" : "Tool Result").font(.caption).fontWeight(.medium)
                Spacer()
                Button(action: { isExpanded.toggle() }) { Image(systemName: isExpanded ? "chevron.up" : "chevron.down").font(.caption) }
            }
            if isExpanded {
                Text(result.output).font(.caption).fontDesign(.monospaced).padding(8).background(Color(.systemGray6)).clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(8).background(Color(.systemGray5).opacity(0.5)).clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
