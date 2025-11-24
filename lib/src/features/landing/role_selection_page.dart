import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/models.dart';
import '../../state/app_state.dart';
import '../../theme.dart';
import '../listener/listener_dashboard.dart';
import '../monitor/monitor_dashboard.dart';

class RoleSelectionPage extends ConsumerWidget {
  const RoleSelectionPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selectedRole = ref.watch(roleProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('CribCall'),
        actions: const [
          Padding(
            padding: EdgeInsets.only(right: 12),
            child: Chip(label: Text('LAN only • QUIC + WebRTC')),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _HeroBanner(role: selectedRole),
            const SizedBox(height: 18),
            _RoleSwitcher(selectedRole: selectedRole),
            const SizedBox(height: 18),
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 250),
              child: selectedRole == null
                  ? _RoleCards(
                      onSelect: (role) {
                        ref.read(roleProvider.notifier).select(role);
                      },
                    )
                  : selectedRole == DeviceRole.monitor
                  ? const MonitorDashboard()
                  : const ListenerDashboard(),
            ),
          ],
        ),
      ),
    );
  }
}

class _HeroBanner extends StatelessWidget {
  const _HeroBanner({required this.role});

  final DeviceRole? role;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF3B82F6), Color(0xFF60A5FA)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Local-first baby monitor',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              color: Colors.white70,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            role == null
                ? 'Choose monitor or listener to get started.'
                : 'You are setting up the ${role!.name} role.',
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
              color: Colors.white,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 10),
          const Row(
            children: [
              _HeroPill(text: 'Pinned cert fingerprints'),
              SizedBox(width: 8),
              _HeroPill(text: 'RFC 8785 transcripts'),
              SizedBox(width: 8),
              _HeroPill(text: 'QUIC control • WebRTC media'),
            ],
          ),
        ],
      ),
    );
  }
}

class _RoleSwitcher extends ConsumerWidget {
  const _RoleSwitcher({required this.selectedRole});

  final DeviceRole? selectedRole;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final chips = DeviceRole.values.map<Widget>((role) {
      final isSelected = selectedRole == role;
      return ChoiceChip(
        label: Text(
          role == DeviceRole.monitor ? 'Monitor device' : 'Listener device',
        ),
        selected: isSelected,
        onSelected: (_) {
          ref.read(roleProvider.notifier).select(role);
        },
      );
    }).toList();

    if (selectedRole != null) {
      chips.add(
        ActionChip(
          label: const Text('Reset'),
          onPressed: () => ref.read(roleProvider.notifier).reset(),
        ),
      );
    }

    return Wrap(spacing: 10, runSpacing: 10, children: chips);
  }
}

class _RoleCards extends StatelessWidget {
  const _RoleCards({required this.onSelect});

  final void Function(DeviceRole) onSelect;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final isWide = constraints.maxWidth > 760;
        final children = [
          _RoleCard(
            title: 'Monitor',
            subtitle:
                'Lives in the nursery. Captures audio/video, detects noise, and advertises itself.',
            icon: Icons.sensors,
            highlights: const [
              'Runs QUIC control server',
              'Sound detection with cooldown',
              'Shows QR or PIN for pairing',
            ],
            buttonLabel: 'Use as Monitor',
            onTap: () => onSelect(DeviceRole.monitor),
          ),
          _RoleCard(
            title: 'Listener',
            subtitle:
                'Stays with the parent. Discovers monitors, validates pinned certs, and opens streams.',
            icon: Icons.hearing,
            highlights: const [
              'Scan QR or LAN for monitors',
              'Receives NOISE_EVENT alerts',
              'Starts audio or video streams',
            ],
            buttonLabel: 'Use as Listener',
            onTap: () => onSelect(DeviceRole.listener),
          ),
        ];

        return isWide
            ? Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: children
                    .map(
                      (child) => Expanded(
                        child: Padding(
                          padding: const EdgeInsets.only(right: 14),
                          child: child,
                        ),
                      ),
                    )
                    .toList(),
              )
            : Column(
                children: children
                    .map(
                      (child) => Padding(
                        padding: const EdgeInsets.only(bottom: 14),
                        child: child,
                      ),
                    )
                    .toList(),
              );
      },
    );
  }
}

class _RoleCard extends StatelessWidget {
  const _RoleCard({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.highlights,
    required this.buttonLabel,
    required this.onTap,
  });

  final String title;
  final String subtitle;
  final IconData icon;
  final List<String> highlights;
  final String buttonLabel;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: AppColors.primary.withValues(alpha: 0.1),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(icon, color: AppColors.primary),
                ),
                const SizedBox(width: 10),
                Text(
                  title,
                  style: Theme.of(
                    context,
                  ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              subtitle,
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: AppColors.muted),
            ),
            const SizedBox(height: 12),
            ...highlights.map(
              (h) => Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  children: [
                    const Icon(
                      Icons.check_circle,
                      color: AppColors.success,
                      size: 18,
                    ),
                    const SizedBox(width: 8),
                    Expanded(child: Text(h)),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            FilledButton(onPressed: onTap, child: Text(buttonLabel)),
          ],
        ),
      ),
    );
  }
}

class _HeroPill extends StatelessWidget {
  const _HeroPill({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        text,
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
          color: Colors.white,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}
