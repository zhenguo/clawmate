import WidgetKit
import SwiftUI

struct TerminalPreviewData: Codable {
    let name: String
    let lines: [String]
    let timestamp: Int
}

struct TerminalPreviewEntry: TimelineEntry {
    let date: Date
    let sessionName: String
    let lines: [String]
    let hasData: Bool
}

struct TerminalPreviewProvider: TimelineProvider {
    func placeholder(in context: Context) -> TerminalPreviewEntry {
        TerminalPreviewEntry(
            date: Date(),
            sessionName: "my-server",
            lines: ["$ ls", "Documents  Downloads  Projects", "$ cd Projects", "$ git status", "On branch main"],
            hasData: true
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (TerminalPreviewEntry) -> Void) {
        completion(placeholder(in: context))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TerminalPreviewEntry>) -> Void) {
        let entry = loadPreview()
        let timeline = Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(60)))
        completion(timeline)
    }

    private func loadPreview() -> TerminalPreviewEntry {
        guard let activeId = SharedKeychain.read(key: "active_session_id"),
              !activeId.isEmpty,
              let preview = SharedKeychain.readJSON(key: "terminal_preview_\(activeId)", as: TerminalPreviewData.self) else {
            return TerminalPreviewEntry(date: Date(), sessionName: "", lines: [], hasData: false)
        }
        return TerminalPreviewEntry(
            date: Date(),
            sessionName: preview.name,
            lines: preview.lines,
            hasData: true
        )
    }
}

struct TerminalPreviewWidgetView: View {
    var entry: TerminalPreviewEntry

    var body: some View {
        if !entry.hasData {
            VStack(spacing: 8) {
                Image(systemName: "rectangle.on.rectangle.slash")
                    .font(.system(size: 28))
                    .foregroundColor(.gray)
                Text("No Active Session")
                    .font(.caption)
                    .foregroundColor(.gray)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .containerBackground(.black, for: .widget)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 6, height: 6)
                    Text(entry.sessionName)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.green)
                    Spacer()
                    Image(systemName: "terminal")
                        .font(.system(size: 10))
                        .foregroundColor(.gray)
                }
                .padding(.bottom, 2)

                let displayLines = Array(entry.lines.suffix(8))
                ForEach(Array(displayLines.enumerated()), id: \.offset) { _, line in
                    Text(line.isEmpty ? " " : line)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(.white.opacity(0.9))
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .containerBackground(.black, for: .widget)
        }
    }
}

struct TerminalPreviewWidget: Widget {
    let kind: String = "TerminalPreviewWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: TerminalPreviewProvider()) { entry in
            TerminalPreviewWidgetView(entry: entry)
        }
        .configurationDisplayName("Terminal Preview")
        .description("See recent terminal output at a glance")
        .supportedFamilies([.systemMedium])
    }
}
