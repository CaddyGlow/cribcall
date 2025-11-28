import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/models.dart';
import '../../identity/device_identity.dart';
import '../../state/app_state.dart';
import '../../theme.dart';
import '../../util/format_utils.dart';
import '../listener/listener_dashboard.dart';
import '../monitor/monitor_dashboard.dart';

const List<int> kMonitorMinDurationOptionsMs = [100, 200, 300, 500, 800];
const List<int> kMonitorCooldownOptionsSec = [3, 5, 8, 10, 15, 30];

List<DropdownMenuItem<int>> monitorDropdownItems({
  required int selected,
  required List<int> baseOptions,
  required String suffix,
}) {
  final options = <int>{...baseOptions, selected}.toList()..sort();

  return options
      .map(
        (value) => DropdownMenuItem<int>(
          value: value,
          child: Text(
            '$value$suffix${baseOptions.contains(value) ? '' : ' (custom)'}',
          ),
        ),
      )
      .toList();
}

class RoleSelectionPage extends ConsumerStatefulWidget {
  const RoleSelectionPage({super.key});

  @override
  ConsumerState<RoleSelectionPage> createState() => _RoleSelectionPageState();
}

class _RoleSelectionPageState extends ConsumerState<RoleSelectionPage> {
  int _selectedIndex = 0;
  bool _sessionRestored = false;

  @override
  void initState() {
    super.initState();
    _restoreSession();
  }

  Future<void> _restoreSession() async {
    // Wait for session to load
    final session = await ref.read(appSessionProvider.future);

    if (!mounted) return;

    setState(() {
      // Restore tab selection based on last role
      if (session.lastRole == DeviceRole.listener) {
        _selectedIndex = 1;
      } else {
        _selectedIndex = 0;
      }
      _sessionRestored = true;
    });

    // Restore monitoring status
    ref
        .read(monitoringStatusProvider.notifier)
        .restoreFromSession(session.monitoringEnabled);

    // Restore role
    if (session.lastRole != null) {
      ref.read(roleProvider.notifier).restoreFromSession(session.lastRole);
    }
  }

  @override
  Widget build(BuildContext context) {
    final identityAsync = ref.watch(identityProvider);
    // Keep roleProvider in sync for other parts of the app
    final currentRole = _selectedIndex == 0
        ? DeviceRole.monitor
        : DeviceRole.listener;

    // Update role provider when tab changes (only after session is restored)
    if (_sessionRestored) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final role = ref.read(roleProvider);
        if (role != currentRole) {
          ref.read(roleProvider.notifier).select(currentRole);
        }
      });
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('CribCall'),
        actions: [
          // Device fingerprint chip
          identityAsync.when(
            data: (identity) =>
                _FingerprintChip(fingerprint: identity.certFingerprint),
            loading: () => const Padding(
              padding: EdgeInsets.only(right: 8),
              child: Chip(label: Text('...')),
            ),
            error: (_, __) => const SizedBox.shrink(),
          ),
          // Settings button
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: 'Settings',
            onPressed: () => _showSettingsSheet(context, ref, currentRole),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: IndexedStack(
        index: _selectedIndex,
        children: const [
          SingleChildScrollView(
            padding: EdgeInsets.symmetric(horizontal: 18, vertical: 16),
            child: MonitorDashboard(),
          ),
          SingleChildScrollView(
            padding: EdgeInsets.symmetric(horizontal: 18, vertical: 16),
            child: ListenerDashboard(),
          ),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _selectedIndex,
        onDestinationSelected: (index) {
          setState(() {
            _selectedIndex = index;
          });
        },
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.sensors_outlined),
            selectedIcon: Icon(Icons.sensors),
            label: 'Monitor',
          ),
          NavigationDestination(
            icon: Icon(Icons.hearing_outlined),
            selectedIcon: Icon(Icons.hearing),
            label: 'Listener',
          ),
        ],
      ),
    );
  }
}

/// Fingerprint chip that shows short fingerprint and copies full on tap.
class _FingerprintChip extends StatelessWidget {
  const _FingerprintChip({required this.fingerprint});

  final String fingerprint;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 4),
      child: ActionChip(
        avatar: const Icon(Icons.fingerprint, size: 18),
        label: Text(shortFingerprint(fingerprint)),
        tooltip: 'Tap to copy fingerprint',
        onPressed: () {
          Clipboard.setData(ClipboardData(text: fingerprint));
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Fingerprint copied to clipboard'),
              duration: Duration(seconds: 2),
            ),
          );
        },
      ),
    );
  }
}

/// Shows the settings bottom sheet.
void _showSettingsSheet(
  BuildContext context,
  WidgetRef ref,
  DeviceRole selectedRole,
) {
  showModalBottomSheet(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (context) => _SettingsSheet(selectedRole: selectedRole),
  );
}

/// Main settings sheet with tabs for monitor/listener/general settings.
class _SettingsSheet extends ConsumerWidget {
  const _SettingsSheet({required this.selectedRole});

  final DeviceRole selectedRole;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final identityAsync = ref.watch(identityProvider);

