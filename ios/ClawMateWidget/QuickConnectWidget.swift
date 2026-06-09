import WidgetKit
import SwiftUI

struct ConnectionItem: Codable, Identifiable {
    let id: String
    let name: String
    let host: String
    let username: String
    let transport: String
}

struct QuickConnectEntry: TimelineEntry {
    let date: Date
    let connections: [ConnectionItem]
}

struct QuickConnectProvider: TimelineProvider {
    func placeholder(in context: Context) -> QuickConnectEntry {
        QuickConnectEntry(date: Date(), connections: [
            ConnectionItem(id: "1", name: "My Server", host: "192.168.1.1", username: "user", transport: "mosh")
        ])
    }

    func getSnapshot(in context: Context, completion: @escaping (QuickConnectEntry) -> Void) {
        completion(placeholder(in: context))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<QuickConnectEntry>) -> Void) {
        let connections = SharedKeychain.readJSON(key: "connections", as: [ConnectionItem].self) ?? []
        let entry = QuickConnectEntry(date: Date(), connections: connections)
        let timeline = Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(300)))
        completion(timeline)
    }
}

struct QuickConnectWidgetView: View {
    var entry: QuickConnectEntry
    @Environment(\.widgetFamily) var family

    var body: some View {
        if entry.connections.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "terminal")
                    .font(.system(size: 32))
                    .foregroundColor(.gray)
                Text("No Connections")
                    .font(.caption)
                    .foregroundColor(.gray)
                Text("Add a server in ClawMate")
                    .font(.caption2)
                    .foregroundColor(.gray.opacity(0.7))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .containerBackground(.black, for: .widget)
        } else {
            let columns = family == .systemLarge ? 2 : 1
            let maxItems = family == .systemLarge ? 6 : 3
            let items = Array(entry.connections.prefix(maxItems))

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Image(systemName: "terminal")
                        .font(.caption)
                        .foregroundColor(.green)
                    Text("Quick Connect")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.white)
                }
                .padding(.bottom, 4)

                if columns == 1 {
                    ForEach(items) { conn in
                        Link(destination: URL(string: "clawmate://connect/\(conn.id)")!) {
                            connectionRow(conn)
                        }
                    }
                } else {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: columns), spacing: 6) {
                        ForEach(items) { conn in
                            Link(destination: URL(string: "clawmate://connect/\(conn.id)")!) {
                                connectionCard(conn)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .containerBackground(.black, for: .widget)
        }
    }

    private func connectionRow(_ conn: ConnectionItem) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(conn.transport == "mosh" ? Color.cyan : Color.green)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(conn.name)
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(.white)
                    .lineLimit(1)
                Text("\(conn.username)@\(conn.host)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.gray)
                    .lineLimit(1)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 10))
                .foregroundColor(.gray)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(Color.white.opacity(0.05))
        .cornerRadius(6)
    }

    private func connectionCard(_ conn: ConnectionItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Circle()
                    .fill(conn.transport == "mosh" ? Color.cyan : Color.green)
                    .frame(width: 6, height: 6)
                Text(conn.name)
                    .font(.caption2)
                    .fontWeight(.medium)
                    .foregroundColor(.white)
                    .lineLimit(1)
            }
            Text(conn.host)
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(.gray)
                .lineLimit(1)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.05))
        .cornerRadius(8)
    }
}

struct QuickConnectWidget: Widget {
    let kind: String = "QuickConnectWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: QuickConnectProvider()) { entry in
            QuickConnectWidgetView(entry: entry)
        }
        .configurationDisplayName("Quick Connect")
        .description("Quickly connect to your servers")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}
