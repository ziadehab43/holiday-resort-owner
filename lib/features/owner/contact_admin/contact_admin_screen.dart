import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../app/theme.dart';
import '../../../core/widgets/app_widgets.dart';

class ContactAdminScreen extends StatelessWidget {
  const ContactAdminScreen({super.key});

  Future<void> _openWhatsApp(BuildContext context) async {
    final uri = Uri.parse('https://wa.me/201234567890');
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication) &&
        context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('تعذر فتح واتساب على هذا الجهاز')),
      );
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: const ResortAppBar('تواصل مع الإدارة'),
    body: SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            Container(
              width: 190,
              height: 145,
              decoration: BoxDecoration(
                color: const Color(0xFFE9F6FA),
                borderRadius: BorderRadius.circular(70),
              ),
              child: const Icon(
                Icons.support_agent_rounded,
                size: 90,
                color: AppColors.blue,
              ),
            ),
            const SizedBox(height: 24),
            Text(
              'يمكنك التواصل مع الإدارة',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            const Text(
              'للحصول على حساب أو تفعيل حسابك، يرجى التوجه إلى مكتب الإدارة أو التواصل معنا عبر واتساب.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 25),
            const ResortCard(
              child: ListTile(
                contentPadding: EdgeInsets.zero,
                leading: CircleAvatar(
                  backgroundColor: Color(0xFFE4F4FA),
                  child: Icon(Icons.location_on, color: AppColors.blue),
                ),
                title: Text(
                  'التوجه إلى مكتب الإدارة',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                subtitle: Text('خلال ساعات العمل الرسمية'),
              ),
            ),
            const SizedBox(height: 12),
            ResortCard(
              child: ListTile(
                contentPadding: EdgeInsets.zero,
                onTap: () => _openWhatsApp(context),
                leading: CircleAvatar(
                  backgroundColor: Color(0xFFE5F9EC),
                  child: Icon(Icons.chat, color: Colors.green),
                ),
                title: Text(
                  'تواصل معنا عبر واتساب',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                subtitle: const Text('نحن هنا لمساعدتك والرد على استفساراتك'),
              ),
            ),
            const SizedBox(height: 12),
            const ResortCard(
              child: Column(
                children: [
                  Text(
                    '012 345 678 90',
                    textDirection: TextDirection.ltr,
                    style: TextStyle(
                      fontSize: 23,
                      fontWeight: FontWeight.w800,
                      color: AppColors.navy,
                    ),
                  ),
                  SizedBox(height: 4),
                  Text('اضغط على الرقم للتواصل'),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
