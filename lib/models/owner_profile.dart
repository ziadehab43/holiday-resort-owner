class OwnerProfile {
  const OwnerProfile({
    required this.uid,
    required this.name,
    required this.email,
    required this.role,
    required this.isActive,
  });

  final String uid, name, email, role;
  final bool isActive;
}
