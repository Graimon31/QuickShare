import 'package:equatable/equatable.dart';

class QhtpItem extends Equatable {
  final String id;
  final String path; // relative path using '/'
  final int size;
  final int? mtime;
  final String? mime;

  /// `sha256:<hex>` when the sender computed one, otherwise null.
  ///
  /// Optional on purpose. Hashing is a full read pass over the payload, and a
  /// 500 GB session would keep the QR code off the screen for tens of minutes
  /// before the transfer even starts. The indexer fills this in only below
  /// [AppConstants.qhtpChecksumMaxSessionBytes]; above it the receiver falls
  /// back to verifying the byte count, which still catches truncation.
  final String? sha256;

  const QhtpItem({
    required this.id,
    required this.path,
    required this.size,
    this.mtime,
    this.mime,
    this.sha256,
  });

  factory QhtpItem.fromJson(Map<String, dynamic> json) {
    return QhtpItem(
      id: json['id'] as String,
      path: json['path'] as String,
      size: json['size'] as int,
      mtime: json['mtime'] as int?,
      mime: json['mime'] as String?,
      sha256: json['sha256'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'path': path,
      'size': size,
      if (mtime != null) 'mtime': mtime,
      if (mime != null) 'mime': mime,
      if (sha256 != null) 'sha256': sha256,
    };
  }

  @override
  List<Object?> get props => [id, path, size, mtime, mime, sha256];
}

class QhtpManifest extends Equatable {
  final String protocol;
  final int protocolVersion;
  final String sessionId;
  final int createdAt;
  final int itemCount;
  final int totalBytes;
  final List<QhtpItem> items;

  const QhtpManifest({
    this.protocol = 'QHTP',
    this.protocolVersion = 1,
    required this.sessionId,
    required this.createdAt,
    required this.itemCount,
    required this.totalBytes,
    required this.items,
  });

  factory QhtpManifest.fromJson(Map<String, dynamic> json) {
    final itemsList = (json['items'] as List<dynamic>?)
            ?.map((i) => QhtpItem.fromJson(i as Map<String, dynamic>))
            .toList() ??
        [];
    return QhtpManifest(
      protocol: json['protocol'] as String? ?? 'QHTP',
      protocolVersion: json['protocolVersion'] as int? ?? 1,
      sessionId: json['sessionId'] as String,
      createdAt: json['createdAt'] as int? ?? DateTime.now().millisecondsSinceEpoch,
      itemCount: json['itemCount'] as int? ?? itemsList.length,
      totalBytes: json['totalBytes'] as int? ?? 0,
      items: itemsList,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'protocol': protocol,
      'protocolVersion': protocolVersion,
      'sessionId': sessionId,
      'createdAt': createdAt,
      'itemCount': itemCount,
      'totalBytes': totalBytes,
      'items': items.map((i) => i.toJson()).toList(),
    };
  }

  @override
  List<Object?> get props => [
        protocol,
        protocolVersion,
        sessionId,
        createdAt,
        itemCount,
        totalBytes,
        items,
      ];
}
