import '../entities/share_payload.dart';
import '../repositories/share_payload_repository.dart';

class ReceiveSharedContent {
  const ReceiveSharedContent(this._repository);

  final SharePayloadRepository _repository;

  Future<SharePayload?> initial() => _repository.getInitialPayload();

  Stream<SharePayload> watch() => _repository.watchPayloads();
}
