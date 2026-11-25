import 'dart:async';

import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../src/rust/api/simple.dart' show configureDoh, dohCheck;
import 'doh_settings.dart';

enum _DohStatus { notTested, connected, unreachable }

class DohSettingsCard extends StatefulWidget {
  const DohSettingsCard({super.key, this.store, this.configure, this.check});

  final DohSettingsStore? store;
  final void Function(String endpoint)? configure;
  final Future<bool> Function(String endpoint)? check;

  @override
  State<DohSettingsCard> createState() => _DohSettingsCardState();
}

class _DohSettingsCardState extends State<DohSettingsCard> {
  late final DohSettingsStore _store = widget.store ?? DohSettingsStore();
  late final TextEditingController _customUrl = TextEditingController();
  bool _enabled = true;
  DohProvider _provider = DohProvider.cloudflare;
  _DohStatus _status = _DohStatus.notTested;
  bool _checking = false;

  String get _endpoint => DohSettings(
    enabled: _enabled,
    provider: _provider,
    customUrl: _customUrl.text,
  ).endpoint;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _customUrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final settings = await _store.load();
    if (!mounted) return;
    setState(() {
      _enabled = settings.enabled;
      _provider = settings.provider;
      _customUrl.text = settings.customUrl;
    });
    _apply();
  }

  Future<void> _apply() async {
    final settings = DohSettings(
      enabled: _enabled,
      provider: _provider,
      customUrl: _customUrl.text,
    );
    await _store.save(settings);
    final endpoint = settings.endpoint;
    try {
      if (widget.configure != null) {
        widget.configure!(endpoint);
      } else {
        configureDoh(endpoint: endpoint);
      }
    } on StateError {
      return;
    }
    if (mounted) setState(() => _status = _DohStatus.notTested);
  }

  Future<void> _check() async {
    final endpoint = _endpoint;
    if (endpoint.isEmpty || _checking || !mounted) return;
    setState(() => _checking = true);
    try {
      final ok = widget.check != null
          ? await widget.check!(endpoint)
          : await dohCheck(endpoint: endpoint);
      if (mounted) {
        setState(() {
          _status = ok ? _DohStatus.connected : _DohStatus.unreachable;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _status = _DohStatus.unreachable);
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 30),
        Row(
          children: [
            Expanded(
              child: Text(
                l10n.settingsDohTitle,
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.35,
                ),
              ),
            ),
            Switch(
              value: _enabled,
              onChanged: (value) {
                setState(() => _enabled = value);
                unawaited(_apply());
              },
            ),
          ],
        ),
        const SizedBox(height: 14),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final provider in DohProvider.values)
              ChoiceChip(
                label: Text(
                  provider == DohProvider.custom
                      ? l10n.settingsDohCustomUrl
                      : provider.name[0].toUpperCase() +
                          provider.name.substring(1),
                ),
                selected: _provider == provider,
                onSelected: (_) {
                  setState(() => _provider = provider);
                  unawaited(_apply());
                },
              ),
          ],
        ),
        if (_provider == DohProvider.custom) ...[
          const SizedBox(height: 12),
          TextField(
            controller: _customUrl,
            decoration: InputDecoration(labelText: l10n.settingsDohCustomUrl),
            onEditingComplete: () => unawaited(_apply()),
          ),
        ],
        const SizedBox(height: 12),
        Row(
          children: [
            Icon(
              _status == _DohStatus.connected
                  ? Icons.check_circle_rounded
                  : Icons.help_outline_rounded,
              size: 18,
              color: _status == _DohStatus.connected ? Colors.green : Colors.grey,
            ),
            const SizedBox(width: 6),
            Text(
              switch (_status) {
                _DohStatus.connected => l10n.settingsDohConnected,
                _DohStatus.unreachable => l10n.settingsDohUnreachable,
                _DohStatus.notTested => l10n.settingsDohNotTested,
              },
              style: TextStyle(
                color: _status == _DohStatus.connected ? Colors.green : Colors.grey,
              ),
            ),
            const Spacer(),
            TextButton(
              onPressed: _checking || !_enabled ? null : _check,
              child: Text(l10n.settingsDohCheck),
            ),
          ],
        ),
      ],
    );
  }
}
