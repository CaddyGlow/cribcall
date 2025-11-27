import 'package:flutter/material.dart';

import '../../../theme.dart';

/// A standardized card container for CribCall UI.
///
/// Features a title, optional subtitle, optional badge with custom color,
/// and optional trailing widget (e.g., a switch).
class CcCard extends StatelessWidget {
  const CcCard({
    super.key,
    required this.title,
    this.subtitle,
    required this.children,
    this.badge,
    this.badgeColor,
    this.trailing,
  });

  final String title;
  final String? subtitle;
  final List<Widget> children;
  final String? badge;
  final Color? badgeColor;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      if (subtitle != null) ...[
                        const SizedBox(height: 4),
                        Text(
                          subtitle!,
                          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            color: AppColors.muted,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                if (badge != null)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: (badgeColor ?? AppColors.primary).withValues(
                        alpha: 0.12,
                      ),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      badge!,
                      style: TextStyle(
                        color: badgeColor ?? AppColors.primary,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                if (trailing != null) ...[
                  const SizedBox(width: 10),
                  trailing!,
                ],
              ],
            ),
            if (children.isNotEmpty) ...[
              const SizedBox(height: 12),
              ...children,
            ],
          ],
        ),
      ),
    );
  }
}
