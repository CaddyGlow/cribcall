import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../theme.dart';

/// Model for an audio input device.
class AudioInputDevice {
  const AudioInputDevice({
    required this.id,
    required this.name,
    this.isDefault = false,
  });

  final String id;
  final String name;
  final bool isDefault;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AudioInputDevice &&
          runtimeType == other.runtimeType &&
          id == other.id;

  @override
  int get hashCode => id.hashCode;
}

/// Provider for listing available audio input devices.
final audioInputDevicesProvider =
    FutureProvider.autoDispose<List<AudioInputDevice>>((ref) async {
  if (Platform.isLinux) {
    return _listLinuxAudioDevices();
  } else if (Platform.isAndroid) {
    // Android device enumeration would use platform channel
    return [
      const AudioInputDevice(
        id: 'default',
        name: 'Default microphone',
        isDefault: true,
      ),
    ];
  }
  return [];
});

/// List audio sources on Linux using pactl.
Future<List<AudioInputDevice>> _listLinuxAudioDevices() async {
  final devices = <AudioInputDevice>[];

  try {
    // Try pactl first
    final result = await Process.run('pactl', ['list', 'sources', 'short']);
    if (result.exitCode == 0) {
      final output = result.stdout as String;
      final lines = output.split('\n').where((l) => l.trim().isNotEmpty);

      for (final line in lines) {
        final parts = line.split('\t');
        if (parts.length >= 2) {
          final id = parts[1]; // Source name
          final name = _formatDeviceName(id);
          final isDefault = id.contains('default') || parts[0] == '0';
          devices.add(AudioInputDevice(
            id: id,
            name: name,
            isDefault: isDefault,
          ));
        }
      }
    }
  } catch (e) {
    // Fallback to default
    devices.add(const AudioInputDevice(
      id: '@DEFAULT_AUDIO_SOURCE@',
      name: 'Default audio source',
      isDefault: true,
    ));
  }

  // If no devices found, add default
  if (devices.isEmpty) {
    devices.add(const AudioInputDevice(
      id: '@DEFAULT_AUDIO_SOURCE@',
      name: 'Default audio source',
      isDefault: true,
    ));
  }

  return devices;
}

/// Format device name for display.
String _formatDeviceName(String id) {
  // Clean up common patterns
  var name = id
      .replaceAll('alsa_input.', '')
      .replaceAll('pci-', '')
      .replaceAll('.analog-stereo', ' (Analog)')
      .replaceAll('.mono', ' (Mono)')
      .replaceAll('_', ' ')
      .replaceAll('-', ' ');

  // Capitalize first letter of each word
  name = name.split(' ').map((word) {
    if (word.isEmpty) return word;
    return word[0].toUpperCase() + word.substring(1).toLowerCase();
  }).join(' ');

  return name;
}

/// Shows the device input settings modal.
void showDeviceInputSettingsModal(
  BuildContext context, {
  String? currentDeviceId,
  required void Function(String deviceId) onDeviceSelected,
}) {
  showModalBottomSheet(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (context) => DeviceInputSettingsSheet(
      currentDeviceId: currentDeviceId,
      onDeviceSelected: onDeviceSelected,
    ),
  );
}

/// Sheet content for device selection.
class DeviceInputSettingsSheet extends ConsumerWidget {
  const DeviceInputSettingsSheet({
    super.key,
    this.currentDeviceId,
    required this.onDeviceSelected,
  });

  final String? currentDeviceId;
  final void Function(String deviceId) onDeviceSelected;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final devicesAsync = ref.watch(audioInputDevicesProvider);

    return DraggableScrollableSheet(
      initialChildSize: 0.5,
      minChildSize: 0.3,
      maxChildSize: 0.8,
      expand: false,
      builder: (context, scrollController) {
        return Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Audio Input Device',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'Select the microphone to use for audio capture',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: AppColors.muted,
                ),
              ),
              const SizedBox(height: 16),
              Expanded(
                child: devicesAsync.when(
                  data: (devices) => devices.isEmpty
                      ? _buildEmptyState(context)
                      : ListView.builder(
                          controller: scrollController,
                          itemCount: devices.length,
                          itemBuilder: (context, index) {
                            final device = devices[index];
                            final isSelected = currentDeviceId == device.id ||
                                (currentDeviceId == null && device.isDefault);
                            return _DeviceListTile(
                              device: device,
                              isSelected: isSelected,
                              onTap: () {
                                onDeviceSelected(device.id);
                                Navigator.of(context).pop();
                              },
                            );
                          },
                        ),
                  loading: () => const Center(
                    child: CircularProgressIndicator(),
                  ),
                  error: (error, _) => _buildErrorState(context, error),
                ),
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: () => ref.refresh(audioInputDevicesProvider),
                  icon: const Icon(Icons.refresh),
                  label: const Text('Refresh devices'),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildEmptyState(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.mic_off,
            size: 48,
            color: AppColors.muted.withValues(alpha: 0.5),
          ),
          const SizedBox(height: 12),
          Text(
            'No audio devices found',
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w700,
              color: AppColors.muted,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Make sure a microphone is connected',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: AppColors.muted,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildErrorState(BuildContext context, Object error) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.error_outline,
            size: 48,
            color: Colors.red,
          ),
          const SizedBox(height: 12),
          Text(
            'Could not list devices',
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w700,
              color: AppColors.muted,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '$error',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: AppColors.muted,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

class _DeviceListTile extends StatelessWidget {
  const _DeviceListTile({
    required this.device,
    required this.isSelected,
    required this.onTap,
  });

  final AudioInputDevice device;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 0,
      color: isSelected
          ? AppColors.primary.withValues(alpha: 0.1)
          : Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: isSelected
              ? AppColors.primary.withValues(alpha: 0.3)
              : Colors.grey.shade200,
        ),
      ),
      child: ListTile(
        leading: Icon(
          Icons.mic,
          color: isSelected ? AppColors.primary : AppColors.muted,
        ),
        title: Text(
          device.name,
          style: TextStyle(
            fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
            color: isSelected ? AppColors.primary : null,
          ),
        ),
        subtitle: device.isDefault
            ? Text(
                'System default',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: AppColors.muted,
                ),
              )
            : null,
        trailing: isSelected
            ? const Icon(Icons.check_circle, color: AppColors.primary)
            : null,
        onTap: onTap,
      ),
    );
  }
}
