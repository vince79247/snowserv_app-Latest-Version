import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Admin-only "Draft Assistant": paste an inbound customer/provider message and
/// get a reply DRAFT grounded in the SnowServ FAQ + policies (via the
/// support-draft edge function → Anthropic). You review/edit, then copy it and
/// send from your normal email. Nothing is sent from here — human-in-the-loop.
class SupportAssistantScreen extends StatefulWidget {
  const SupportAssistantScreen({super.key});

  @override
  State<SupportAssistantScreen> createState() => _SupportAssistantScreenState();
}

class _SupportAssistantScreenState extends State<SupportAssistantScreen> {
  final _messageCtrl = TextEditingController();
  final _extraCtrl = TextEditingController();
  final _draftCtrl = TextEditingController();
  String _senderType = 'unknown'; // unknown | customer | provider
  bool _loading = false;

  @override
  void dispose() {
    _messageCtrl.dispose();
    _extraCtrl.dispose();
    _draftCtrl.dispose();
    super.dispose();
  }

  Future<void> _draft() async {
    final msg = _messageCtrl.text.trim();
    if (msg.isEmpty) {
      _snack('Paste the customer\'s message first.');
      return;
    }
    setState(() => _loading = true);
    try {
      final res = await Supabase.instance.client.functions.invoke(
        'support-draft',
        body: {
          'customer_message': msg,
          'sender_type': _senderType,
          if (_extraCtrl.text.trim().isNotEmpty)
            'extra_instructions': _extraCtrl.text.trim(),
        },
      ).timeout(const Duration(seconds: 45));
      final data = res.data;
      final draft = data is Map ? data['draft'] as String? : null;
      if (draft != null && draft.isNotEmpty) {
        setState(() => _draftCtrl.text = draft);
      } else {
        final err = data is Map ? (data['error'] ?? 'Could not draft a reply.') : 'Could not draft a reply.';
        _snack('$err');
      }
    } catch (e) {
      _snack('Could not draft a reply: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _copy() {
    if (_draftCtrl.text.trim().isEmpty) return;
    Clipboard.setData(ClipboardData(text: _draftCtrl.text));
    _snack('Draft copied — paste it into your email reply.');
  }

  void _snack(String m) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Support Draft Assistant')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Paste a customer or provider message. I\'ll draft a reply grounded '
              'in the SnowServ FAQ & policies. Review and edit it, then copy and '
              'send from your email. Nothing is sent from here.',
              style: TextStyle(fontSize: 13, color: Colors.black54),
            ),
            const SizedBox(height: 16),
            const Text('Who is asking?',
                style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'unknown', label: Text('Not sure')),
                ButtonSegment(value: 'customer', label: Text('Customer')),
                ButtonSegment(value: 'provider', label: Text('Provider')),
              ],
              selected: {_senderType},
              onSelectionChanged: (s) => setState(() => _senderType = s.first),
            ),
            const SizedBox(height: 16),
            const Text('Their message',
                style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            TextField(
              controller: _messageCtrl,
              maxLines: 7,
              minLines: 4,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                hintText: 'Paste the customer\'s email or question here…',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _extraCtrl,
              maxLines: 2,
              minLines: 1,
              decoration: const InputDecoration(
                labelText: 'Optional: a note to steer the reply',
                hintText: 'e.g. "offer a refund", "keep it short", "apologize"',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            ElevatedButton.icon(
              onPressed: _loading ? null : _draft,
              icon: _loading
                  ? const SizedBox(
                      height: 18,
                      width: 18,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.auto_awesome),
              label: Text(_loading ? 'Drafting…' : 'Draft reply'),
            ),
            const SizedBox(height: 20),
            if (_draftCtrl.text.isNotEmpty) ...[
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('Draft (edit as needed)',
                      style: TextStyle(fontWeight: FontWeight.w600)),
                  TextButton.icon(
                    onPressed: _copy,
                    icon: const Icon(Icons.copy, size: 18),
                    label: const Text('Copy'),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              TextField(
                controller: _draftCtrl,
                maxLines: null,
                minLines: 8,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Always give it a read before sending — it can be wrong, and money '
                'or dispute questions should get your judgment.',
                style: TextStyle(fontSize: 12, color: Colors.black45),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
