import 'package:flutter/material.dart';
import '../services/address_notes_service.dart';
import '../theme.dart';
import '../utils/job_helpers.dart';

/// Property notes for one address, shared by the provider job card and the
/// admin panel.
///
/// ⚠️ NEVER put this in a customer-facing screen. These are candid notes
/// between providers ("dog is aggressive", "owner disputes the walkway edge")
/// and the whole point is that the homeowner doesn't read them. The database
/// blocks it too — a customer session sees 0 rows even on their own address —
/// but the rule lives here as well so nobody wires it up by accident.
class SiteNotesPanel extends StatefulWidget {
  const SiteNotesPanel({
    super.key,
    required this.addressId,
    this.canAdd = true,
    this.isAdmin = false,
    this.dense = false,
    this.myProviderId,
  });

  final String addressId;

  /// Providers add notes from a job card; the admin panel is read/remove only.
  final bool canAdd;

  /// Admin gets hard delete; a provider can only retract their own note.
  final bool isAdmin;

  /// The viewing provider's providers.id. Only their OWN notes get a retract
  /// button — RLS rejects updating anyone else's, so offering the control would
  /// be a button that always fails.
  final String? myProviderId;

  /// Tighter spacing for the admin list.
  final bool dense;

  @override
  State<SiteNotesPanel> createState() => _SiteNotesPanelState();
}

class _SiteNotesPanelState extends State<SiteNotesPanel> {
  List<Map<String, dynamic>> _notes = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final rows = await AddressNotesService.forAddress(widget.addressId);
    if (!mounted) return;
    setState(() {
      _notes = rows;
      _loading = false;
    });
  }

  void _snack(String msg, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: error ? SnowServColors.danger : null,
    ));
  }

  static ({Color bg, Color border, Color fg, IconData icon}) _style(String cat) {
    switch (cat) {
      case 'safety':
        return (
          bg: const Color(0xFFFFF4E5),
          border: const Color(0xFFF0C48A),
          fg: SnowServColors.warning,
          icon: Icons.warning_amber_rounded
        );
      case 'access':
        return (
          bg: const Color(0xFFE8F1FC),
          border: const Color(0xFFB8D4F0),
          fg: SnowServColors.iceBlue,
          icon: Icons.vpn_key_outlined
        );
      case 'pricing':
        // Green rather than a warning color: this is money information for the
        // admin, not a hazard, and it should read as useful rather than alarming
        // to the next provider who sees it on the card.
        return (
          bg: const Color(0xFFE6F4EC),
          border: const Color(0xFF9FD3B8),
          fg: SnowServColors.success,
          icon: Icons.trending_up
        );
      default:
        return (
          bg: SnowServColors.surfaceSoft,
          border: SnowServColors.hairline,
          fg: SnowServColors.inkSoft,
          icon: Icons.lightbulb_outline
        );
    }
  }

  Future<void> _addDialog() async {
    String category = 'access';
    final controller = TextEditingController();
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: const Text('Add a site note'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Notes stay with this property for whoever works it next. '
                'The customer never sees them.',
                style: TextStyle(fontSize: 12, color: SnowServColors.inkSoft),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: category,
                decoration: const InputDecoration(
                  labelText: 'Type',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                items: AddressNotesService.categories.entries
                    .map((e) =>
                        DropdownMenuItem(value: e.key, child: Text(e.value)))
                    .toList(),
                onChanged: (v) => setLocal(() => category = v ?? 'access'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: controller,
                maxLines: 3,
                maxLength: 500,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  hintText: 'e.g. Gate code 4471. Dog is friendly but loud.',
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel')),
            ElevatedButton(
              onPressed: () async {
                if (controller.text.trim().isEmpty) return;
                try {
                  await AddressNotesService.add(
                    addressId: widget.addressId,
                    category: category,
                    note: controller.text,
                  );
                  if (ctx.mounted) Navigator.pop(ctx, true);
                } catch (e) {
                  if (ctx.mounted) Navigator.pop(ctx, false);
                  _snack('Could not save that note.', error: true);
                }
              },
              child: const Text('Save note'),
            ),
          ],
        ),
      ),
    );
    controller.dispose();
    if (saved == true) {
      _snack('Site note saved.');
      _load();
    }
  }

  Future<void> _removeNote(Map<String, dynamic> note) async {
    final isAdmin = widget.isAdmin;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(isAdmin ? 'Delete this note?' : 'Retract this note?'),
        content: Text(isAdmin
            ? 'This removes it permanently.'
            : 'It stops showing to other providers. SnowServ keeps a copy.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Keep')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(isAdmin ? 'Delete' : 'Retract',
                style: const TextStyle(color: SnowServColors.danger)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      if (isAdmin) {
        await AddressNotesService.remove(note['id']);
      } else {
        await AddressNotesService.archive(note['id']);
      }
      _load();
    } catch (_) {
      _snack('Could not remove that note.', error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const SizedBox.shrink();
    if (_notes.isEmpty && !widget.canAdd) return const SizedBox.shrink();

    return Padding(
      padding: EdgeInsets.only(top: widget.dense ? 6 : 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.push_pin_outlined,
                  size: 14, color: SnowServColors.inkSoft),
              const SizedBox(width: 5),
              Text(
                _notes.isEmpty
                    ? 'No site notes yet'
                    : 'Site notes (${_notes.length})',
                style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: SnowServColors.inkSoft),
              ),
              const Spacer(),
              if (widget.canAdd)
                TextButton.icon(
                  onPressed: _addDialog,
                  icon: const Icon(Icons.add, size: 15),
                  label: const Text('Add note'),
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    minimumSize: const Size(0, 30),
                    visualDensity: VisualDensity.compact,
                  ),
                ),
            ],
          ),
          ..._notes.map((n) {
            final s = _style('${n['category']}');
            final mine = widget.isAdmin ||
                (widget.myProviderId != null &&
                    n['provider_id'] == widget.myProviderId);
            return Container(
              width: double.infinity,
              margin: const EdgeInsets.only(bottom: 6),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: s.bg,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: s.border),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(s.icon, size: 15, color: s.fg),
                  const SizedBox(width: 7),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${n['note']}',
                          style: const TextStyle(
                              fontSize: 13, color: SnowServColors.ink),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '${AddressNotesService.categories[n['category']] ?? n['category']}'
                          ' · ${AddressNotesService.authorLabel(n)}'
                          ' · ${formatDate('${n['created_at']}')}',
                          style: const TextStyle(
                              fontSize: 10.5, color: SnowServColors.inkSoft),
                        ),
                      ],
                    ),
                  ),
                  if (mine)
                    InkWell(
                      onTap: () => _removeNote(n),
                      child: const Padding(
                        padding: EdgeInsets.all(2),
                        child: Icon(Icons.close,
                            size: 15, color: SnowServColors.inkSoft),
                      ),
                    ),
                ],
              ),
            );
          }),
        ],
      ),
    );
  }
}
