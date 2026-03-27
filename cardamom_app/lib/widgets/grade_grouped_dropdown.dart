import 'package:flutter/material.dart';

/// Grade category constants and helpers used across the app.
class GradeHelper {
  GradeHelper._();

  static const categoryOrder = ['Colour', 'Fruit', 'Rejection', 'Seeds'];

  /// Categorise a grade string into one of four groups.
  static String category(String grade) {
    final g = grade.toLowerCase();
    if (g.contains('colour') || g.contains('color')) return 'Colour';
    if (g.contains('fruit')) return 'Fruit';
    if (g.contains('rejection') || g.contains('split') || g.contains('sick')) {
      return 'Rejection';
    }
    return 'Seeds';
  }

  // Extract the first number from a grade string (e.g. "7.5 to 8 mm" → 7.5)
  static double? _firstNumber(String grade) {
    final match = RegExp(r'(\d+\.?\d*)').firstMatch(grade);
    return match != null ? double.tryParse(match.group(1)!) : null;
  }

  /// Sort grades by category order: Colour → Fruit → Rejection → Seeds.
  /// Within each category: grades with numbers sort by highest number first,
  /// then non-numeric grades sort alphabetically at the end.
  static List<String> sorted(List<String> grades) {
    final list = List<String>.from(grades);
    list.sort((a, b) {
      final ca = categoryOrder.indexOf(category(a));
      final cb = categoryOrder.indexOf(category(b));
      if (ca != cb) return ca.compareTo(cb);
      // Within same category: sort by first number descending
      final na = _firstNumber(a);
      final nb = _firstNumber(b);
      if (na != null && nb != null) {
        if (na != nb) return nb.compareTo(na); // higher number first
        // Same first number — compare by second number descending
        final ma = RegExp(r'(\d+\.?\d*)').allMatches(a).toList();
        final mb = RegExp(r'(\d+\.?\d*)').allMatches(b).toList();
        if (ma.length > 1 && mb.length > 1) {
          final sa = double.tryParse(ma[1].group(1)!) ?? 0;
          final sb = double.tryParse(mb[1].group(1)!) ?? 0;
          if (sa != sb) return sb.compareTo(sa);
        }
        return a.compareTo(b);
      }
      // Numeric grades come before non-numeric
      if (na != null) return -1; // a has number, b doesn't → a first
      if (nb != null) return 1;  // b has number, a doesn't → b first
      return a.toLowerCase().compareTo(b.toLowerCase());
    });
    return list;
  }

  /// Build grouped display items (headers + grades) from a grade list.
  static List<GradeDisplayItem> grouped(List<String> grades) {
    final sorted = GradeHelper.sorted(grades);
    final List<GradeDisplayItem> items = [];
    String? lastCat;
    for (final g in sorted) {
      final cat = category(g);
      if (cat != lastCat) {
        items.add(GradeDisplayItem(label: cat, isHeader: true));
        lastCat = cat;
      }
      items.add(GradeDisplayItem(label: g, isHeader: false));
    }
    return items;
  }

  /// Category header text style.
  static const headerStyle = TextStyle(
    fontSize: 11,
    fontWeight: FontWeight.w800,
    color: Color(0xFF2D6A4F),
    letterSpacing: 0.5,
  );
}

/// Represents either a category header or a grade item in the dropdown.
class GradeDisplayItem {
  final String label;
  final bool isHeader;
  const GradeDisplayItem({required this.label, required this.isHeader});
}

/// Machined-style container decoration shared by searchable dropdowns.
BoxDecoration _machinedBoxDecoration() => BoxDecoration(
  color: const Color(0xFFF5F5F0),
  borderRadius: BorderRadius.circular(14),
  boxShadow: [
    BoxShadow(
      color: const Color(0xFF1E293B).withValues(alpha: 0.08),
      blurRadius: 4,
      offset: const Offset(2, 2),
    ),
    BoxShadow(
      color: Colors.white.withValues(alpha: 0.9),
      blurRadius: 4,
      offset: const Offset(-2, -2),
    ),
  ],
  border: Border.all(color: const Color(0xFFE0E0DB), width: 1),
);