    return DraggableScrollableSheet(
      initialChildSize: 0.6,
      minChildSize: 0.4,
      maxChildSize: 0.9,
      expand: false,
      builder: (context, scrollController) {
        return DefaultTabController(
          length: 3,
          initialIndex: selectedRole == DeviceRole.listener ? 1 : 0,
          child: Column(
            children: [
              // Header
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: AppColors.primary.withValues(alpha: 0.1),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        Icons.settings,
                        color: AppColors.primary,
                        size: 20,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Settings',
                            style: Theme.of(context).textTheme.titleMedium
                                ?.copyWith(fontWeight: FontWeight.w800),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            'Configure monitor and listener behavior',
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(color: AppColors.muted),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 16),

              // Tabs
              const TabBar(
                tabs: [
                  Tab(text: 'Monitor'),
                  Tab(text: 'Listener'),
                  Tab(text: 'General'),
                ],
              ),

              // Tab content
              Expanded(
                child: TabBarView(
                  children: [
                    _MonitorSettingsTab(scrollController: scrollController),
                    _ListenerSettingsTab(scrollController: scrollController),
                    _GeneralSettingsTab(
                      scrollController: scrollController,
                      identityAsync: identityAsync,
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Monitor settings tab content.
class _MonitorSettingsTab extends ConsumerWidget {
  const _MonitorSettingsTab({required this.scrollController});

  final ScrollController scrollController;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settingsAsync = ref.watch(monitorSettingsProvider);
    final appSession = ref.watch(appSessionProvider);
    final deviceName = appSession.asData?.value.deviceName ?? 'Device';
    final displayName = appSession.asData?.value.displayName ?? deviceName;

    return settingsAsync.when(
      data: (settings) => ListView(
        controller: scrollController,
        padding: const EdgeInsets.all(16),
        children: [
          _SettingsTile(
            icon: Icons.label,
            title: 'Device name',
            subtitle: displayName,
            onTap: () => _showNameDialog(context, ref, deviceName),
          ),
          const SizedBox(height: 12),
          _SettingsTile(
            icon: Icons.volume_up,
            title: 'Noise threshold',
            subtitle: '${settings.noise.threshold}%',
            trailing: SizedBox(
              width: 150,
              child: Slider(
                value: settings.noise.threshold.toDouble().clamp(10, 100),
                min: 10,
                max: 100,
                divisions: 18,
                onChanged: (value) {
                  ref
                      .read(monitorSettingsProvider.notifier)
                      .setThreshold(value.round());
                },
              ),
            ),
          ),
          const SizedBox(height: 12),
          _SettingsTile(
            icon: Icons.mic,
            title: 'Input gain',
            subtitle: '${settings.audioInputGain}%',
            trailing: SizedBox(
              width: 150,
              child: Slider(
                value: settings.audioInputGain.toDouble().clamp(0, 200),
                min: 0,
                max: 200,
                divisions: 20,
                onChanged: (value) {
                  ref
                      .read(monitorSettingsProvider.notifier)
                      .setAudioInputGain(value.round());
                },
              ),
            ),
          ),
          const SizedBox(height: 12),
          _SettingsTile(
            icon: Icons.timer,
            title: 'Min duration',
            subtitle: '${settings.noise.minDurationMs}ms',
            trailing: DropdownButton<int>(
              value: settings.noise.minDurationMs,
              underline: const SizedBox.shrink(),
              onChanged: (value) {
                if (value != null) {
                  ref
                      .read(monitorSettingsProvider.notifier)
                      .setMinDurationMs(value);
                }
              },
              items: monitorDropdownItems(
                selected: settings.noise.minDurationMs,
                baseOptions: kMonitorMinDurationOptionsMs,
                suffix: 'ms',
              ),
            ),
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppColors.primary.withValues(alpha: 0.05),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: AppColors.primary.withValues(alpha: 0.1),
              ),
            ),
            child: Row(
              children: [
                Icon(
                  Icons.info_outline,
                  size: 18,
                  color: AppColors.primary.withValues(alpha: 0.7),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Cooldown and auto-stream settings are configured by listeners.',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: AppColors.muted,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('Error: $e')),
    );
  }

  Future<void> _showNameDialog(
    BuildContext context,
    WidgetRef ref,
    String currentName,
  ) async {
    final controller = TextEditingController(text: currentName);
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Device Name'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Name',
            hintText: 'e.g., Nursery Monitor',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (result != null && result.isNotEmpty) {
      ref.read(appSessionProvider.notifier).setDeviceName(result);
    }
  }
}

/// Listener settings tab content.
class _ListenerSettingsTab extends ConsumerWidget {
  const _ListenerSettingsTab({required this.scrollController});

  final ScrollController scrollController;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settingsAsync = ref.watch(listenerSettingsProvider);

    return settingsAsync.when(
      data: (settings) => ListView(
        controller: scrollController,
        padding: const EdgeInsets.all(16),
        children: [
          _SettingsTile(
            icon: Icons.notifications,
            title: 'Notifications',
            subtitle: settings.notificationsEnabled ? 'Enabled' : 'Disabled',
            trailing: Switch(
              value: settings.notificationsEnabled,
              onChanged: (_) {
                ref
                    .read(listenerSettingsProvider.notifier)
                    .toggleNotifications();
              },
            ),
          ),
          const SizedBox(height: 12),
          _SettingsTile(
            icon: Icons.touch_app,
            title: 'Default action on noise',
            subtitle: settings.defaultAction == ListenerDefaultAction.notify
                ? 'Show notification'
                : 'Auto-open stream',
            trailing: DropdownButton<ListenerDefaultAction>(
              value: settings.defaultAction,
              underline: const SizedBox.shrink(),
              onChanged: (value) {
                if (value != null) {
                  ref
                      .read(listenerSettingsProvider.notifier)
                      .setDefaultAction(value);
                }
              },
              items: const [
                DropdownMenuItem(
                  value: ListenerDefaultAction.notify,
                  child: Text('Notify'),
                ),
                DropdownMenuItem(
                  value: ListenerDefaultAction.autoOpenStream,
                  child: Text('Auto-open'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          _SettingsTile(
            icon: Icons.volume_up,
            title: 'Playback volume',
            subtitle: '${settings.playbackVolume}%',
            trailing: SizedBox(
              width: 150,
              child: Slider(
                value: settings.playbackVolume.toDouble().clamp(0, 200),
                min: 0,
                max: 200,
                divisions: 20,
                onChanged: (value) {
                  ref
                      .read(listenerSettingsProvider.notifier)
                      .setPlaybackVolume(value.round());
                },
              ),
            ),
          ),
        ],
      ),
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('Error: $e')),
    );
  }
}

/// General settings tab content.
class _GeneralSettingsTab extends ConsumerWidget {
  const _GeneralSettingsTab({
    required this.scrollController,
    required this.identityAsync,
  });

  final ScrollController scrollController;
  final AsyncValue<DeviceIdentity> identityAsync;

  Future<void> _confirmRegenerateIdentity(
    BuildContext context,
    WidgetRef ref,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Regenerate Identity?'),
        content: const Text(
          'This will create a new device ID and certificate. '
          'All paired devices will need to re-pair with this device.\n\n'
          'This action cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Regenerate'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      await ref.read(identityProvider.notifier).regenerate();

      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Identity regenerated. All pairings must be redone.'),
          duration: Duration(seconds: 4),
        ),
      );
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to regenerate identity: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ListView(
      controller: scrollController,
      padding: const EdgeInsets.all(16),
      children: [
        // Device identity section
        Text(
          'Device Identity',
          style: Theme.of(context).textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w700,
            color: AppColors.muted,
          ),
        ),
        const SizedBox(height: 12),
        identityAsync.when(
          data: (identity) => Column(
            children: [
              _SettingsTile(
                icon: Icons.perm_identity,
                title: 'Device ID',
                subtitle: identity.deviceId,
                onTap: () {
                  Clipboard.setData(ClipboardData(text: identity.deviceId));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Device ID copied'),
                      duration: Duration(seconds: 2),
                    ),
                  );
                },
              ),
              const SizedBox(height: 12),
              _SettingsTile(
                icon: Icons.fingerprint,
                title: 'Certificate Fingerprint',
                subtitle: identity.certFingerprint,
                onTap: () {
                  Clipboard.setData(
                    ClipboardData(text: identity.certFingerprint),
                  );
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Fingerprint copied'),
                      duration: Duration(seconds: 2),
                    ),
                  );
                },
              ),
              const SizedBox(height: 12),
              _SettingsTile(
                icon: Icons.refresh,
                title: 'Regenerate Identity',
                subtitle: 'Create new device ID and certificate',
                trailing: const Icon(
                  Icons.warning_amber,
                  color: Colors.orange,
                  size: 20,
                ),
                onTap: () => _confirmRegenerateIdentity(context, ref),
              ),
            ],
          ),
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => Text('Error: $e'),
        ),
        const SizedBox(height: 24),
        // About section
        Text(
          'About',
          style: Theme.of(context).textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w700,
            color: AppColors.muted,
          ),
        ),
        const SizedBox(height: 12),
        const _SettingsTile(
          icon: Icons.info,
          title: 'Version',
          subtitle: '1.0.0',
        ),
        const SizedBox(height: 12),
        const _SettingsTile(
          icon: Icons.security,
          title: 'Security',
          subtitle: 'LAN-only, mTLS, pinned certificates',
        ),
      ],
    );
  }
}

/// Reusable settings tile widget.
class _SettingsTile extends StatelessWidget {
  const _SettingsTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.trailing,
    this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.surface,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.grey.shade200),
          ),
          child: Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: AppColors.primary.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(icon, color: AppColors.primary, size: 18),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: Theme.of(
                        context,
                      ).textTheme.bodySmall?.copyWith(color: AppColors.muted),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              if (trailing != null) ...[
                const SizedBox(width: 8),
                trailing!,
              ] else if (onTap != null) ...[
                const SizedBox(width: 8),
                Icon(Icons.chevron_right, color: AppColors.muted, size: 20),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
