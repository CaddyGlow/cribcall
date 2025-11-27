import 'package:cribcall/src/domain/models.dart';
import 'package:cribcall/src/features/landing/role_selection_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('monitor dropdown items include defaults', () {
    final minDurationItems = monitorDropdownItems(
      selected: NoiseSettings.defaults.minDurationMs,
      baseOptions: kMonitorMinDurationOptionsMs,
      suffix: 'ms',
    );

    final cooldownItems = monitorDropdownItems(
      selected: NoiseSettings.defaults.cooldownSeconds,
      baseOptions: kMonitorCooldownOptionsSec,
      suffix: 's',
    );

    expect(
      minDurationItems.map((item) => item.value),
      contains(NoiseSettings.defaults.minDurationMs),
    );
    expect(
      cooldownItems.map((item) => item.value),
      contains(NoiseSettings.defaults.cooldownSeconds),
    );
  });

  test('monitor dropdown items stay sorted and mark custom values', () {
    const customValue = 750;
    final items = monitorDropdownItems(
      selected: customValue,
      baseOptions: const [100, 200, 500],
      suffix: 'ms',
    );

    expect(
      items.map((item) => item.value),
      orderedEquals([100, 200, 500, customValue]),
    );

    final customLabel =
        (items.firstWhere((item) => item.value == customValue).child as Text)
            .data;
    final baseLabel =
        (items.firstWhere((item) => item.value == 200).child as Text).data;

    expect(customLabel, '750ms (custom)');
    expect(baseLabel, '200ms');
  });
}
