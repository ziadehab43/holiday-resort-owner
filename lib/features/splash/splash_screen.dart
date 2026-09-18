import 'package:flutter/material.dart';

import '../../app/routes.dart';
import '../../features/owner/home/home_screen.dart';
import '../../features/owner/login/login_screen.dart';
import '../../services/owner_backend.dart';
import '../../state/app_session.dart';

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});
  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with SingleTickerProviderStateMixin {
  static const _root = 'assets/images/splash_final';
  static const _parts = '$_root/parts';
  static const _seconds = 3.55;
  late final AnimationController _controller;
  bool _started = false;

  static const _assets = <String>[
    '$_root/wordmark.png',
    '$_root/led.png',
    '$_parts/sun_center.png',
    '$_parts/ray_1.png',
    '$_parts/ray_2.png',
    '$_parts/ray_3.png',
    '$_parts/ray_4.png',
    '$_parts/ray_5.png',
    '$_parts/ray_6.png',
    '$_parts/ray_7.png',
    '$_parts/landscape.png',
  ];

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 3550),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_started) {
      _started = true;
      _play();
    }
  }

  Future<void> _play() async {
    final session = AppSessionScope.of(context, listen: false);
    final restore = _restore(session);
    final assetsReady = Future.wait<void>([
      for (final asset in _assets) precacheImage(AssetImage(asset), context),
    ]);
    bool? authenticatedResult;
    final restoreDone = restore.then<void>(
      (value) => authenticatedResult = value,
    );
    await Future.wait<void>([_controller.forward(), restoreDone, assetsReady]);
    if (!mounted) return;
    final authenticated = authenticatedResult ?? false;
    Navigator.of(context).pushReplacement(
      PageRouteBuilder<void>(
        settings: RouteSettings(
          name: authenticated ? AppRoutes.home : AppRoutes.login,
        ),
        transitionDuration: const Duration(milliseconds: 300),
        pageBuilder: (_, animation, _) => FadeTransition(
          opacity: CurvedAnimation(parent: animation, curve: Curves.easeInOut),
          child: authenticated ? const HomeScreen() : const LoginScreen(),
        ),
      ),
    );
  }

  Future<bool> _restore(AppSession session) async {
    try {
      return await session.restoreSession();
    } on OwnerBackendException {
      return false;
    }
  }

  double _phase(double begin, double end) => Curves.easeOutCubic.transform(
    ((_controller.value - begin / _seconds) / ((end - begin) / _seconds)).clamp(
      0.0,
      1.0,
    ),
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: Colors.black,
    child: SafeArea(
      child: AnimatedBuilder(
        animation: _controller,
        builder: (_, _) {
          final center = _phase(.30, .65);
          final rays = [
            for (var i = 0; i < 7; i++) _phase(.50 + i * .09, .66 + i * .09),
          ];
          final landscape = _phase(1.40, 1.90);
          final wordmark = _phase(1.75, 2.70);
          final led = _phase(2.70, 3.55);
          return Center(
            child: FractionallySizedBox(
              widthFactor: .76,
              child: RepaintBoundary(
                child: AspectRatio(
                  aspectRatio: 1 / .70,
                  child: LayoutBuilder(
                    builder: (_, constraints) {
                      final size = constraints.biggest;
                      return Stack(
                        fit: StackFit.expand,
                        clipBehavior: Clip.none,
                        children: [
                          _Layer(
                            asset: '$_root/wordmark.png',
                            rect: const Rect.fromLTWH(.30, .02, .70, .50),
                            opacity: wordmark,
                            scale: .96 + .04 * wordmark,
                            translateY: 10 * (1 - wordmark),
                            canvasSize: size,
                          ),
                          _GraphicPart(
                            asset: '$_parts/sun_center.png',
                            sourceRect: const Rect.fromLTWH(253, 278, 452, 437),
                            opacity: center,
                            scale: .90 + .10 * center,
                            canvasSize: size,
                          ),
                          for (var i = 0; i < _rayParts.length; i++)
                            _GraphicPart(
                              asset: '$_parts/${_rayParts[i].asset}.png',
                              sourceRect: _rayParts[i].rect,
                              opacity: rays[i],
                              scale: .82 + .18 * rays[i],
                              canvasSize: size,
                            ),
                          _GraphicPart(
                            asset: '$_parts/landscape.png',
                            sourceRect: const Rect.fromLTWH(0, 560, 1174, 465),
                            opacity: landscape,
                            translateY: 5 * (1 - landscape),
                            canvasSize: size,
                          ),
                          _LedReveal(progress: led, canvasSize: size),
                        ],
                      );
                    },
                  ),
                ),
              ),
            ),
          );
        },
      ),
    ),
  );
}

