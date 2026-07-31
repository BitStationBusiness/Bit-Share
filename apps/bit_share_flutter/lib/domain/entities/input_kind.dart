enum InputKind {
  url,
  text,
  imageUri,
  audioUri,
  videoUri,
  multiUri,
  unknown;

  static InputKind fromWireValue(Object? value) {
    return InputKind.values.firstWhere(
      (kind) => kind.name == value,
      orElse: () => InputKind.unknown,
    );
  }
}
