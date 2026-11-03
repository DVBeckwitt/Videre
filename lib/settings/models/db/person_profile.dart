/// A person's local library and saved accounts on this device.
class PersonProfile {
  static const defaultId = 'default';
  static const defaultProfile = PersonProfile(id: defaultId, name: 'Default');

  final String id;
  final String name;

  const PersonProfile({required this.id, required this.name});

  factory PersonProfile.fromJson(Map<String, Object?> json) =>
      PersonProfile(id: json['id'] as String, name: json['name'] as String);

  Map<String, Object?> toJson() => {'id': id, 'name': name};

  @override
  bool operator ==(Object other) =>
      other is PersonProfile && id == other.id && name == other.name;

  @override
  int get hashCode => Object.hash(id, name);
}
