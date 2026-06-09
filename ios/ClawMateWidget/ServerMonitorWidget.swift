import WidgetKit
import SwiftUI

struct ServerStatsData: Codable {
    let host: String
    let cpu: Double
    let mem: Double
    let disk: Double?
    let timestamp: Int
}

struct ServerMonitorEntry: TimelineEntry {
    let date: Date
    let servers: [ServerStatsData]
    let hasData: Bool
}

struct ServerMonitorProvider: TimelineProvider {
    func placeholder(in context: Context) -> ServerMonitorEntry {
        ServerMonitorEntry(date: Date(), servers: [
            ServerStatsData(host: "192.168.1.1", cpu: 45.2, mem: 62.8, disk: nil, timestamp: 0)
        ], hasData: true)
    }

    func getSnapshot(in context: Context, completion: @escaping (ServerMonitorEntry) -> Void) {
        completion(placeholder(in: context))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ServerMonitorEntry>) -> Void) {
        let servers = loadStats()
        let entry = ServerMonitorEntry(date: Date(), servers: servers, hasData: !servers.isEmpty)
        let timeline = Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(60)))
        completion(timeline)
    }

    private func loadStats() -> [ServerStatsData] {
        guard let connections = SharedKeychain.readJSON(key: "connections", as: [ConnectionItem].self) else {
            return []
        }
        var stats: [ServerStatsData] = []
        for conn in connections {
            if let stat = SharedKeychain.readJSON(key: "server_stats_\(conn.id)", as: ServerStatsData.self) {
                let age = Date().timeIntervalSince1970 - Double(stat.timestamp) / 1000.0
                if age < 300 {
                    stats.append(stat)
                }
            }
        }
        return stats
    }
}

struct ServerMonitorWidgetView: View {
    var entry: ServerMonitorEntry
    @Environment(\.widgetFamily) var family

    var body: some View {
        if !entry.hasData {
            VStack(spacing: 8) {
                Image(systemName: "chart.bar")
                    .font(.system(size: 28))
                    .foregroundColor(.gray)
                Text("No Server Data")
                    .font(.caption)
                    .foregroundColor(.gray)
                Text("Connect to see stats")
                    .font(.caption2)
                    .foregroundColor(.gray.opacity(0.7))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .containerBackground(.black, for: .widget)
        } else if family == .systemSmall {
            if let server = entry.servers.first {
                smallView(server)
                    .containerBackground(.black, for: .widget)
            }
        } else {
            mediumView()
                .containerBackground(.black, for: .widget)
        }
    }

    private func smallView(_ server: ServerStatsData) -> some View {
        VStack(spacing: 8) {
            Text(server.host)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.green)
                .lineLimit(1)

            ZStack {
                Circle()
                    .stroke(Color.gray.opacity(0.3), lineWidth: 4)
                Circle()
                    .trim(from: 0, to: server.cpu / 100)
                    .stroke(cpuColor(server.cpu), style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                VStack(spacing: 0) {
                    Text("\(Int(server.cpu))%")
                        .font(.system(size: 16, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                    Text("CPU")
                        .font(.system(size: 8))
                        .foregroundColor(.gray)
                }
            }
            .frame(width: 56, height: 56)

            HStack(spacing: 4) {
                Image(systemName: "memorychip")
                    .font(.system(size: 8))
                    .foregroundColor(.cyan)
                Text("\(Int(server.mem))%")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(.white)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func mediumView() -> some View {
        let items = Array(entry.servers.prefix(3))
        return HStack(spacing: 12) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, server in
                VStack(spacing: 6) {
                    Text(server.host)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(.green)
                        .lineLimit(1)

                    ZStack {
                        Circle()
                            .stroke(Color.gray.opacity(0.3), lineWidth: 3)
                        Circle()
                            .trim(from: 0, to: server.cpu / 100)
                            .stroke(cpuColor(server.cpu), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                        VStack(spacing: 0) {
                            Text("\(Int(server.cpu))%")
                                .font(.system(size: 12, weight: .bold, design: .monospaced))
                                .foregroundColor(.white)
                            Text("CPU")
                                .font(.system(size: 7))
                                .foregroundColor(.gray)
                        }
                    }
                    .frame(width: 44, height: 44)

                    HStack(spacing: 2) {
                        Rectangle()
                            .fill(memColor(server.mem))
                            .frame(width: 3, height: 12)
                            .cornerRadius(1.5)
                        Text("\(Int(server.mem))%")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(.white)
                        Text("MEM")
                            .font(.system(size: 7))
                            .foregroundColor(.gray)
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func cpuColor(_ value: Double) -> Color {
        if value < 50 { return .green }
        if value < 80 { return .orange }
        return .red
    }

    private func memColor(_ value: Double) -> Color {
        if value < 60 { return .cyan }
        if value < 85 { return .orange }
        return .red
    }
}

struct ServerMonitorWidget: Widget {
    let kind: String = "ServerMonitorWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: ServerMonitorProvider()) { entry in
            ServerMonitorWidgetView(entry: entry)
        }
        .configurationDisplayName("Server Monitor")
        .description("Monitor your server CPU and memory usage")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
