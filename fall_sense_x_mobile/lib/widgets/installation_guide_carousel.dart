import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

class _GuideStep {
  final String title;
  final String body;
  final Widget illustration;

  const _GuideStep({required this.title, required this.body, required this.illustration});
}

/// Step-by-step onboarding shown once after a device is first registered,
/// mirroring the Tuya "Installation Guide" carousel. Illustrations are
/// simple custom-drawn diagrams (no stock photos available for this
/// product), not literal copies of the reference screenshots.
class InstallationGuideCarousel extends StatefulWidget {
  const InstallationGuideCarousel({super.key});

  @override
  State<InstallationGuideCarousel> createState() => _InstallationGuideCarouselState();
}

class _InstallationGuideCarouselState extends State<InstallationGuideCarousel> {
  final _pageController = PageController();
  int _page = 0;

  late final List<_GuideStep> _steps = [
    _GuideStep(
      title: 'Mount at ceiling height',
      body: 'For best coverage, install the device at the center of the ceiling in the area '
          'you want to monitor.',
      illustration: _CeilingMountIllustration(),
    ),
    _GuideStep(
      title: 'Check the detection zone',
      body: 'The sensor covers a 120° cone with a range of about 6 m. Avoid pointing it '
          'through glass or at moving fans.',
      illustration: _DetectionConeIllustration(),
    ),
    _GuideStep(
      title: 'Power on and connect',
      body: 'Plug in the device and wait for the status LED to turn solid blue, then connect '
          'it to Wi-Fi from the Add Device screen.',
      illustration: _PowerIllustration(),
    ),
    _GuideStep(
      title: 'You\'re all set',
      body: 'Your device will start streaming live presence and fall-detection data to the '
          'Home dashboard.',
      illustration: _DoneIllustration(),
    ),
  ];

  void _next() {
    if (_page < _steps.length - 1) {
      _pageController.nextPage(duration: const Duration(milliseconds: 250), curve: Curves.ease);
    } else {
      Navigator.of(context).pop();
    }
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isLast = _page == _steps.length - 1;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Installation Guide'),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: PageView.builder(
                controller: _pageController,
                onPageChanged: (i) => setState(() => _page = i),
                itemCount: _steps.length,
                itemBuilder: (context, index) {
                  final step = _steps[index];
                  return Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(step.title,
                            style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
                        const SizedBox(height: 8),
                        Text(step.body, style: const TextStyle(color: AppColors.textSecondary, fontSize: 14)),
                        const SizedBox(height: 24),
                        Expanded(
                          child: Center(
                            child: SizedBox(height: 220, width: double.infinity, child: step.illustration),
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: List.generate(
                _steps.length,
                (i) => Container(
                  margin: const EdgeInsets.symmetric(horizontal: 4),
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: i == _page ? AppColors.accent : const Color(0xFFE5E5EA),
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _next,
                  child: Text(isLast ? 'Done' : 'Next Step (${_page + 1}/${_steps.length})'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CeilingMountIllustration extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.accentLight,
        borderRadius: BorderRadius.circular(16),
      ),
      child: const Center(
        child: Icon(Icons.sensors, size: 72, color: AppColors.accent),
      ),
    );
  }
}

class _DetectionConeIllustration extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _ConePainter(),
      child: Container(
        decoration: BoxDecoration(
          color: const Color(0xFFEFF6FF),
          borderRadius: BorderRadius.circular(16),
        ),
      ),
    );
  }
}

class _ConePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final apex = Offset(size.width / 2, size.height * 0.15);
    final paint = Paint()
      ..color = AppColors.statusPresence.withOpacity(0.25)
      ..style = PaintingStyle.fill;
    final path = Path()
      ..moveTo(apex.dx, apex.dy)
      ..lineTo(size.width * 0.15, size.height * 0.85)
      ..lineTo(size.width * 0.85, size.height * 0.85)
      ..close();
    canvas.drawPath(path, paint);
    canvas.drawCircle(apex, 6, Paint()..color = AppColors.statusPresence);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _PowerIllustration extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFFE8F8EE),
        borderRadius: BorderRadius.circular(16),
      ),
      child: const Center(
        child: Icon(Icons.wifi_tethering, size: 72, color: AppColors.statusOnline),
      ),
    );
  }
}

class _DoneIllustration extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.accentLight,
        borderRadius: BorderRadius.circular(16),
      ),
      child: const Center(
        child: Icon(Icons.check_circle, size: 72, color: AppColors.accent),
      ),
    );
  }
}
