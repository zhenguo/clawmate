import 'dart:convert';

enum TransportType { ssh, mosh }

class ConnectionProfile {
  final String id;
  final String name;
  final String host;
  final int port;
  final String username;
  final TransportType transportType;

  ConnectionProfile({
    required this.id,
    required this.name,
    required this.host,
    this.port = 22,
    required this.username,
    this.transportType = TransportType.ssh,
  });

  ConnectionProfile copyWith({
    String? name,
    String? host,
    int? port,
    String? username,
    TransportType? transportType,
  }) {
    return ConnectionProfile(
      id: id,
      name: name ?? this.name,
      host: host ?? this.host,
      port: port ?? this.port,
      username: username ?? this.username,
      transportType: transportType ?? this.transportType,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'host': host,
        'port': port,
        'username': username,
        'transportType': transportType.name,
      };

  factory ConnectionProfile.fromJson(Map<String, dynamic> json) {
    return ConnectionProfile(
      id: json['id'] as String,
      name: json['name'] as String,
      host: json['host'] as String,
      port: json['port'] as int? ?? 22,
      username: json['username'] as String,
      transportType: json['transportType'] == 'mosh'
          ? TransportType.mosh
          : TransportType.ssh,
    );
  }

  String encode() => jsonEncode(toJson());

  static ConnectionProfile decode(String source) =>
      ConnectionProfile.fromJson(jsonDecode(source) as Map<String, dynamic>);
}
