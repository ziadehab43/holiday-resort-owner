import 'package:flutter/material.dart';

import '../../../app/routes.dart';
import '../../../app/theme.dart';
import '../../../core/widgets/app_widgets.dart';
import '../../../models/owner.dart';
import '../../../state/app_session.dart';
import '../../../services/guest_qr_backend.dart';
import '../../../services/delivery_qr_backend.dart';

class HospitalityScreen extends StatefulWidget {
  const HospitalityScreen({super.key});
  @override
  State<HospitalityScreen> createState() => _HospitalityScreenState();
}

class _HospitalityScreenState extends State<HospitalityScreen> {
  static const _deliveryTypes = [
    'مطعم',
    'صيدلية',
    'سوبر ماركت',
    'مندوب',
    'صيانة',
    'خدمات منزلية',
    'أخرى',
  ];

  int count = 1;
  String _deliveryType = _deliveryTypes.first;
  bool _isGenerating = false;
  bool _isGeneratingDelivery = false;
  String? _loadedUnitKey;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final session = AppSessionScope.of(context, listen: false);
    final owner = session.activeOwner;
    if (owner == null || _loadedUnitKey == owner.storageKey) return;
    _loadedUnitKey = owner.storageKey;
    session.loadTodayGuestQr(owner).catchError((_) => null);
  }

  Future<void> _generateGuestQr(Owner owner) async {
    if (_isGenerating) return;
    setState(() => _isGenerating = true);
    try {
      final result = await AppSessionScope.of(
        context,
        listen: false,
      ).generateGuestQr(owner, count);
      if (!mounted) return;
      if (!result.created) {
        throw const GuestQrException('تعذر إنشاء كود جديد. أعد المحاولة.');
      }
      await Navigator.pushNamed(
        context,
        AppRoutes.qr,
        arguments: result.record,
      );
    } on GuestQrException catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(error.message)));
      }
    } finally {
      if (mounted) setState(() => _isGenerating = false);
    }
  }

  Future<void> _generateDeliveryQr(Owner owner) async {
    if (_isGeneratingDelivery) return;
    setState(() => _isGeneratingDelivery = true);
    try {
      final record = await AppSessionScope.of(
        context,
        listen: false,
      ).generateDeliveryQr(owner, _deliveryType);
      if (!mounted) return;
      await Navigator.pushNamed(context, AppRoutes.qr, arguments: record);
    } on DeliveryQrException catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(error.message)));
      }
    } finally {
      if (mounted) setState(() => _isGeneratingDelivery = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = AppSessionScope.of(context);
    final owner = session.activeOwner;
    if (owner == null) {
      return Scaffold(
        appBar: const ResortAppBar('الضيافات'),
        body: const Center(
          child: Padding(
            padding: EdgeInsets.all(28),
            child: Text(
              'لا توجد وحدة مرتبطة بالحساب لإنشاء كود QR.',
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );
    }
    return Scaffold(
      appBar: const ResortAppBar('الضيافات'),
      bottomNavigationBar: BottomNav(
        selected: 0,
        onHome: () =>
            Navigator.popUntil(context, ModalRoute.withName(AppRoutes.home)),
        onReport: () => Navigator.pushNamed(context, AppRoutes.report),
        onHistory: () => Navigator.pushNamed(context, AppRoutes.history),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
          child: Column(
            children: [
              Container(
                height: 160,
                width: 230,
                decoration: BoxDecoration(
                  color: const Color(0xFFE7F5F8),
                  borderRadius: BorderRadius.circular(80),
                ),
                child: const Icon(
                  Icons.family_restroom_rounded,
                  size: 100,
                  color: AppColors.blue,
                ),
              ),
              const SizedBox(height: 20),
              ResortCard(
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: [
                    _quotaValue('الحد اليومي', session.guestAllowance.limit),
                    _quotaValue('تم استخدام', session.guestAllowance.reserved),
                    _quotaValue(
                      'المتبقي اليوم',
                      session.guestAllowance.remaining,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 18),
              Text(
                'اختر عدد أفراد الزوار',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 7),
              Text(
                session.guestAllowance.remaining == 0
                    ? 'تم الوصول للحد الأقصى للضيوف اليوم'
                    : 'يمكنك اختيار حتى ${session.guestAllowance.remaining} أفراد',
              ),
              const SizedBox(height: 22),
              Directionality(
                textDirection: TextDirection.ltr,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    _step(
                      Icons.remove,
                      count > 1 ? () => setState(() => count--) : null,
                    ),
                    Container(
                      width: 92,
                      height: 58,
                      margin: const EdgeInsets.symmetric(horizontal: 14),
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: const Color(0xFFE9EDF2)),
                      ),
                      child: Text(
                        '$count',
                        style: const TextStyle(
                          fontSize: 28,
                          fontWeight: FontWeight.w800,
                          color: AppColors.navy,
                        ),
                      ),
                    ),
                    _step(
                      Icons.add,
                      count < session.guestAllowance.remaining
                          ? () => setState(() => count++)
                          : null,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              const Text('أفراد'),
              const SizedBox(height: 32),
              PrimaryButton(
                label: _isGenerating ? 'جاري التحقق...' : 'توليد كود الضيافة',
                onPressed:
                    _isGenerating || session.guestAllowance.remaining == 0
                    ? null
                    : () {
                        if (count > session.guestAllowance.remaining) {
                          count = session.guestAllowance.remaining;
                        }
                        _generateGuestQr(owner);
                      },
              ),
              const SizedBox(height: 24),
              ResortCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        const CircleAvatar(
                          backgroundColor: Color(0xFFE7F5F8),
                          child: Icon(
                            Icons.delivery_dining_rounded,
                            color: AppColors.blue,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Text(
                          'التوصيل',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      'أنشئ كود دخول لمندوب التوصيل. يسمح كود التوصيل بدخول فرد واحد فقط.',
                    ),
                    const SizedBox(height: 14),
                    DropdownButtonFormField<String>(
                      key: const Key('delivery_type_dropdown'),
                      initialValue: _deliveryType,
                      decoration: const InputDecoration(
                        labelText: 'نوع التوصيل',
                      ),
                      items: _deliveryTypes
                          .map(
                            (type) => DropdownMenuItem(
                              value: type,
                              child: Text(type),
                            ),
                          )
                          .toList(),
                      onChanged: _isGeneratingDelivery
                          ? null
                          : (value) {
                              if (value != null) {
                                setState(() => _deliveryType = value);
                              }
                            },
                    ),
                    const SizedBox(height: 18),
                    PrimaryButton(
                      label: _isGeneratingDelivery
                          ? 'جاري الإنشاء...'
                          : 'توليد كود التوصيل',
                      icon: Icons.qr_code_rounded,
                      onPressed: _isGeneratingDelivery
                          ? null
                          : () => _generateDeliveryQr(owner),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
            ],
          ),
        ),
      ),
    );
  }

  Widget _step(IconData icon, VoidCallback? action) => SizedBox(
    width: 54,
    height: 54,
    child: FilledButton(
      onPressed: action,
      style: FilledButton.styleFrom(
        padding: EdgeInsets.zero,
        backgroundColor: AppColors.blue,
        disabledBackgroundColor: const Color(0xFFE2F2F7),
        disabledForegroundColor: AppColors.blue,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(11)),
      ),
      child: Icon(icon, size: 28),
    ),
  );

  Widget _quotaValue(String label, int value) => Column(
    children: [
      Text(label, style: const TextStyle(color: AppColors.muted, fontSize: 12)),
      const SizedBox(height: 4),
      Text(
        '$value',
        style: const TextStyle(
          fontWeight: FontWeight.w800,
          fontSize: 20,
          color: AppColors.navy,
        ),
      ),
    ],
  );
}
