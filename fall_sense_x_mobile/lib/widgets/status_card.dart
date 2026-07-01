import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

/// Device summary card for the Home dashboard, mirroring the
/// "Presence Sensor / Presence detected" cards in the Tuya reference UI.
class StatusCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String statusText;
  final String? subtitle;
  final bool isOnline;
  final VoidCallback? onTap;

  const StatusCard({
    super.key,
    required this.icon,
    required this.title,
    required this.statusText,
    this.subtitle,
    this.isOnline = true,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Icon(icon, color: AppColors.accent, size: 22),
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: isOnline ? AppColors.statusOnline : AppColors.statusOffline,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                statusText,
                style: const TextStyle(
                  fontSize: 13,
                  color: AppColors.textSecondary,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 4),
              Text(
                title,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textPrimary,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              if (subtitle != null) ...[
                const SizedBox(height: 4),
                Text(
                  subtitle!,
                  style: const TextStyle(fontSize: 11, color: AppColors.textSecondary),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class SectionHeader extends StatelessWidget {
  final String title;
  final Widget? trailing;

  const SectionHeader({super.key, required this.title, this.trailing});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            title,
            style: const TextStyle(
              fontSize: 13,
              color: AppColors.textSecondary,
              fontWeight: FontWeight.w500,
            ),
          ),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}

/// A single settings row used across Device Settings / Manage Home / Profile,
/// mirroring the white-card list rows in the reference screens.
class SettingsTile extends StatelessWidget {
  final IconData? icon;
  final String title;
  final String? value;
  final String? subtitle;
  final VoidCallback? onTap;
  final Widget? trailingWidget;
  final Color? titleColor;
  /// When set, draws [icon] inside a colored circle (matching the premium
  /// reference's Settings/Device Settings rows) instead of a bare icon.
  final Color? iconCircleColor;

  const SettingsTile({
    super.key,
    this.icon,
    required this.title,
    this.value,
    this.subtitle,
    this.onTap,
    this.trailingWidget,
    this.titleColor,
    this.iconCircleColor,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            if (icon != null) ...[
              if (iconCircleColor != null)
                CircleAvatar(radius: 16, backgroundColor: iconCircleColor!.withValues(alpha: 0.12), child: Icon(icon, size: 16, color: iconCircleColor))
              else
                Icon(icon, size: 20, color: AppColors.textPrimary),
              const SizedBox(width: 16),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 16,
                      color: titleColor ?? AppColors.textPrimary,
                    ),
                  ),
                  if (subtitle != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      subtitle!,
                      style: const TextStyle(fontSize: 12, color: AppColors.textSecondary),
                    ),
                  ],
                ],
              ),
            ),
            if (value != null)
              Text(value!, style: const TextStyle(color: AppColors.textSecondary)),
            if (trailingWidget != null) trailingWidget!,
            if (onTap != null)
              const Padding(
                padding: EdgeInsets.only(left: 4),
                child: Icon(Icons.chevron_right, color: AppColors.textSecondary, size: 20),
              ),
          ],
        ),
      ),
    );
  }
}

class SettingsSectionCard extends StatelessWidget {
  final List<Widget> children;

  const SettingsSectionCard({super.key, required this.children});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Column(
        children: [
          for (var i = 0; i < children.length; i++) ...[
            children[i],
            if (i != children.length - 1)
              const Divider(height: 1, indent: 16, endIndent: 16),
          ],
        ],
      ),
    );
  }
}
