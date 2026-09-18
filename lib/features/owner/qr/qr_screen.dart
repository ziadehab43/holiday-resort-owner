import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';

import '../../../app/theme.dart';
import '../../../core/widgets/app_widgets.dart';
import '../../../models/owner.dart';
import '../../../services/guest_qr_backend.dart';
import '../../../state/app_session.dart';

class QrScreen extends StatefulWidget {
  const QrScreen({
    super.key,
    required this.record,
    this.recordOnOpen = true,
    this.showCreatedMessage,
  });
  final QrRecord record;
  final bool recordOnOpen;
  final bool? showCreatedMessage;
  @override
  State<QrScreen> createState() => _QrScreenState();
}

class _QrScreenState extends State<QrScreen> {
  bool _recorded = false;
  bool _cancelling = false;
  late QrRecord _record;

  @override
  void initState() {
    super.initState();
    _record = widget.record;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_recorded && widget.recordOnOpen) {
      _recorded = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          AppSessionScope.of(context, listen: false).addQrRecord(widget.record);
        }
      });
    }
  }

  bool get isDelivery => _record.type == QrType.delivery;
  bool get showCreatedMessage =>
      widget.showCreatedMessage ?? widget.recordOnOpen;

  @override
  Widget build(BuildContext context) {
    _record =
        AppSessionScope.of(context).qrRecordById(_record.id) ?? _record;
    return Scaffold(
    backgroundColor: Colors.white,
    appBar: ResortAppBar(isDelivery ? 'كود التوصيل' : 'كود الضيافة'),
    body: SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: Column(
          children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(11),
              decoration: BoxDecoration(
                color: const Color(0xFFE4F7E9),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.check_circle, color: Colors.green),
                  SizedBox(width: 8),
                  Text(
                    showCreatedMessage
                        ? 'تم إنشاء كود ${isDelivery ? 'التوصيل' : 'الضيافة'} بنجاح'
                        : 'تفاصيل كود ${isDelivery ? 'التوصيل' : 'الضيافة'}',
                    style: const TextStyle(
                      color: Color(0xFF258847),
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 10),
            ResortCard(
              child: Column(
                children: [
                  QrImageView(data: _record.qrData, size: 205),
                  const Text(
                    'صالح ليوم واحد فقط',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: AppColors.navy,
                    ),
                  ),
                  const Text('يرجى إظهار الكود عند البوابة'),
                ],
              ),
            ),
            const SizedBox(height: 12),
            ResortCard(
              child: Column(
                children: [
                  _info(
                    Icons.category_outlined,
                    'نوع الكود',
                    isDelivery
                        ? _record.deliveryType == null
                              ? 'توصيل'
                              : 'توصيل - ${_record.deliveryType}'
                        : 'ضيافة',
                  ),
                  const Divider(),
                  _info(
                    Icons.home_outlined,
                    'الوحدة',
                    _record.unitNumber?.isNotEmpty == true
                        ? _record.unitNumber!
                        : _record.unit,
                  ),
                  const Divider(),
                  _info(
                    Icons.calendar_month,
                    'التاريخ',
                    _formatDate(_record.createdAt),
                  ),
                  const Divider(),
                  _info(
                    Icons.groups_outlined,
                    'عدد الأفراد',
                    _record.allowedPersons == 1
                        ? 'فرد واحد'
                        : '${_record.allowedPersons} أفراد',
                  ),
                  const Divider(),
                  _info(
                    Icons.schedule,
                    'وقت الإنشاء',
                    TimeOfDay.fromDateTime(_record.createdAt).format(context),
                  ),
                  const Divider(),
                  _info(
                    Icons.verified_outlined,
                    'حالة الدخول',
                    switch (_record.status) {
                      QrStatus.active => 'نشط - لم يُستخدم بعد',
                      QrStatus.used => 'تم الاستخدام',
                      QrStatus.cancelled => 'تم الإلغاء',
                      QrStatus.expired => 'منتهي الصلاحية',
                    },
                  ),
                  if (_record.usedAt != null) ...[
                    const Divider(),
                    _info(
                      Icons.schedule,
                      'وقت الاستخدام',
                      TimeOfDay.fromDateTime(_record.usedAt!).format(context),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => SharePlus.instance.share(
                      ShareParams(
                        text:
                            'كود ${isDelivery ? 'توصيل' : 'ضيافة'} Holiday Resort: ${_record.qrData}',
                      ),
                    ),
                    icon: const Icon(Icons.share_outlined),
                    label: const Text('مشاركة'),
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size(0, 50),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: () => ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('تم حفظ الكود بنجاح')),
                    ),
                    icon: const Icon(Icons.download),
                    label: const Text('حفظ الكود'),
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(0, 50),
                      backgroundColor: AppColors.blue,
                    ),
                  ),
                ),
              ],
            ),
            if (!isDelivery && _record.status == QrStatus.active) ...[
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: _cancelling ? null : _cancel,
                  icon: const Icon(Icons.cancel_outlined),
                  label: Text(_cancelling ? 'جاري الإلغاء...' : 'إلغاء الكود'),
                ),
              ),
            ],
            const SizedBox(height: 20),
          ],
        ),
      ),
    ),
    );
  }

  Future<void> _cancel() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('إلغاء الكود'),
        content: const Text(
          'هل أنت متأكد من إلغاء هذا الكود؟\n'
          'بعد الإلغاء لن يمكن استخدامه للدخول.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('تراجع'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('إلغاء الكود'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _cancelling = true);
    try {
      await AppSessionScope.of(context, listen: false).cancelGuestQr(_record);
      if (!mounted) return;
      setState(() {
        _record = _record.copyWith(
          status: QrStatus.cancelled,
          cancelledAt: DateTime.now(),
        );
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('تم إلغاء الكود بنجاح واستعادة عدد الضيوف.'),
        ),
      );
    } on GuestQrException catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(error.message)));
    } finally {
      if (mounted) setState(() => _cancelling = false);
    }
  }

  String _formatDate(DateTime date) =>
      '${date.day.toString().padLeft(2, '0')}-${date.month.toString().padLeft(2, '0')}-${date.year}';

  Widget _info(IconData icon, String label, String value) => Row(
    children: [
      Icon(icon, color: AppColors.navy),
      const SizedBox(width: 10),
      Text(label),
      const Spacer(),
      Text(
        value,
        style: const TextStyle(
          fontWeight: FontWeight.w800,
          color: AppColors.navy,
        ),
      ),
    ],
  );
}