class _Part {
  const _Part(this.asset, this.rect);
  final String asset;
  final Rect rect;
}

const _rayParts = <_Part>[
  _Part('ray_2', Rect.fromLTWH(412, 0, 138, 272)),
  _Part('ray_3', Rect.fromLTWH(568, 103, 214, 214)),
  _Part('ray_6', Rect.fromLTWH(692, 376, 234, 130)),
  _Part('ray_1', Rect.fromLTWH(69, 581, 208, 218)),
  _Part('ray_5', Rect.fromLTWH(0, 428, 255, 129)),
  _Part('ray_7', Rect.fromLTWH(73, 264, 223, 144)),
  _Part('ray_4', Rect.fromLTWH(185, 100, 205, 213)),
];

class _GraphicPart extends StatelessWidget {
  const _GraphicPart({
    required this.asset,
    required this.sourceRect,
    required this.opacity,
    required this.canvasSize,
    this.scale = 1,
    this.translateY = 0,
  });
  final String asset;
  final Rect sourceRect;
  final double opacity, scale, translateY;
  final Size canvasSize;

  @override
  Widget build(BuildContext context) {
    const left = .02, top = .05, width = .43, height = width * 1025 / 1174;
    return _Layer(
      asset: asset,
      rect: Rect.fromLTWH(
        left + width * sourceRect.left / 1174,
        top + height * sourceRect.top / 1025,
        width * sourceRect.width / 1174,
        height * sourceRect.height / 1025,
      ),
      opacity: opacity,
      scale: scale,
      translateY: translateY,
      canvasSize: canvasSize,
    );
  }
}

class _Layer extends StatelessWidget {
  const _Layer({
    required this.asset,
    required this.rect,
    required this.opacity,
    required this.canvasSize,
    this.scale = 1,
    this.translateY = 0,
  });
  final String asset;
  final Rect rect;
  final double opacity, scale, translateY;
  final Size canvasSize;

  @override
  Widget build(BuildContext context) => Positioned(
    left: rect.left * canvasSize.width,
    top: rect.top * canvasSize.width,
    width: rect.width * canvasSize.width,
    height: rect.height * canvasSize.width,
    child: Transform.translate(
      offset: Offset(0, translateY),
      child: Transform.scale(
        scale: scale,
        child: Opacity(
          opacity: opacity,
          child: Image.asset(
            asset,
            fit: BoxFit.fill,
            gaplessPlayback: true,
            filterQuality: FilterQuality.high,
          ),
        ),
      ),
    ),
  );
}

class _LedReveal extends StatelessWidget {
  const _LedReveal({required this.progress, required this.canvasSize});
  final double progress;
  final Size canvasSize;

  @override
  Widget build(BuildContext context) {
    final rect = Rect.fromLTWH(
      canvasSize.width * .10,
      canvasSize.width * .48,
      canvasSize.width * .80,
      canvasSize.width * .80 * 220 / 814,
    );
    Widget half(bool left) => ClipRect(
      clipper: _LedHalfClipper(progress, left),
      child: Image.asset(
        'assets/images/splash_final/led.png',
        fit: BoxFit.fill,
        filterQuality: FilterQuality.high,
      ),
    );
    return Positioned.fromRect(
      rect: rect,
      child: Stack(fit: StackFit.expand, children: [half(true), half(false)]),
    );
  }
}

class _LedHalfClipper extends CustomClipper<Rect> {
  const _LedHalfClipper(this.progress, this.left);
  final double progress;
  final bool left;
  @override
  Rect getClip(Size size) {
    // Slightly overlap the two source-image clips at their meeting edge so
    // fractional physical pixels cannot leave a dark seam in the LED glow.
    final overlap = progress > 0 ? 1.0 : 0.0;
    final amount = (size.width * .5 * progress + overlap).clamp(
      0.0,
      size.width * .5 + 1,
    );
    return left
        ? Rect.fromLTWH(0, 0, amount, size.height)
        : Rect.fromLTWH(size.width - amount, 0, amount, size.height);
  }

  @override
  bool shouldReclip(_LedHalfClipper old) =>
      old.progress != progress || old.left != left;
}
