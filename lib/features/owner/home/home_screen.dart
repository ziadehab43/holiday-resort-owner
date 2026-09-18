import 'dart:async';

import 'package:flutter/material.dart';
import 'package:timezone/timezone.dart' as tz;

import '../../../app/routes.dart';
import '../../../app/theme.dart';
import '../../../core/widgets/app_widgets.dart';
import '../../../models/owner.dart';
import '../../../services/guest_qr_backend.dart';
import '../../../state/app_session.dart';
import '../qr/qr_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  PageController? _pageController;
  Timer? _dayRolloverTimer;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _pageController ??= PageController(
      viewportFraction: AppSessionScope.of(context).linkedOwners.length > 1
          ? .88
          : 1,
    );
    _scheduleDayRollover();
  }

  @override
  void dispose() {
    _dayRolloverTimer?.cancel();
    _pageController?.dispose();
    super.dispose();
  }

  void _scheduleDayRollover() {
    if (_dayRolloverTimer?.isActive == true) return;
    final now = FirebaseGuestQrBackend.egyptTime(DateTime.now());
    final tomorrow = tz.TZDateTime(
      now.location,
      now.year,
      now.month,
      now.day + 1,
    );
    _dayRolloverTimer = Timer(tomorrow.difference(now), () {
      if (!mounted) return;
      setState(() {});
      _scheduleDayRollover();
    });
  }

  void _syncPage(AppSession session) {
    final activeOwner = session.activeOwner;
    if (activeOwner == null) return;
    final activeIndex = session.linkedOwners.indexWhere(
      (owner) => owner.storageKey == activeOwner.storageKey,
    );
    final controller = _pageController;
    if (controller == null || !controller.hasClients || activeIndex < 0) return;
    final visiblePage = controller.page?.round() ?? 0;
    if (visiblePage != activeIndex) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && controller.hasClients) {
          controller.animateToPage(
            activeIndex,
            duration: const Duration(milliseconds: 320),
            curve: Curves.easeOutCubic,
          );
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = AppSessionScope.of(context);
    final latestActivities = session.todayActiveHistory();
    _syncPage(session);
    return Scaffold(
      backgroundColor: const Color(0xFFF4FBFD),
      floatingActionButton: session.hasUnits
          ? FloatingActionButton(
              tooltip: 'إنشاء كود QR',
              onPressed: () =>
                  Navigator.pushNamed(context, AppRoutes.hospitality),
              backgroundColor: const Color(0xFFEAF7F9),
              foregroundColor: AppColors.navy,
              shape: const CircleBorder(
                side: BorderSide(color: Color(0xFF8BCAD5), width: 1.5),
              ),
              child: const Icon(Icons.qr_code_scanner_rounded, size: 29),
            )
          : null,
      floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
      bottomNavigationBar: BottomNav(
        selected: 0,
        onHome: () {},
        onReport: () => Navigator.pushNamed(context, AppRoutes.report),
        onHistory: () => Navigator.pushNamed(context, AppRoutes.history),
      ),
      body: SafeArea(
        bottom: false,
        child: CustomScrollView(
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(20, 24, 20, 14),
              sliver: SliverToBoxAdapter(
                child: _Header(
                  ownerName: session.ownerName,
                  onProfile: () =>
                      Navigator.pushNamed(context, AppRoutes.profile),
                ),
              ),
            ),
            SliverToBoxAdapter(
              child: session.hasUnits
                  ? SizedBox(
                      height: 136,
                      child: PageView.builder(
                        key: const Key('unit_carousel'),
                        controller: _pageController,
                        padEnds: false,
                        physics: session.linkedOwners.length > 1
                            ? const PageScrollPhysics()
                            : const NeverScrollableScrollPhysics(),
                        itemCount: session.linkedOwners.length,
                        onPageChanged: (index) =>
                            session.switchOwner(session.linkedOwners[index]),
                        itemBuilder: (context, index) {
                          final owner = session.linkedOwners[index];
                          return Padding(
                            padding: EdgeInsetsDirectional.only(
                              start: index == 0 ? 20 : 6,
                              end: 6,
                            ),
                            child: _UnitCard(
                              owner: owner,
                              history: session.historyFor(owner),
                            ),
                          );
                        },
                      ),
                    )
                  : const _NoUnitsCard(),
            ),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 10),
              sliver: SliverToBoxAdapter(
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'أحدث الأنشطة',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    TextButton(
                      onPressed: () =>
                          Navigator.pushNamed(context, AppRoutes.history),
                      child: const Text('عرض الكل'),
                    ),
                  ],
                ),
              ),
            ),
            if (latestActivities.isEmpty)
              const SliverFillRemaining(
                hasScrollBody: false,
                child: _EmptyActivities(),
              )
            else
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 96),
                sliver: SliverList.separated(
                  itemCount: latestActivities.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 7),
                  itemBuilder: (context, index) => _ActivityTile(
                    record: latestActivities[index],
                    onTap: () {
                      final record = latestActivities[index];
                      session.markQrRead(record.id);
                      Navigator.push(
                        context,
                        MaterialPageRoute<void>(
                          builder: (_) =>
                              QrScreen(record: record, recordOnOpen: false),
                        ),
                      );
                    },
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.ownerName, required this.onProfile});
  final String ownerName;
  final VoidCallback onProfile;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Hi',
              style: TextStyle(
                color: AppColors.muted,
                fontWeight: FontWeight.w600,
              ),
            ),
            Text(ownerName, style: Theme.of(context).textTheme.titleLarge),
          ],
        ),
      ),
      InkWell(
        key: const Key('profile_button'),
        onTap: onProfile,
        customBorder: const CircleBorder(),
        child: const CircleAvatar(
          radius: 22,
          backgroundColor: Color(0xFFE4EEF2),
          child: Icon(Icons.person_outline_rounded, color: AppColors.navy),
        ),
      ),
    ],
  );
}

