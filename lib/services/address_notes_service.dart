import 'package:supabase_flutter/supabase_flutter.dart';

/// Property notes that outlive a single job (see
/// supabase/migrations/20260803120000_address_notes.sql).
///
/// Notes hang off the ADDRESS, not the job, so the next provider sent to a
/// property inherits what the last one learned — gate codes, a bad dog, the
/// septic lid you must not plow over.
///
/// SECURITY: these are provider↔admin notes and are NEVER shown to customers,
/// exactly like jobs.provider_notes. The database enforces that (the SELECT
/// policy has no customer-ownership branch, verified by minting a real customer
/// session and getting 0 rows), but don't undermine it by rendering these in any
/// customer-facing screen.
class AddressNotesService {
  AddressNotesService._();

  static final _db = Supabase.instance.client;

  static const categories = <String, String>{
    'safety': 'Safety',
    'access': 'Access',
    'quirk': 'Property quirk',
  };

  /// Live (non-archived) notes for a property, newest first.
  /// Returns [] rather than throwing — a notes failure must never block the
  /// job card it's rendered inside.
  static Future<List<Map<String, dynamic>>> forAddress(String addressId) async {
    try {
      final rows = await _db
          .from('address_notes')
          .select('*, providers(provider_number, users(name))')
          .eq('address_id', addressId)
          .eq('archived', false)
          .order('created_at', ascending: false);
      return List<Map<String, dynamic>>.from(rows as List);
    } catch (_) {
      return [];
    }
  }

  /// Adds a note. author/provider_id are stamped server-side by a trigger, so a
  /// provider can't post as somebody else — don't send them from here.
  static Future<void> add({
    required String addressId,
    required String category,
    required String note,
  }) async {
    await _db.from('address_notes').insert({
      'address_id': addressId,
      'category': category,
      'note': note.trim(),
    });
  }

  /// Providers retract their own notes; the row survives for admin//claims.
  static Future<void> archive(String noteId) async {
    await _db.from('address_notes').update({'archived': true}).eq('id', noteId);
  }

  /// Admin-only at the database level.
  static Future<void> remove(String noteId) async {
    await _db.from('address_notes').delete().eq('id', noteId);
  }

  /// "Alfonso C. (#2)" / "SnowServ admin" — who to credit on a note.
  static String authorLabel(Map<String, dynamic> note) {
    if (note['author_role'] == 'admin') return 'SnowServ admin';
    final p = note['providers'];
    if (p == null) return 'A provider';
    final name = (p['users']?['name'] as String?)?.trim();
    final num = p['provider_number'];
    if (name == null || name.isEmpty) {
      return num == null ? 'A provider' : 'Provider #$num';
    }
    return num == null ? name : '$name (#$num)';
  }
}
