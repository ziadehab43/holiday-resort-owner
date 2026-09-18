import 'package:flutter/material.dart';

import '../../../app/routes.dart';
import '../../../app/theme.dart';
import '../../../core/widgets/app_widgets.dart';
import '../../../models/owner.dart';
import '../../../models/report.dart';
import '../../../services/guest_qr_backend.dart';
import '../../../services/history_backend.dart';
import '../../../state/app_session.dart';
import '../qr/qr_screen.dart';

class HospitalityHistoryScreen extends StatefulWidget {
  const HospitalityHistoryScreen({super.key});
  @override
  State<HospitalityHistoryScreen> createState() =>
      _HospitalityHistoryScreenState();
}

class _HospitalityHistoryScreenState extends State<HospitalityHistoryScreen> {
  bool _loading = true, _started = false;
  String? _error;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_started) {
      _started = true;
      AppSessionScope.of(context, listen: false).watchActiveUnitData();
      _load();
    }
  }

  Future<void> _load() async {
    if (mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      await AppSessionScope.of(context, listen: false).loadActiveUnitHistory();
    } on HistoryException catch (e) {
      _error = e.message;
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = AppSessionScope.of(context);
    final activities = <_Activity>[
      ...session.ownerHistory.map(_Activity.qr),
      ...session.reports.map(_Activity.report),
    ]..sort((a, b) => b.date.compareTo(a.date));
    return Scaffold(
      appBar: const ResortAppBar('السجل'),
      bottomNavigationBar: BottomNav(
        selected: 2,
        onHome: () => Navigator.pushNamedAndRemoveUntil(
          context,
          AppRoutes.home,
          (r) => false,
        ),
        onReport: () =>
            Navigator.pushReplacementNamed(context, AppRoutes.report),
        onHistory: () {},
      ),
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _error != null
            ? _HistoryError(message: _error!, onRetry: _load)
            : activities.isEmpty
            ? const _EmptyHistory()
            : RefreshIndicator(
                onRefresh: _load,
                child: ListView.separated(
                  padding: const EdgeInsets.all(24),
                  itemCount: activities.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 12),
                  itemBuilder: (_, i) {
                    final report = activities[i].reportValue;
                    return report != null
                        ? _ReportTile(report: report)
                        : _QrTile(
                            record: activities[i].qrValue!,
                            session: session,
                          );
                  },
                ),
              ),
      ),
    );
  }
}

class _Activity {
  const _Activity.qr(this.qrValue) : reportValue = null;
  const _Activity.report(this.reportValue) : qrValue = null;
  final QrRecord? qrValue;
  final OwnerReport? reportValue;
  DateTime get date => qrValue?.createdAt ?? reportValue!.createdAt;
}

class _QrTile extends StatelessWidget {
  const _QrTile({required this.record, required this.session});
  final QrRecord record;
  final AppSession session;
  @override
  Widget build(BuildContext context) {
    final delivery = record.type == QrType.delivery;
    return Material(
      color: record.isRead ? Colors.white : const Color(0xFFC6E1E4),
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        key: Key('history_${record.id}'),
        borderRadius: BorderRadius.circular(18),
        onTap: () async {
          session.markQrRead(record.id);
          await Navigator.push(
            context,
            MaterialPageRoute<void>(
              builder: (_) => QrScreen(record: record, recordOnOpen: false),
            ),
          );
        },
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Row(
            children: [
              Icon(
                delivery
                    ? Icons.delivery_dining_rounded
                    : Icons.groups_outlined,
                size: 30,
                color: AppColors.navy,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      delivery
                          ? 'توصيل${record.deliveryType == null ? '' : ' - ${record.deliveryType}'}'
                          : 'ضيافة',
                      style: const TextStyle(
                        fontWeight: FontWeight.w800,
                        color: AppColors.navy,
                      ),
                    ),
                    Text(
                      'الوحدة ${record.unitNumber?.isNotEmpty == true ? record.unitNumber : record.unit}',
                    ),
                    Text(
                      record.allowedPersons == 1
                          ? 'فرد واحد'
                          : '${record.allowedPersons} أفراد',
                    ),
                    Text(
                      _qrStatus(record.status),
                      style: TextStyle(
                        color: _statusColor(record.status),
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
              _DateBlock(record.createdAt),
            ],
          ),
        ),
      ),
    );
  }
}

