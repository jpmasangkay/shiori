import 'package:flutter/material.dart';

import '../services/platform_bridge.dart';
import '../theme.dart';

/// Opens a bottom sheet showing an Android `ConfigurableSource` extension's
/// native SharedPreferences (switches, list dropdowns, text inputs, multi-select).
Future<bool> showExtensionPreferencesSheet(
  BuildContext context, {
  required String pkg,
  required String name,
}) async {
  var changed = false;
  await showModalBottomSheet<void>(
    context: context,
    backgroundColor: AppColors.surface,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (ctx) => _ExtensionPreferencesSheet(
      pkg: pkg,
      name: name,
      onChanged: () => changed = true,
    ),
  );
  return changed;
}

class _ExtensionPreferencesSheet extends StatefulWidget {
  const _ExtensionPreferencesSheet({
    required this.pkg,
    required this.name,
    required this.onChanged,
  });

  final String pkg;
  final String name;
  final VoidCallback onChanged;

  @override
  State<_ExtensionPreferencesSheet> createState() =>
      _ExtensionPreferencesSheetState();
}

class _ExtensionPreferencesSheetState
    extends State<_ExtensionPreferencesSheet> {
  bool _loading = true;
  List<Map<String, dynamic>> _prefs = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final items = await PlatformBridge.instance.getExtensionPreferences(
      widget.pkg,
    );
    if (!mounted) return;
    setState(() {
      _prefs = items;
      _loading = false;
    });
  }

  Future<void> _savePref(Map<String, dynamic> pref, dynamic newValue) async {
    final key = pref['key']?.toString() ?? '';
    final type = pref['type']?.toString() ?? 'text';
    if (key.isEmpty) return;
    setState(() => pref['value'] = newValue);
    final ok = await PlatformBridge.instance.setExtensionPreference(
      pkg: widget.pkg,
      key: key,
      value: newValue,
      type: type,
    );
    if (ok) {
      widget.onChanged();
    }
  }

  @override
  Widget build(BuildContext context) {
    final maxH = MediaQuery.sizeOf(context).height * 0.78;
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxH),
        child: Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.viewInsetsOf(context).bottom + 12,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.only(top: 10, bottom: 12),
                decoration: BoxDecoration(
                  color: AppColors.outline,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
                child: Row(
                  children: [
                    const Icon(Icons.tune_rounded, color: AppColors.primary, size: 20),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        '${widget.name} Settings',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppText.sheetTitle,
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close_rounded, color: AppColors.muted),
                      onPressed: () => Navigator.pop(context),
                    ),
                  ],
                ),
              ),
              const Divider(color: AppColors.outline, height: 1),
              if (_loading)
                const Padding(
                  padding: EdgeInsets.all(32),
                  child: CircularProgressIndicator(color: AppColors.primary),
                )
              else if (_prefs.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(28),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.tune_rounded, color: AppColors.muted, size: 36),
                      const SizedBox(height: 10),
                      Text(
                        'No configurable settings exposed by this source.',
                        textAlign: TextAlign.center,
                        style: AppText.body.copyWith(color: AppColors.muted),
                      ),
                    ],
                  ),
                )
              else
                Flexible(
                  child: ListView.separated(
                    shrinkWrap: true,
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    itemCount: _prefs.length,
                    separatorBuilder: (_, _) =>
                        const Divider(color: AppColors.outline, height: 1),
                    itemBuilder: (ctx, i) => _buildPrefTile(_prefs[i]),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPrefTile(Map<String, dynamic> pref) {
    final type = pref['type']?.toString() ?? 'text';
    final title = pref['title']?.toString() ?? pref['key']?.toString() ?? 'Option';
    final summary = pref['summary']?.toString() ?? '';
    final value = pref['value'];

    if (type == 'switch' || type == 'checkbox') {
      final boolVal = value == true;
      return SwitchListTile(
        value: boolVal,
        activeThumbColor: AppColors.primary,
        title: Text(title, style: AppText.bodyMedium),
        subtitle: summary.isNotEmpty
            ? Text(summary, style: AppText.caption)
            : null,
        onChanged: (v) => _savePref(pref, v),
      );
    }

    if (type == 'list') {
      final entries = (pref['entries'] as List<dynamic>? ?? const [])
          .map((e) => e.toString())
          .toList();
      final entryValues = (pref['entryValues'] as List<dynamic>? ?? const [])
          .map((e) => e.toString())
          .toList();
      final curVal = value?.toString() ?? '';
      final curIdx = entryValues.indexOf(curVal);
      final curLabel = (curIdx >= 0 && curIdx < entries.length)
          ? entries[curIdx]
          : (summary.isNotEmpty ? summary : curVal);

      return ListTile(
        title: Text(title, style: AppText.bodyMedium),
        subtitle: Text(
          curLabel.isNotEmpty ? curLabel : 'Tap to choose',
          style: AppText.caption.copyWith(color: AppColors.primary),
        ),
        trailing: const Icon(Icons.chevron_right_rounded, color: AppColors.muted),
        onTap: entries.isEmpty
            ? null
            : () {
                showDialog<void>(
                  context: context,
                  builder: (dCtx) => SimpleDialog(
                    backgroundColor: AppColors.surface,
                    title: Text(title, style: AppText.sheetTitle),
                    children: [
                      for (var idx = 0; idx < entries.length; idx++)
                        ListTile(
                          title: Text(entries[idx], style: AppText.body),
                          trailing: (idx < entryValues.length &&
                                  entryValues[idx] == curVal)
                              ? const Icon(Icons.check_rounded, color: AppColors.primary)
                              : null,
                          onTap: () {
                            Navigator.pop(dCtx);
                            final chosen = idx < entryValues.length
                                ? entryValues[idx]
                                : entries[idx];
                            _savePref(pref, chosen);
                          },
                        ),
                    ],
                  ),
                );
              },
      );
    }

    if (type == 'multi_select') {
      final entries = (pref['entries'] as List<dynamic>? ?? const [])
          .map((e) => e.toString())
          .toList();
      final entryValues = (pref['entryValues'] as List<dynamic>? ?? const [])
          .map((e) => e.toString())
          .toList();
      final selected = (value as List<dynamic>? ?? const [])
          .map((e) => e.toString())
          .toSet();
      return ListTile(
        title: Text(title, style: AppText.bodyMedium),
        subtitle: Text(
          '${selected.length} selected${summary.isNotEmpty ? ' • $summary' : ''}',
          style: AppText.caption,
        ),
        trailing: const Icon(Icons.chevron_right_rounded, color: AppColors.muted),
        onTap: entries.isEmpty
            ? null
            : () {
                final working = Set<String>.from(selected);
                showDialog<void>(
                  context: context,
                  builder: (dCtx) => StatefulBuilder(
                    builder: (dCtx, setDlg) => AlertDialog(
                      backgroundColor: AppColors.surface,
                      title: Text(title, style: AppText.sheetTitle),
                      content: SizedBox(
                        width: double.maxFinite,
                        child: ListView.builder(
                          shrinkWrap: true,
                          itemCount: entries.length,
                          itemBuilder: (_, idx) {
                            final v = idx < entryValues.length
                                ? entryValues[idx]
                                : entries[idx];
                            return CheckboxListTile(
                              value: working.contains(v),
                              activeColor: AppColors.primary,
                              title: Text(entries[idx], style: AppText.body),
                              onChanged: (checked) {
                                setDlg(() {
                                  if (checked == true) {
                                    working.add(v);
                                  } else {
                                    working.remove(v);
                                  }
                                });
                              },
                            );
                          },
                        ),
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(dCtx),
                          child: const Text('Cancel'),
                        ),
                        FilledButton(
                          onPressed: () {
                            Navigator.pop(dCtx);
                            _savePref(pref, working.toList());
                          },
                          child: const Text('Save'),
                        ),
                      ],
                    ),
                  ),
                );
              },
      );
    }

    // Default: text / EditTextPreference
    final textVal = value?.toString() ?? '';
    return ListTile(
      title: Text(title, style: AppText.bodyMedium),
      subtitle: Text(
        textVal.isNotEmpty
            ? textVal
            : (summary.isNotEmpty ? summary : 'Tap to edit'),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: AppText.caption,
      ),
      trailing: const Icon(Icons.edit_outlined, size: 18, color: AppColors.muted),
      onTap: () {
        final ctrl = TextEditingController(text: textVal);
        showDialog<void>(
          context: context,
          builder: (dCtx) => AlertDialog(
            backgroundColor: AppColors.surface,
            title: Text(title, style: AppText.sheetTitle),
            content: TextField(
              controller: ctrl,
              autofocus: true,
              style: AppText.body,
              decoration: InputDecoration(
                hintText: summary.isNotEmpty ? summary : 'Enter value',
                filled: true,
                fillColor: AppColors.surfaceHigh,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dCtx),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () {
                  Navigator.pop(dCtx);
                  _savePref(pref, ctrl.text.trim());
                },
                child: const Text('Save'),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Opens a dynamic `FilterList` bottom sheet for an Android Tachiyomi/Keiyoushi extension.
Future<List<Map<String, dynamic>>?> showExtensionFiltersSheet(
  BuildContext context, {
  required String pkg,
  required String name,
  List<Map<String, dynamic>>? initialFilters,
}) {
  return showModalBottomSheet<List<Map<String, dynamic>>>(
    context: context,
    backgroundColor: AppColors.surface,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (ctx) => _ExtensionFiltersSheet(
      pkg: pkg,
      name: name,
      initialFilters: initialFilters,
    ),
  );
}

class _ExtensionFiltersSheet extends StatefulWidget {
  const _ExtensionFiltersSheet({
    required this.pkg,
    required this.name,
    this.initialFilters,
  });

  final String pkg;
  final String name;
  final List<Map<String, dynamic>>? initialFilters;

  @override
  State<_ExtensionFiltersSheet> createState() => _ExtensionFiltersSheetState();
}

class _ExtensionFiltersSheetState extends State<_ExtensionFiltersSheet> {
  bool _loading = true;
  List<Map<String, dynamic>> _filters = [];

  @override
  void initState() {
    super.initState();
    if (widget.initialFilters != null && widget.initialFilters!.isNotEmpty) {
      _filters = _deepCopyFilters(widget.initialFilters!);
      _loading = false;
    } else {
      _loadFilters();
    }
  }

  List<Map<String, dynamic>> _deepCopyFilters(List<Map<String, dynamic>> src) {
    return src.map((item) {
      final copy = Map<String, dynamic>.from(item);
      if (copy['children'] is List) {
        copy['children'] = (copy['children'] as List)
            .whereType<Map>()
            .map((c) => Map<String, dynamic>.from(c))
            .toList();
      }
      return copy;
    }).toList();
  }

  Future<void> _loadFilters() async {
    setState(() => _loading = true);
    final raw = await PlatformBridge.instance.getExtensionFilters(widget.pkg);
    if (!mounted) return;
    setState(() {
      _filters = _deepCopyFilters(raw);
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final maxH = MediaQuery.sizeOf(context).height * 0.82;
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxH),
        child: Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.viewInsetsOf(context).bottom + 12,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.only(top: 10, bottom: 10),
                decoration: BoxDecoration(
                  color: AppColors.outline,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                child: Row(
                  children: [
                    const Icon(Icons.filter_list_rounded, color: AppColors.primary, size: 20),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '${widget.name} Filters',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppText.sheetTitle,
                      ),
                    ),
                    TextButton(
                      onPressed: _loadFilters,
                      child: const Text('Reset'),
                    ),
                    FilledButton(
                      onPressed: _filters.isEmpty
                          ? null
                          : () => Navigator.pop(context, _filters),
                      style: FilledButton.styleFrom(
                        backgroundColor: AppColors.primary,
                        foregroundColor: AppColors.onPrimary,
                        minimumSize: const Size(64, 38),
                      ),
                      child: const Text('Apply'),
                    ),
                  ],
                ),
              ),
              const Divider(color: AppColors.outline, height: 1),
              if (_loading)
                const Padding(
                  padding: EdgeInsets.all(32),
                  child: CircularProgressIndicator(color: AppColors.primary),
                )
              else if (_filters.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(28),
                  child: Text(
                    'This source does not expose custom search filters.',
                    textAlign: TextAlign.center,
                    style: AppText.body.copyWith(color: AppColors.muted),
                  ),
                )
              else
                Flexible(
                  child: ListView.builder(
                    shrinkWrap: true,
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    itemCount: _filters.length,
                    itemBuilder: (_, i) => _buildFilterItem(_filters[i]),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildFilterItem(Map<String, dynamic> item) {
    final type = item['type']?.toString() ?? '';
    final name = item['name']?.toString() ?? '';

    switch (type) {
      case 'header':
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Text(name.toUpperCase(), style: AppText.sectionHeader),
        );
      case 'separator':
        return const Divider(color: AppColors.outline, height: 16);
      case 'checkbox':
        final checked = item['state'] == true;
        return CheckboxListTile(
          dense: true,
          value: checked,
          activeColor: AppColors.primary,
          title: Text(name, style: AppText.bodyMedium),
          onChanged: (v) => setState(() => item['state'] = v ?? false),
        );
      case 'tristate':
        final state = (item['state'] as num?)?.toInt() ?? 0; // 0=ignore, 1=include, 2=exclude
        final IconData icon;
        final Color color;
        if (state == 1) {
          icon = Icons.check_box_rounded;
          color = AppColors.primary;
        } else if (state == 2) {
          icon = Icons.indeterminate_check_box_rounded;
          color = Colors.redAccent;
        } else {
          icon = Icons.check_box_outline_blank_rounded;
          color = AppColors.muted;
        }
        return ListTile(
          dense: true,
          leading: Icon(icon, color: color, size: 22),
          title: Text(name, style: AppText.bodyMedium),
          trailing: Text(
            state == 1 ? 'Include' : (state == 2 ? 'Exclude' : 'Any'),
            style: AppText.caption.copyWith(color: color),
          ),
          onTap: () => setState(() => item['state'] = (state + 1) % 3),
        );
      case 'select':
        final values = (item['values'] as List<dynamic>? ?? const [])
            .map((e) => e.toString())
            .toList();
        final idx = ((item['state'] as num?)?.toInt() ?? 0)
            .clamp(0, values.isEmpty ? 0 : values.length - 1);
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          child: Row(
            children: [
              Expanded(child: Text(name, style: AppText.bodyMedium)),
              if (values.isNotEmpty)
                DropdownButton<int>(
                  value: idx,
                  dropdownColor: AppColors.surfaceHigh,
                  underline: const SizedBox(),
                  style: AppText.body,
                  items: [
                    for (var i = 0; i < values.length; i++)
                      DropdownMenuItem(value: i, child: Text(values[i])),
                  ],
                  onChanged: (v) {
                    if (v != null) setState(() => item['state'] = v);
                  },
                ),
            ],
          ),
        );
      case 'sort':
        final values = (item['values'] as List<dynamic>? ?? const [])
            .map((e) => e.toString())
            .toList();
        final curIdx = ((item['index'] as num?)?.toInt() ?? 0)
            .clamp(0, values.isEmpty ? 0 : values.length - 1);
        final asc = item['ascending'] == true;
        return ExpansionTile(
          title: Text(name, style: AppText.bodyMedium),
          subtitle: values.isNotEmpty
              ? Text(
                  '${values[curIdx]} (${asc ? 'Asc' : 'Desc'})',
                  style: AppText.caption.copyWith(color: AppColors.primary),
                )
              : null,
          children: [
            for (var i = 0; i < values.length; i++)
              ListTile(
                dense: true,
                leading: Icon(
                  i == curIdx
                      ? (asc ? Icons.arrow_upward_rounded : Icons.arrow_downward_rounded)
                      : Icons.radio_button_unchecked_rounded,
                  size: 18,
                  color: i == curIdx ? AppColors.primary : AppColors.muted,
                ),
                title: Text(values[i], style: AppText.body),
                onTap: () {
                  setState(() {
                    if (curIdx == i) {
                      item['ascending'] = !asc;
                    } else {
                      item['index'] = i;
                      item['ascending'] = false;
                    }
                  });
                },
              ),
          ],
        );
      case 'text':
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          child: TextFormField(
            initialValue: item['state']?.toString() ?? '',
            style: AppText.body,
            decoration: InputDecoration(
              labelText: name,
              labelStyle: AppText.caption,
              filled: true,
              fillColor: AppColors.surfaceHigh,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide.none,
              ),
              isDense: true,
            ),
            onChanged: (v) => item['state'] = v,
          ),
        );
      case 'group':
        final children = (item['children'] as List<dynamic>? ?? const [])
            .whereType<Map<String, dynamic>>()
            .toList();
        return ExpansionTile(
          title: Text(name, style: AppText.bodyMedium),
          children: [for (final child in children) _buildFilterItem(child)],
        );
      default:
        return const SizedBox.shrink();
    }
  }
}
