import '../entities/share_payload.dart';

abstract interface class SharePayloadRepository {
  Future<SharePayload?> getInitialPayload();

  Stream<SharePayload> watchPayloads();
}
