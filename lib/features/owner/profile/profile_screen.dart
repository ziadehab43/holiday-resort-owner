import 'package:flutter/material.dart';

import '../../../app/routes.dart';
import '../../../app/theme.dart';
import '../../../core/widgets/app_widgets.dart';
import '../../../models/owner.dart';
import '../../../state/app_session.dart';

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller =
      AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 230),
      )..addListener(() {
        setState(() => _offset = _animation?.value ?? _offset);
      });
  Animation<double>? _animation;
  double _offset = 0;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _drag(DragUpdateDetails details) {
    _controller.stop();
    setState(() {
      _offset = (_offset + details.delta.dy).clamp(
        0,
        MediaQuery.sizeOf(context).height,
      );
    });
  }

  void _endDrag(DragEndDetails details) {
    final height = MediaQuery.sizeOf(context).height;
    final close =
        _offset > height * .16 || (details.primaryVelocity ?? 0) > 700;
    _animateTo(close ? height : 0, closeAfter: close);
  }

  Future<void> _animateTo(double target, {required bool closeAfter}) async {
    _controller
      ..stop()
      ..reset();
    _animation = Tween(
      begin: _offset,
      end: target,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic));
    await _controller.forward();
    if (closeAfter && mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final session = AppSessionScope.of(context);
    final owner = session.activeOwner;
    final height = MediaQuery.sizeOf(context).height * .84;
    return Material(
      color: Colors.transparent,
      child: Transform.translate(
        offset: Offset(0, _offset),
        child: Align(
          alignment: Alignment.bottomCenter,
          child: Container(
            height: height,
            width: double.infinity,
            decoration: const BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.vertical(top: Radius.circular(38)),
              boxShadow: [
                BoxShadow(
                  color: Color(0x300B2B4B),
                  blurRadius: 28,
                  offset: Offset(0, -6),
                ),
              ],
            ),
            child: SafeArea(
              top: false,
              child: Column(
                children: [
                  GestureDetector(
                    key: const Key('profile_drag_handle'),
                    behavior: HitTestBehavior.opaque,
                    onVerticalDragUpdate: _drag,
                    onVerticalDragEnd: _endDrag,
                    child: SizedBox(
                      height: 58,
                      child: Center(
                        child: Container(
                          width: 52,
                          height: 5,
                          decoration: BoxDecoration(
                            color: Colors.blueGrey.shade300,
                            borderRadius: BorderRadius.circular(4),
                          ),
                        ),
                      ),
                    ),
                  ),
                  Expanded(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(24, 4, 24, 24),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _OwnerHeader(
                            owner: owner,
                            ownerName: session.ownerName,
                            email: session.ownerEmail,
                          ),
                          const SizedBox(height: 28),
                          Text(
                            'وحداتي',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          const SizedBox(height: 10),
                          ResortCard(
                            padding: EdgeInsets.zero,
                            child: session.linkedOwners.isEmpty
                                ? const Padding(
                                    padding: EdgeInsets.all(18),
                                    child: Text(
                                      'لا توجد وحدات مرتبطة بالحساب حالياً.',
                                      textAlign: TextAlign.center,
                                    ),
                                  )
                                : Column(
                                    children: [
                                      for (
                                        var index = 0;
                                        index < session.linkedOwners.length;
                                        index++
                                      ) ...[
                                        _UnitTile(
                                          owner: session.linkedOwners[index],
                                          active:
                                              session
                                                  .linkedOwners[index]
                                                  .storageKey ==
                                              owner?.storageKey,
                                          onTap: () => session.switchOwner(
                                            session.linkedOwners[index],
                                          ),
                                        ),
                                        if (index <
                                            session.linkedOwners.length - 1)
                                          const Divider(height: 1),
                                      ],
                                    ],
                                  ),
                          ),
                          const SizedBox(height: 22),
                          ResortCard(
                            child: ListTile(
                              contentPadding: EdgeInsets.zero,
                              onTap: () async {
                                await session.logout();
                                if (!context.mounted) return;
                                Navigator.pushNamedAndRemoveUntil(
                                  context,
                                  AppRoutes.login,
                                  (route) => false,
                                );
                              },
                              leading: const Icon(
                                Icons.logout,
                                color: Colors.red,
                              ),
                              title: const Text(
                                'تسجيل الخروج',
                                style: TextStyle(
                                  fontWeight: FontWeight.w800,
                                  color: AppColors.navy,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _OwnerHeader extends StatelessWidget {
  const _OwnerHeader({
    required this.owner,
    required this.ownerName,
    required this.email,
  });
  final Owner? owner;
  final String ownerName, email;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      const CircleAvatar(
        radius: 34,
        backgroundColor: Color(0xFFEDF1F5),
        child: Icon(Icons.person_outline, size: 48, color: AppColors.muted),
      ),
      const SizedBox(width: 15),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(ownerName, style: Theme.of(context).textTheme.titleLarge),
            Text(email, textDirection: TextDirection.ltr),
            Text(
              owner == null
                  ? 'لا توجد وحدة مرتبطة'
                  : 'الوحدة الحالية ${owner!.unitLabel}',
            ),
          ],
        ),
      ),
    ],
  );
}

class _UnitTile extends StatelessWidget {
  const _UnitTile({
    required this.owner,
    required this.active,
    required this.onTap,
  });
  final Owner owner;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => ListTile(
    onTap: onTap,
    leading: CircleAvatar(
      backgroundColor: active ? const Color(0xFFDDF2F7) : AppColors.canvas,
      child: Icon(
        active ? Icons.check_rounded : Icons.apartment_rounded,
        color: active ? AppColors.blue : AppColors.muted,
      ),
    ),
    title: Text(
      'الوحدة ${owner.unitLabel}',
      style: const TextStyle(
        fontWeight: FontWeight.w800,
        color: AppColors.navy,
      ),
    ),
    subtitle: Text(active ? 'نشطة حالياً' : 'اضغط للتبديل إلى هذه الوحدة'),
  );
}