/// Searchable autocomplete dropdown for grades with grouped category headers.
///
/// Type to filter, tap to select, X to clear. Groups grades into
/// Colour → Fruit → Rejection → Seeds with category subheadings.
class SearchableGradeDropdown extends StatefulWidget {
  final List<String> grades;
  final String? value;
  final ValueChanged<String?> onChanged;
  final bool showAllOption;
  final String hintText;

  const SearchableGradeDropdown({
    super.key,
    required this.grades,
    required this.onChanged,
    this.value,
    this.showAllOption = true,
    this.hintText = 'Search grade...',
  });

  @override
  State<SearchableGradeDropdown> createState() => _SearchableGradeDropdownState();
}

class _SearchableGradeDropdownState extends State<SearchableGradeDropdown> {
  // Track to prevent rebuild overwriting user edits while typing
  String? _lastSyncedValue;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return Autocomplete<String>(
          optionsBuilder: (TextEditingValue textEditingValue) {
            if (textEditingValue.text.isEmpty) {
              // Return sorted with 'All' first
              if (widget.showAllOption) {
                return ['All', ...GradeHelper.sorted(widget.grades)];
              }
              return GradeHelper.sorted(widget.grades);
            }
            final query = textEditingValue.text.toLowerCase();
            final filtered = widget.grades
                .where((g) => g.toLowerCase().contains(query))
                .toList();
            final sorted = GradeHelper.sorted(filtered);
            if (widget.showAllOption) return ['All', ...sorted];
            return sorted;
          },
          onSelected: (String selection) {
            widget.onChanged(selection == 'All' ? null : selection);
          },
          fieldViewBuilder: (context, textController, focusNode, onFieldSubmitted) {
            // Two-way sync: update text when parent value changes
            final expected = widget.value ?? '';
            if (_lastSyncedValue != expected && !focusNode.hasFocus) {
              textController.text = expected;
              if (expected.isNotEmpty) {
                textController.selection = TextSelection.collapsed(offset: expected.length);
              }
              _lastSyncedValue = expected;
            }
            return Container(
              decoration: _machinedBoxDecoration(),
              child: TextField(
                controller: textController,
                focusNode: focusNode,
                onSubmitted: (_) => onFieldSubmitted(),
                decoration: InputDecoration(
                  hintText: widget.hintText,
                  hintStyle: const TextStyle(color: Color(0xFF94A3B8), fontSize: 13, fontWeight: FontWeight.w500),
                  prefixIcon: Container(
                    margin: const EdgeInsets.all(8),
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(
                      color: const Color(0xFF10B981).withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Icon(Icons.diamond_rounded, size: 16, color: Color(0xFF10B981)),
                  ),
                  suffixIcon: textController.text.isNotEmpty
                      ? IconButton(
                          icon: const Icon(Icons.close, size: 16, color: Color(0xFF94A3B8)),
                          onPressed: () {
                            textController.clear();
                            widget.onChanged(null);
                          },
                        )
                      : const Padding(
                          padding: EdgeInsets.all(12),
                          child: Icon(Icons.keyboard_arrow_down_rounded, size: 16, color: Color(0xFF64748B)),
                        ),
                  filled: true,
                  fillColor: Colors.transparent,
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(vertical: 14, horizontal: 12),
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                ),
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: Color(0xFF1E293B)),
              ),
            );
          },
          optionsViewBuilder: (context, onSelected, options) {
            final optionList = options.toList();
            // Build grouped display — skip 'All' for grouping
            final bool hasAll = optionList.isNotEmpty && optionList.first == 'All';
            final gradesOnly = hasAll ? optionList.sublist(1) : optionList;
            final grouped = GradeHelper.grouped(gradesOnly);

            return Align(
              alignment: Alignment.topLeft,
              child: Material(
                elevation: 8,
                borderRadius: BorderRadius.circular(14),
                color: const Color(0xFFF8F8F5),
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxHeight: 280, maxWidth: constraints.maxWidth),
                  child: ListView.builder(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    shrinkWrap: true,
                    itemCount: (hasAll ? 1 : 0) + grouped.length,
                    itemBuilder: (context, index) {
                      // 'All' option first
                      if (hasAll && index == 0) {
                        return InkWell(
                          onTap: () => onSelected('All'),
                          child: const Padding(
                            padding: EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                            child: Text('All', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: Color(0xFF64748B))),
                          ),
                        );
                      }
                      final item = grouped[hasAll ? index - 1 : index];
                      if (item.isHeader) {
                        return Padding(
                          padding: const EdgeInsets.fromLTRB(14, 10, 14, 4),
                          child: Text(item.label, style: GradeHelper.headerStyle),
                        );
                      }
                      return InkWell(
                        onTap: () => onSelected(item.label),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                          child: Text(item.label, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xFF1E293B))),
                        ),
                      );
                    },
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }
}

