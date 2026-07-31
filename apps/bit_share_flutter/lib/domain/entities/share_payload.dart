import 'input_kind.dart';

class SharePayload {
  const SharePayload({
    required this.id,
    required this.action,
    required this.inputKind,
    required this.receivedAt,
    this.sourcePackage,
    this.mimeType,
    this.text,
    this.uris = const [],
  });

  factory SharePayload.fromMap(Map<Object?, Object?> map) {
    final rawUris = map['uris'];
    return SharePayload(
      id: map['id'] as String? ?? '',
      sourcePackage: map['sourcePackage'] as String?,
      action: map['action'] as String? ?? '',
      mimeType: map['mimeType'] as String?,
      text: map['text'] as String?,
      uris: rawUris is List
          ? rawUris.whereType<String>().toList(growable: false)
          : const [],
      inputKind: InputKind.fromWireValue(map['inputKind']),
      receivedAt:
          DateTime.tryParse(map['receivedAt'] as String? ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
    );
  }

  final String id;
  final String? sourcePackage;
  final String action;
  final String? mimeType;
  final String? text;
  final List<String> uris;
  final InputKind inputKind;
  final DateTime receivedAt;

  bool get hasContent => (text?.trim().isNotEmpty ?? false) || uris.isNotEmpty;
}