class _UnitCard extends StatelessWidget {
  const _UnitCard({required this.owner, required this.history});
  final Owner owner;
  final List<QrRecord> history;

  @override
  Widget build(BuildContext context) {
    final guestTotal = history
        .where((record) => record.type == QrType.guest)
        .fold<int>(0, (total, record) => total + record.allowedPersons);
    final deliveryTotal = history
        .where((record) => record.type == QrType.delivery)
        .length;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 13),
      decoration: BoxDecoration(
        color: const Color(0xFFE2EDF2),
        borderRadius: BorderRadius.circular(17),
        boxShadow: const [
          BoxShadow(
            color: Color(0x120B2B4B),
            blurRadius: 12,
            offset: Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        children: [
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Text(
                  owner.apartment,
                  textDirection: TextDirection.ltr,
                  style: const TextStyle(
                    color: AppColors.navy,
                    fontSize: 37,
                    height: 1,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const Spacer(),
                _UnitDetail(
                  label: 'العمارة',
                  value: owner.buildingNumber.isEmpty
                      ? '—'
                      : 'B.${owner.buildingNumber}',
                ),
                const SizedBox(width: 24),
                _UnitDetail(
                  label: 'الدور',
                  value: owner.floorNumber.isEmpty
                      ? '—'
                      : 'F.${owner.floorNumber}',
                ),
              ],
            ),
          ),
          Row(
            children: [
              Expanded(
                child: _StatChip(
                  icon: Icons.groups_outlined,
                  label: 'الزوار',
                  value: guestTotal,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _StatChip(
                  icon: Icons.inventory_2_outlined,
                  label: 'التوصيل',
                  value: deliveryTotal,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _UnitDetail extends StatelessWidget {
  const _UnitDetail({required this.label, required this.value});
  final String label, value;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisAlignment: MainAxisAlignment.center,
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        label,
        style: const TextStyle(
          color: AppColors.muted,
          fontSize: 9,
          fontWeight: FontWeight.w700,
        ),
      ),
      Text(
        value,
        textDirection: TextDirection.ltr,
        style: const TextStyle(
          color: AppColors.navy,
          fontSize: 15,
          fontWeight: FontWeight.w900,
        ),
      ),
    ],
  );
}

class _StatChip extends StatelessWidget {
  const _StatChip({
    required this.icon,
    required this.label,
    required this.value,
  });
  final IconData icon;
  final String label;
  final int value;

  @override
  Widget build(BuildContext context) => Container(
    height: 39,
    padding: const EdgeInsets.symmetric(horizontal: 10),
    decoration: BoxDecoration(
      color: const Color(0xFFC9DEE1),
      borderRadius: BorderRadius.circular(11),
    ),
    child: Row(
      children: [
        Icon(icon, size: 17, color: AppColors.navy),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700),
          ),
        ),
        Text(
          '$value',
          style: const TextStyle(
            color: AppColors.navy,
            fontSize: 13,
            fontWeight: FontWeight.w900,
          ),
        ),
      ],
    ),
  );
}

class _ActivityTile extends StatelessWidget {
  const _ActivityTile({required this.record, required this.onTap});
  final QrRecord record;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final delivery = record.type == QrType.delivery;
    return Material(
      key: Key('activity_${record.id}'),
      color: record.isRead ? const Color(0xFFE5EEF2) : const Color(0xFFC6E1E4),
      borderRadius: BorderRadius.circular(15),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(15),
        child: SizedBox(
          height: 64,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                CircleAvatar(
                  radius: 20,
                  backgroundColor: delivery
                      ? const Color(0xFFF4DFC7)
                      : const Color(0xFFBCD6F5),
                  child: Icon(
                    delivery
                        ? Icons.inventory_2_outlined
                        : Icons.groups_outlined,
                    color: AppColors.navy,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        delivery
                            ? record.deliveryType == null
                                  ? 'توصيل'
                                  : 'توصيل - ${record.deliveryType}'
                            : 'زوار',
                        style: const TextStyle(
                          color: AppColors.navy,
                          fontSize: 15,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      Text(
                        _date(record.createdAt),
                        textDirection: TextDirection.ltr,
                        style: const TextStyle(fontSize: 11),
                      ),
                    ],
                  ),
                ),
                Container(
                  key: Key('usage_${record.id}'),
                  width: 22,
                  height: 22,
                  decoration: BoxDecoration(
                    color: record.isUsed ? AppColors.blue : Colors.transparent,
                    shape: BoxShape.circle,
                    border: Border.all(color: AppColors.navy, width: 1.5),
                  ),
                  child: Icon(
                    Icons.check_rounded,
                    size: 15,
                    color: record.isUsed ? Colors.white : AppColors.navy,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  static String _date(DateTime date) =>
      '${date.day.toString().padLeft(2, '0')} ${_month(date.month)} ${date.year}';

  static String _month(int month) => const [
    'يناير',
    'فبراير',
    'مارس',
    'أبريل',
    'مايو',
    'يونيو',
    'يوليو',
    'أغسطس',
    'سبتمبر',
    'أكتوبر',
    'نوفمبر',
    'ديسمبر',
  ][month - 1];
}

class _EmptyActivities extends StatelessWidget {
  const _EmptyActivities();

  @override
  Widget build(BuildContext context) => const Padding(
    padding: EdgeInsets.only(bottom: 90),
    child: Center(child: Text('لا توجد أنشطة لهذه الوحدة حتى الآن')),
  );
}

class _NoUnitsCard extends StatelessWidget {
  const _NoUnitsCard();

  @override
  Widget build(BuildContext context) => Container(
    height: 136,
    margin: const EdgeInsets.symmetric(horizontal: 20),
    padding: const EdgeInsets.symmetric(horizontal: 24),
    decoration: BoxDecoration(
      color: const Color(0xFFE2EDF2),
      borderRadius: BorderRadius.circular(17),
    ),
    child: const Row(
      children: [
        CircleAvatar(
          backgroundColor: Color(0xFFC9DEE1),
          child: Icon(Icons.apartment_rounded, color: AppColors.navy),
        ),
        SizedBox(width: 14),
        Expanded(
          child: Text(
            'لا توجد وحدات مرتبطة بحسابك حالياً. يرجى التواصل مع الإدارة.',
            style: TextStyle(fontWeight: FontWeight.w700),
          ),
        ),
      ],
    ),
  );
}