class _ReportTile extends StatelessWidget {
  const _ReportTile({required this.report});
  final OwnerReport report;
  @override
  Widget build(BuildContext context) => Material(
    color: Colors.white,
    borderRadius: BorderRadius.circular(18),
    child: InkWell(
      key: Key('report_${report.id}'),
      borderRadius: BorderRadius.circular(18),
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute<void>(
          builder: (_) => _ReportDetails(reportId: report.id),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Row(
          children: [
            const Icon(Icons.report_outlined, size: 30, color: AppColors.navy),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'بلاغ - ${_category(report.category)}',
                    style: const TextStyle(
                      fontWeight: FontWeight.w800,
                      color: AppColors.navy,
                    ),
                  ),
                  Text(
                    report.message,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text('الوحدة ${report.unitNumber}'),
                  Text(
                    report.status.arabicLabel,
                    style: TextStyle(
                      color: _reportColor(report.status),
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
            ),
            _DateBlock(report.createdAt),
          ],
        ),
      ),
    ),
  );
}

class _ReportDetails extends StatelessWidget {
  const _ReportDetails({required this.reportId});
  final String reportId;
  @override
  Widget build(BuildContext context) {
    final report = AppSessionScope.of(context).reports
        .where((item) => item.id == reportId)
        .firstOrNull;
    if (report == null) {
      return const Scaffold(
        appBar: ResortAppBar('تفاصيل البلاغ'),
        body: Center(child: Text('تعذر تحميل تفاصيل البلاغ.')),
      );
    }
    return Scaffold(
      appBar: const ResortAppBar('تفاصيل البلاغ'),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ResortCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _detail('نوع البلاغ', _category(report.category)),
                _detail('الوحدة', report.unitNumber),
                _detail('الوصف', report.message),
                _detail('تاريخ الإرسال', _dateTime(report.createdAt)),
                _detail('الحالة', report.status.arabicLabel),
                _detail(
                  'رد الإدارة',
                  report.adminResponse?.isNotEmpty == true
                      ? report.adminResponse!
                      : 'لم يتم إضافة رد من الإدارة حتى الآن',
                ),
                _detail(
                  'آخر تحديث',
                  report.updatedAt == null
                      ? 'لا يوجد تحديث حتى الآن'
                      : _dateTime(report.updatedAt!),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _detail(String label, String value) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(color: AppColors.muted)),
        const SizedBox(height: 5),
        Text(
          value,
          style: const TextStyle(
            fontWeight: FontWeight.w700,
            color: AppColors.navy,
          ),
        ),
      ],
    ),
  );
}

class _DateBlock extends StatelessWidget {
  const _DateBlock(this.value);
  final DateTime value;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.end,
    children: [
      Text(
        _date(value),
        textDirection: TextDirection.ltr,
        style: const TextStyle(
          fontWeight: FontWeight.w800,
          color: AppColors.navy,
        ),
      ),
      const SizedBox(height: 4),
      Text(_time(value), textDirection: TextDirection.ltr),
    ],
  );
}

String _category(ReportCategory value) => switch (value) {
  ReportCategory.qr => 'مشكلة في QR',
  ReportCategory.security => 'الأمن',
  ReportCategory.unitRequest => 'طلب خاص بالوحدة',
  ReportCategory.general => 'عام',
  ReportCategory.other => 'أخرى',
};
String _qrStatus(QrStatus value) => switch (value) {
  QrStatus.active => 'نشط',
  QrStatus.used => 'تم الاستخدام',
  QrStatus.cancelled => 'ملغي',
  QrStatus.expired => 'منتهي الصلاحية',
};
Color _statusColor(QrStatus value) => switch (value) {
  QrStatus.active => AppColors.blue,
  QrStatus.used => Colors.green,
  QrStatus.cancelled => Colors.red,
  QrStatus.expired => AppColors.muted,
};
Color _reportColor(ReportStatus value) => switch (value) {
  ReportStatus.pending => AppColors.blue,
  ReportStatus.inProgress => Colors.orange,
  ReportStatus.resolved => Colors.green,
  ReportStatus.rejected => Colors.red,
};
String _date(DateTime value) {
  final v = FirebaseGuestQrBackend.egyptTime(value);
  return '${v.day.toString().padLeft(2, '0')}-${v.month.toString().padLeft(2, '0')}-${v.year}';
}

String _time(DateTime value) {
  final v = FirebaseGuestQrBackend.egyptTime(value);
  final h = v.hour % 12 == 0 ? 12 : v.hour % 12;
  return '${h.toString().padLeft(2, '0')}:${v.minute.toString().padLeft(2, '0')} ${v.hour >= 12 ? 'PM' : 'AM'}';
}

String _dateTime(DateTime value) => '${_date(value)} - ${_time(value)}';

class _HistoryError extends StatelessWidget {
  const _HistoryError({required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;
  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(message, textAlign: TextAlign.center),
          const SizedBox(height: 14),
          FilledButton(onPressed: onRetry, child: const Text('إعادة المحاولة')),
        ],
      ),
    ),
  );
}

class _EmptyHistory extends StatelessWidget {
  const _EmptyHistory();
  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 104,
            height: 104,
            decoration: const BoxDecoration(
              color: Color(0xFFE7F5F8),
              shape: BoxShape.circle,
            ),
            child: const Icon(
              Icons.history_rounded,
              size: 58,
              color: AppColors.blue,
            ),
          ),
          const SizedBox(height: 20),
          Text(
            'لا توجد أنشطة حتى الآن',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 7),
          const Text('ستظهر أكواد الضيافة والتوصيل والبلاغات هنا'),
        ],
      ),
    ),
  );
}
