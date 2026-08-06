import 'package:flutter/material.dart';

/// A US state picker that writes the two-letter code into [controller].
///
/// Every state field in the app used to be free text with a hint of "NY", which
/// meant the database would collect "NY", "ny", "New York" and "N.Y." for the
/// same place. That breaks anything that filters or groups by state, and it
/// matters more than it looks: Stripe's automatic tax engine sources its rate
/// from the address, and a malformed state is a wrong tax calculation.
///
/// It's driven by a TextEditingController rather than a value + callback so it
/// drops straight into the existing screens, which all read `.text` on save.
class UsStateField extends StatefulWidget {
  const UsStateField({
    super.key,
    required this.controller,
    this.label = 'State',
    this.filled = false,
  });

  final TextEditingController controller;
  final String label;
  final bool filled;

  @override
  State<UsStateField> createState() => _UsStateFieldState();
}

class _UsStateFieldState extends State<UsStateField> {
  static const _states = <String>[
    'AL','AK','AZ','AR','CA','CO','CT','DE','DC','FL','GA','HI','ID','IL','IN',
    'IA','KS','KY','LA','ME','MD','MA','MI','MN','MS','MO','MT','NE','NV','NH',
    'NJ','NM','NY','NC','ND','OH','OK','OR','PA','RI','SC','SD','TN','TX','UT',
    'VT','VA','WA','WV','WI','WY',
  ];

  String? get _value {
    final v = widget.controller.text.trim().toUpperCase();
    return _states.contains(v) ? v : null;
  }

  @override
  Widget build(BuildContext context) {
    return DropdownButtonFormField<String>(
      // Long value lists want the button to fill its width, or the selected
      // item can run past the field's border on a narrow phone.
      isExpanded: true,
      initialValue: _value,
      decoration: InputDecoration(
        labelText: widget.label,
        prefixIcon: const Icon(Icons.map_outlined),
        filled: widget.filled ? true : null,
        fillColor: widget.filled ? Colors.white : null,
      ),
      items: [
        for (final s in _states) DropdownMenuItem(value: s, child: Text(s)),
      ],
      onChanged: (v) {
        if (v == null) return;
        setState(() => widget.controller.text = v);
      },
    );
  }
}
