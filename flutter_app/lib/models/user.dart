class User {
  final String id;
  final String email;
  final String? name;
  final String role;

  const User({
    required this.id,
    required this.email,
    this.name,
    required this.role,
  });

  factory User.fromJson(Map<String, dynamic> j) => User(
        id:    j['id']   as String,
        email: j['email'] as String,
        name:  j['name']  as String?,
        role:  j['role']  as String? ?? 'user',
      );

  String get displayName => name?.isNotEmpty == true ? name! : email;
  bool get isAdmin => role == 'admin';
}