/// Searchable autocomplete dropdown for client names.
///
/// Type to filter, tap to select, X to clear. Matches substring
/// case-insensitively.
class SearchableClientDropdown extends StatefulWidget {
  final List<String> clients;
  final String? value;
  final ValueChanged<String?> onChanged;
  final bool showAllOption;
  final bool showAddNew;
  final Future<void> Function(String)? onAddNew;
  final String hintText;

  const SearchableClientDropdown({
    super.key,
    required this.clients,
    required this.onChanged,
    this.value,
    this.showAllOption = true,
    this.showAddNew = false,
    this.onAddNew,
    this.hintText = 'Search client...',
  });

  @override
  State<SearchableClientDropdown> createState() => _SearchableClientDropdownState();
}

class _SearchableClientDropdownState extends State<SearchableClientDropdown> {
  // Prevent focus listener stacking across rebuilds
  FocusNode? _lastFocusNode;
  VoidCallback? _focusListener;
  // Track to prevent rebuild overwriting user edits while typing
  String? _lastSyncedValue;
  // Track whether user explicitly interacted with this dropdown
  bool _userIsInteracting = false;
  // Track whether user explicitly cleared the text (via X button)
  bool _userExplicitlyClearedText = false;

  @override
  void dispose() {
    if (_lastFocusNode != null && _focusListener != null) {
      _lastFocusNode!.removeListener(_focusListener!);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return Autocomplete<String>(
          optionsBuilder: (TextEditingValue textEditingValue) {
            final List<String> base = widget.showAllOption
                ? ['All', ...widget.clients]
                : List<String>.from(widget.clients);
            if (textEditingValue.text.isEmpty) return base;
            final query = textEditingValue.text.toLowerCase();
            final filtered = widget.clients
                .where((c) => c.toLowerCase().contains(query))
                .toList();
            final List<String> result = [];
            if (widget.showAllOption) result.add('All');
            result.addAll(filtered);
            // Add "add new" sentinel if enabled and no exact match
            if (widget.showAddNew &&
                textEditingValue.text.isNotEmpty &&
                !widget.clients.any((c) => c.toLowerCase() == query)) {
              result.add('__add_new__${textEditingValue.text.trim()}');
            }
            return result;
          },
          onSelected: (String selection) {
            if (selection.startsWith('__add_new__')) {
              final name = selection.replaceFirst('__add_new__', '');
              widget.onAddNew?.call(name);
              return;
            }
            _userIsInteracting = true;
            final val = selection == 'All' ? null : selection;
            _userExplicitlyClearedText = (val == null);
            debugPrint('[ClientDropdown] SELECTED: "$selection" → onChanged(${val == null ? "null" : '"$val"'})');
            widget.onChanged(val);
          },
          fieldViewBuilder: (context, textController, focusNode, onFieldSubmitted) {
            // Two-way sync: update text when parent value changes
            // (e.g., when another filter triggers setState)
            final expected = widget.value ?? '';
            if (_lastSyncedValue != expected && !focusNode.hasFocus) {
              textController.text = expected;
              if (expected.isNotEmpty) {
                textController.selection = TextSelection.collapsed(offset: expected.length);
              }
              _lastSyncedValue = expected;
            }
            // Register focus listener ONCE — prevent stacking on rebuilds
            if (_lastFocusNode != focusNode) {
              // Remove old listener if the focus node changed
              if (_lastFocusNode != null && _focusListener != null) {
                _lastFocusNode!.removeListener(_focusListener!);
              }
              _focusListener = () {
                if (!focusNode.hasFocus) {
                  final parentVal = widget.value ?? '';
                  debugPrint('[ClientDropdown] FOCUS LOST: _userIsInteracting=$_userIsInteracting text="${textController.text}" parentVal="$parentVal"');
                  // Always sync text to parent value on focus loss.
                  // Only fire onChanged if the user EXPLICITLY changed the text
                  // (typed something different or cleared it via X button).
                  if (!_userIsInteracting) {
                    // Not a user interaction — restore text to parent value.
                    if (textController.text != parentVal) {
                      debugPrint('[ClientDropdown] SYNC text from "${textController.text}" to "$parentVal" (no user interaction)');
                      textController.text = parentVal;
                    }
                    return;
                  }
                  _userIsInteracting = false;
                  final typed = textController.text.trim();
                  // If text matches current parent value, no change needed.
                  // This prevents redundant onChanged calls from focus events.
                  if (typed.toLowerCase() == parentVal.toLowerCase()) {
                    debugPrint('[ClientDropdown] SAME: typed="$typed" matches parent, no change');
                    return;
                  }
                  if (typed.isEmpty) {
                    if (parentVal.isNotEmpty && !_userExplicitlyClearedText) {
                      // Text was accidentally emptied (e.g., by Autocomplete
                      // or focus events from other dropdowns). Restore it.
                      debugPrint('[ClientDropdown] RESTORE: text empty but parent="$parentVal", restoring');
                      textController.text = parentVal;
                      return;
                    }
                    debugPrint('[ClientDropdown] CLEAR: empty text → onChanged(null)');
                    _userExplicitlyClearedText = false;
                    widget.onChanged(null);
                  } else {
                    final match = widget.clients.firstWhere(
                      (c) => c.toLowerCase() == typed.toLowerCase(),
                      orElse: () => '',
                    );
                    if (match.isNotEmpty) {
                      debugPrint('[ClientDropdown] MATCH: typed="$typed" → onChanged("$match")');
                      widget.onChanged(match);
                    } else {
                      // No match: restore to parent value to avoid stale state
                      debugPrint('[ClientDropdown] NO MATCH: typed="$typed" → restoring to "$parentVal"');
                      textController.text = parentVal;
                      // Don't clear the filter — keep current selection
                    }
                  }
                }
              };
              focusNode.addListener(_focusListener!);
              _lastFocusNode = focusNode;
            }
            return Container(
              decoration: _machinedBoxDecoration(),
              child: TextField(
                controller: textController,
                focusNode: focusNode,
                onTap: () {
                  _userIsInteracting = true;
                },
                onSubmitted: (text) {
                  _userIsInteracting = true;
                  onFieldSubmitted();
                  final typed = text.trim();
                  final match = widget.clients.firstWhere(
                    (c) => c.toLowerCase() == typed.toLowerCase(),
                    orElse: () => '',
                  );
                  if (match.isNotEmpty) {
                    widget.onChanged(match);
                  }
                },
                decoration: InputDecoration(
                  hintText: widget.hintText,
                  hintStyle: const TextStyle(color: Color(0xFF94A3B8), fontSize: 13, fontWeight: FontWeight.w500),
                  prefixIcon: Container(
                    margin: const EdgeInsets.all(8),
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF59E0B).withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Icon(Icons.person_rounded, size: 16, color: Color(0xFFF59E0B)),
                  ),
                  suffixIcon: textController.text.isNotEmpty
                      ? IconButton(
                          icon: const Icon(Icons.close, size: 16, color: Color(0xFF94A3B8)),
                          onPressed: () {
                            _userIsInteracting = true;
                            _userExplicitlyClearedText = true;
                            textController.clear();
                            widget.onChanged(null);
                          },
                        )
                      : const Padding(
                          padding: EdgeInsets.all(12),
                          child: Icon(Icons.keyboard_arrow_down_rounded, size: 16, color: Color(0xFF64748B)),
                        ),
                  filled: true,
                  fillColor: Colors.transparent,
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(vertical: 14, horizontal: 12),
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                ),
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: Color(0xFF1E293B)),
              ),
            );
          },
          optionsViewBuilder: (context, onSelected, options) {
            return Align(
              alignment: Alignment.topLeft,
              child: Material(
                elevation: 8,
                borderRadius: BorderRadius.circular(14),
                color: const Color(0xFFF8F8F5),
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxHeight: 250, maxWidth: constraints.maxWidth),
                  child: ListView.builder(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    shrinkWrap: true,
                    itemCount: options.length,
                    itemBuilder: (context, index) {
                      final option = options.elementAt(index);
                      // "Add new client" option
                      if (option.startsWith('__add_new__')) {
                        final name = option.replaceFirst('__add_new__', '');
                        return InkWell(
                          onTap: () => onSelected(option),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                            child: Row(
                              children: [
                                const CircleAvatar(
                                  radius: 12,
                                  backgroundColor: Color(0xFF22C55E),
                                  child: Icon(Icons.person_add, color: Colors.white, size: 12),
                                ),
                                const SizedBox(width: 8),
                                Text('Add "$name"', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xFF22C55E))),
                              ],
                            ),
                          ),
                        );
                      }
                      final isAll = option == 'All';
                      return InkWell(
                        onTap: () => onSelected(option),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                          child: Text(
                            option,
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: isAll ? FontWeight.w800 : FontWeight.w600,
                              color: isAll ? const Color(0xFF64748B) : const Color(0xFF1E293B),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }
}

/// A DropdownButtonFormField that groups grades by category with subheadings.
///
/// Drop-in replacement for a standard grade DropdownButtonFormField
/// wherever grade selection is needed. Tapping outside closes the dropdown
/// automatically (standard Flutter DropdownButtonFormField behaviour).
class GradeGroupedDropdown extends StatelessWidget {
  final String? value;
  final List<String> grades;
  final ValueChanged<String?>? onChanged;
  final InputDecoration? decoration;
  final bool isExpanded;
  final bool isDense;
  final double? menuMaxHeight;
  final TextStyle? itemStyle;

  const GradeGroupedDropdown({
    super.key,
    required this.grades,
    this.value,
    this.onChanged,
    this.decoration,
    this.isExpanded = true,
    this.isDense = true,
    this.menuMaxHeight = 350,
    this.itemStyle,
  });

  @override
  Widget build(BuildContext context) {
    final grouped = GradeHelper.grouped(grades);
    final effectiveStyle = itemStyle ?? const TextStyle(fontSize: 13);

    // Build DropdownMenuItems with disabled headers
    final List<DropdownMenuItem<String>> menuItems = [];
    for (final item in grouped) {
      if (item.isHeader) {
        menuItems.add(DropdownMenuItem<String>(
          enabled: false,
          value: '__header__${item.label}',
          child: Padding(
            padding: const EdgeInsets.only(top: 6, bottom: 2),
            child: Text(item.label, style: GradeHelper.headerStyle),
          ),
        ));
      } else {
        menuItems.add(DropdownMenuItem<String>(
          value: item.label,
          child: Text(item.label, style: effectiveStyle),
        ));
      }
    }

    return DropdownButtonFormField<String>(
      // ignore: deprecated_member_use
      value: (value != null && value!.isNotEmpty && grades.contains(value)) ? value : null,
      decoration: decoration ?? const InputDecoration(isDense: true),
      borderRadius: BorderRadius.circular(20),
      isExpanded: isExpanded,
      isDense: isDense,
      menuMaxHeight: menuMaxHeight ?? 350,
      items: menuItems,
      onChanged: (val) {
        // Ignore header taps (shouldn't happen since enabled: false)
        if (val != null && val.startsWith('__header__')) return;
        onChanged?.call(val);
      },
    );
  }
}
