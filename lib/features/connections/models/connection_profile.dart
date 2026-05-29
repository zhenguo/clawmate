import 'dart:convert';

class ConnectionProfile {
  final String id;
  final String name;
  final String host;
  final int port;
  final String username;

  ConnectionProfile({
    required this.id,
    required this.name,
    required this.host,
    this.port = 22,
    required this.username,
  });

  ConnectionProfile copyWith({
    String? name,
    String? host,
    int? port,
    String? username,
  }) {
    return ConnectionProfile(
      id: id,
      name: name ?? this.name,
      host: host ?? this.host,
      port: port ?? this.port,
      username: username ?? this.username,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'host': host,
        'port': port,
        'username': username,
      };

  factory ConnectionProfile.fromJson(Map<String, dynamic> json) {
    return ConnectionProfile(
      id: json['id'] as String,
      name: json['name'] as String,
      host: json['host'] as String,
      port: json['port'] as int? ?? 22,
      username: json['username'] as String,
    );
  }

  String encode() => jsonEncode(toJson());

  static ConnectionProfile decode(String source) =>
      ConnectionProfile.fromJson(jsonDecode(source) as Map<String, dynamic>);
}
