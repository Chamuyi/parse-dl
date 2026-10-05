import 'dart:convert';

/// X 用户信息。
///
///  里的 `TwitterUser`。最少只需要 4 个字段
/// （昵称、screenName、头像、媒体数），其他全部可选 —— X 的 API 不同端点返回
/// 字段不同，过严的解析会让一部分用户加载失败。
class TwitterUser {
  final String? id;
  final String? name;
  final String? screenName;
  final String? description;
  final String? avatar;
  final int? mediaCount;
  final int? followersCount;
  final int? friendsCount;

  const TwitterUser({
    this.id,
    this.name,
    this.screenName,
    this.description,
    this.avatar,
    this.mediaCount,
    this.followersCount,
    this.friendsCount,
  });

  /// 从 X API 单用户响应里解析。字段名跟 X 官方响应完全一致。
  factory TwitterUser.fromJson(Map<String, dynamic> json) {
    final Map<String, dynamic>? data = json['data'] is Map<String, dynamic>
        ? json['data'] as Map<String, dynamic>
        : null;

    final Map<String, dynamic>? userWrapper =
        data?['user'] is Map<String, dynamic>
            ? data!['user'] as Map<String, dynamic>
            : null;

    final Map<String, dynamic>? result = userWrapper?['result'] is Map<String, dynamic>
        ? userWrapper!['result'] as Map<String, dynamic>
        : null;

    final Map<String, dynamic>? legacy =
        result?['legacy'] is Map<String, dynamic>
            ? result!['legacy'] as Map<String, dynamic>
            : (json['legacy'] is Map<String, dynamic>
                ? json['legacy'] as Map<String, dynamic>
                : null);

    // 头像：优先高清原图，回落到 normal 大小
    final avatarRaw =
        (result?['legacy']?['profile_image_url_https'] ?? legacy?['profile_image_url_https'] ?? result?['profile_image_url'] ?? legacy?['profile_image_url']) as String?;
    final avatar = avatarRaw?.replaceFirst('_normal', '_400x400');

    return TwitterUser(
      id: (result?['rest_id'] ?? legacy?['id_str']) as String?,
      name: (result?['legacy']?['name'] ?? legacy?['name']) as String?,
      screenName:
          (result?['legacy']?['screen_name'] ?? legacy?['screen_name']) as String?,
      description:
          (result?['legacy']?['description'] ?? legacy?['description']) as String?,
      avatar: avatar,
      mediaCount: _tryInt(result?['media_count'] ?? legacy?['media_count']),
      followersCount: _tryInt(
          result?['legacy']?['followers_count'] ?? legacy?['followers_count']),
      friendsCount: _tryInt(
          result?['legacy']?['friends_count'] ?? legacy?['friends_count']),
    );
  }

  static int? _tryInt(dynamic v) {
    if (v == null) return null;
    if (v is int) return v;
    if (v is String) return int.tryParse(v);
    return null;
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'screen_name': screenName,
        'description': description,
        'profile_image_url': avatar?.replaceFirst('_400x400', '_normal'),
        'media_count': mediaCount,
        'followers_count': followersCount,
        'friends_count': friendsCount,
      };

  /// 从 JSON 字符串解析（用于持久化）。
  static TwitterUser? tryDecode(String s) {
    try {
      final m = jsonDecode(s) as Map<String, dynamic>;
      return TwitterUser(
        id: m['id'] as String?,
        name: m['name'] as String?,
        screenName: m['screen_name'] as String?,
        description: m['description'] as String?,
        avatar: m['avatar'] as String?,
        mediaCount: m['media_count'] as int?,
        followersCount: m['followers_count'] as int?,
        friendsCount: m['friends_count'] as int?,
      );
    } catch (_) {
      return null;
    }
  }

  String encode() => jsonEncode(toJson());
}