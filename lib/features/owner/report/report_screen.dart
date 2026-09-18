import 'package:flutter/material.dart';

import '../../../app/routes.dart';
import '../../../app/theme.dart';
import '../../../core/widgets/app_widgets.dart';
import '../../../models/report.dart';
import '../../../services/report_backend.dart';
import '../../../state/app_session.dart';

class ReportScreen extends StatefulWidget {
  const ReportScreen({super.key});

  @override
  State<ReportScreen> createState() => _ReportScreenState();
}

class _ReportScreenState extends State<ReportScreen> {
  final _formKey = GlobalKey<FormState>();
  final _descriptionController = TextEditingController();
  ReportCategory _category = ReportCategory.qr;
  bool _isSubmitting = false;

  @override
  void dispose() {
    _descriptionController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_isSubmitting || !_formKey.currentState!.validate()) return;
    final session = AppSessionScope.of(context, listen: false);
    setState(() => _isSubmitting = true);
    try {
      await session.submitReport(
        category: _category,
        message: _descriptionController.text.trim(),
      );
      if (!mounted) return;
      _descriptionController.clear();
      setState(() => _category = ReportCategory.qr);
      FocusScope.of(context).unfocus();
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('تم إرسال الطلب'),
          content: const Text(
            'تم إرسال طلبك إلى الإدارة بنجاح وسيتم مراجعته في أقرب وقت.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('حسنًا'),
            ),
          ],
        ),
      );
    } on ReportBackendException catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(error.message)));
      }
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = AppSessionScope.of(context);
    return Scaffold(
      appBar: const ResortAppBar('إرسال بلاغ'),
      bottomNavigationBar: BottomNav(
        selected: 1,
        onHome: () => Navigator.pushNamedAndRemoveUntil(
          context,
          AppRoutes.home,
          (route) => false,
        ),
        onReport: () {},
        onHistory: () =>
            Navigator.pushReplacementNamed(context, AppRoutes.history),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(
                  height: 135,
                  decoration: BoxDecoration(
                    color: const Color(0xFFE7F5F8),
                    borderRadius: BorderRadius.circular(68),
                  ),
                  child: const Icon(
                    Icons.support_agent_rounded,
                    size: 78,
                    color: AppColors.blue,
                  ),
                ),
                const SizedBox(height: 20),
                Text(
                  'كيف يمكننا مساعدتك؟',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 7),
                const Text(
                  'أرسل مشكلتك أو طلبك إلى إدارة المنتجع وسنقوم بمراجعته.',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 22),
                ResortCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _UnitSummary(unit: session.activeOwner?.unitLabel),
                      const Divider(height: 30),
                      Text(
                        'نوع البلاغ',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 10),
                      DropdownButtonFormField<ReportCategory>(
                        initialValue: _category,
                        decoration: const InputDecoration(
                          prefixIcon: Icon(Icons.category_outlined),
                        ),
                        items: ReportCategory.values
                            .map(
                              (category) => DropdownMenuItem(
                                value: category,
                                child: Text(_categoryLabel(category)),
                              ),
                            )
                            .toList(),
                        onChanged: _isSubmitting
                            ? null
                            : (value) {
                                if (value != null) {
                                  setState(() => _category = value);
                                }
                              },
                      ),
                      const SizedBox(height: 20),
                      Text(
                        'وصف المشكلة أو الطلب',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 10),
                      TextFormField(
                        controller: _descriptionController,
                        minLines: 5,
                        maxLines: 8,
                        textInputAction: TextInputAction.newline,
                        decoration: const InputDecoration(
                          hintText: 'اكتب تفاصيل المشكلة أو الطلب هنا...',
                          alignLabelWithHint: true,
                        ),
                        validator: (value) =>
                            value == null || value.trim().isEmpty
                            ? 'يرجى كتابة وصف المشكلة أو الطلب'
                            : null,
                      ),
                      const SizedBox(height: 20),
                      PrimaryButton(
                        label: _isSubmitting
                            ? 'جاري الإرسال...'
                            : 'إرسال البلاغ',
                        icon: Icons.send_rounded,
                        onPressed: _isSubmitting ? null : _submit,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  static String _categoryLabel(ReportCategory category) => switch (category) {
    ReportCategory.qr => 'مشكلة في QR',
    ReportCategory.security => 'مشكلة مع الأمن',
    ReportCategory.unitRequest => 'طلب خاص بالوحدة',
    ReportCategory.general => 'مشكلة عامة',
    ReportCategory.other => 'أخرى',
  };
}

class _UnitSummary extends StatelessWidget {
  const _UnitSummary({required this.unit});
  final String? unit;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      const CircleAvatar(
        backgroundColor: Color(0xFFE7F5F8),
        child: Icon(Icons.apartment_rounded, color: AppColors.blue),
      ),
      const SizedBox(width: 12),
      Expanded(
        child: Text(
          unit == null
              ? 'لا توجد وحدة مرتبطة بالحساب'
              : 'سيتم إرسال البلاغ عن الوحدة الحالية',
        ),
      ),
      Text(
        unit ?? '—',
        textDirection: TextDirection.ltr,
        style: const TextStyle(
          fontWeight: FontWeight.w800,
          color: AppColors.navy,
        ),
      ),
    ],
  );
}
