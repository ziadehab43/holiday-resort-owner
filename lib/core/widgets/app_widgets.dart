import 'package:flutter/material.dart';

import '../../app/theme.dart';

class PrimaryButton extends StatelessWidget {
  const PrimaryButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
  });
  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  @override
  Widget build(BuildContext context) => SizedBox(
    width: double.infinity,
    height: 52,
    child: FilledButton.icon(
      onPressed: onPressed,
      icon: icon == null ? const SizedBox.shrink() : Icon(icon),
      label: Text(
        label,
        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
      ),
      style: FilledButton.styleFrom(
        backgroundColor: AppColors.blue,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(11)),
      ),
    ),
  );
}

class ResortCard extends StatelessWidget {
  const ResortCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(18),
  });
  final Widget child;
  final EdgeInsets padding;
  @override
  Widget build(BuildContext context) => Container(
    padding: padding,
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(18),
      border: Border.all(color: const Color(0xFFE9EDF2)),
      boxShadow: const [
        BoxShadow(
          color: Color(0x100B2B4B),
          blurRadius: 14,
          offset: Offset(0, 5),
        ),
      ],
    ),
    child: Material(color: Colors.transparent, child: child),
  );
}

class ResortAppBar extends StatelessWidget implements PreferredSizeWidget {
  const ResortAppBar(this.title, {super.key});
  final String title;
  @override
  Size get preferredSize => const Size.fromHeight(58);
  @override
  Widget build(BuildContext context) => AppBar(
    backgroundColor: Colors.transparent,
    surfaceTintColor: Colors.transparent,
    elevation: 0,
    centerTitle: true,
    title: Text(title, style: Theme.of(context).textTheme.titleLarge),
    leading: Navigator.canPop(context)
        ? IconButton(
            icon: const Icon(Icons.arrow_back_ios_new, size: 19),
            onPressed: () => Navigator.pop(context),
          )
        : null,
  );
}

class BottomNav extends StatelessWidget {
  const BottomNav({
    super.key,
    required this.selected,
    required this.onHome,
    required this.onReport,
    required this.onHistory,
  });
  final int selected;
  final VoidCallback onHome, onReport, onHistory;
  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.fromLTRB(
      20,
      0,
      20,
      MediaQuery.paddingOf(context).bottom + 12,
    ),
    child: Container(
      height: 54,
      decoration: BoxDecoration(
        color: const Color(0xFFF3FAFC),
        borderRadius: BorderRadius.circular(28),
        border: Border.all(color: const Color(0xFF84C4D1)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          _BottomNavIcon(
            tooltip: 'الرئيسية',
            icon: Icons.home_rounded,
            selected: selected == 0,
            onTap: onHome,
          ),
          _BottomNavIcon(
            tooltip: 'بلاغ',
            icon: Icons.report_outlined,
            selected: selected == 1,
            onTap: onReport,
          ),
          _BottomNavIcon(
            tooltip: 'السجل',
            icon: Icons.calendar_month_outlined,
            selected: selected == 2,
            onTap: onHistory,
          ),
        ],
      ),
    ),
  );
}

class _BottomNavIcon extends StatelessWidget {
  const _BottomNavIcon({
    required this.tooltip,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  final String tooltip;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: tooltip,
    onPressed: selected ? null : onTap,
    icon: Container(
      width: 29,
      height: 29,
      decoration: BoxDecoration(
        color: selected ? AppColors.navy : Colors.transparent,
        shape: BoxShape.circle,
      ),
      child: Icon(
        icon,
        size: 18,
        color: selected ? Colors.white : AppColors.muted,
      ),
    ),
  );
}
