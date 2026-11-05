import 'package:flutter/material.dart';

/// Pixel-faithful tracker brand icons matching Mihon / Tachiyomi tracker logos
class TrackerLogo extends StatelessWidget {
  final String trackerId;
  final double size;

  const TrackerLogo({
    super.key,
    required this.trackerId,
    this.size = 40,
  });

  @override
  Widget build(BuildContext context) {
    switch (trackerId.toLowerCase()) {
      case 'mangabaka':
        return _buildMangaBaka();
      case 'myanimelist':
      case 'mal':
        return _buildMAL();
      case 'anilist':
        return _buildAniList();
      case 'kitsu':
        return _buildKitsu();
      case 'mangaupdates':
        return _buildMangaUpdates();
      case 'shikimori':
        return _buildShikimori();
      case 'bangumi':
        return _buildBangumi();
      case 'hikka':
        return _buildHikka();
      default:
        return _buildGeneric();
    }
  }

  Widget _buildMangaBaka() {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: const Color(0xFF1B2228),
        borderRadius: BorderRadius.circular(size * 0.22),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(size * 0.22),
        child: CustomPaint(
          size: Size(size, size),
          painter: _MangaBakaPainter(),
        ),
      ),
    );
  }

  Widget _buildMAL() {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: const Color(0xFF2E51A2),
        borderRadius: BorderRadius.circular(size * 0.22),
      ),
      alignment: Alignment.center,
      child: Text(
        'MAL',
        style: TextStyle(
          color: Colors.white,
          fontSize: size * 0.36,
          fontWeight: FontWeight.w900,
          fontFamily: 'sans-serif',
          letterSpacing: -0.5,
        ),
      ),
    );
  }

  Widget _buildAniList() {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: const Color(0xFF0B1622),
        borderRadius: BorderRadius.circular(size * 0.22),
      ),
      child: CustomPaint(
        size: Size(size, size),
        painter: _AniListPainter(),
      ),
    );
  }

  Widget _buildKitsu() {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: const Color(0xFFFD5A46),
        borderRadius: BorderRadius.circular(size * 0.22),
      ),
      child: CustomPaint(
        size: Size(size, size),
        painter: _KitsuPainter(),
      ),
    );
  }

  Widget _buildMangaUpdates() {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: const Color(0xFFDCE7F2),
        borderRadius: BorderRadius.circular(size * 0.22),
      ),
      alignment: Alignment.center,
      child: Text(
        'M',
        style: TextStyle(
          color: const Color(0xFFFF7A00),
          fontSize: size * 0.62,
          fontWeight: FontWeight.w900,
          fontFamily: 'serif',
          height: 1.0,
        ),
      ),
    );
  }

  Widget _buildShikimori() {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: const Color(0xFF222222),
        borderRadius: BorderRadius.circular(size * 0.22),
      ),
      alignment: Alignment.center,
      child: Text(
        '示',
        style: TextStyle(
          color: Colors.white,
          fontSize: size * 0.58,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }

  Widget _buildBangumi() {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: const Color(0xFFF09199),
        borderRadius: BorderRadius.circular(size * 0.22),
      ),
      child: CustomPaint(
        size: Size(size, size),
        painter: _BangumiPainter(),
      ),
    );
  }

  Widget _buildHikka() {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: const Color(0xFF14121A),
        borderRadius: BorderRadius.circular(size * 0.22),
      ),
      child: CustomPaint(
        size: Size(size, size),
        painter: _HikkaPainter(),
      ),
    );
  }

  Widget _buildGeneric() {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: const Color(0xFF333333),
        borderRadius: BorderRadius.circular(size * 0.22),
      ),
      alignment: Alignment.center,
      child: Icon(Icons.sync_rounded, color: Colors.white70, size: size * 0.6),
    );
  }
}

class _MangaBakaPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;

    // Face / skin
    final facePaint = Paint()..color = const Color(0xFFFFDEC8);
    canvas.drawCircle(Offset(w * 0.5, h * 0.52), w * 0.35, facePaint);

    // Hair base (dark teal / dark emerald)
    final hairPaint = Paint()..color = const Color(0xFF15433B);
    final hairPath = Path();
    hairPath.moveTo(w * 0.15, h * 0.5);
    hairPath.quadraticBezierTo(w * 0.15, h * 0.15, w * 0.5, h * 0.15);
    hairPath.quadraticBezierTo(w * 0.85, h * 0.15, w * 0.85, h * 0.5);
    hairPath.quadraticBezierTo(w * 0.75, h * 0.35, w * 0.5, h * 0.38);
    hairPath.quadraticBezierTo(w * 0.25, h * 0.35, w * 0.15, h * 0.5);
    canvas.drawPath(hairPath, hairPaint);

    // Buns / twin accessories
    canvas.drawCircle(Offset(w * 0.2, h * 0.25), w * 0.14, hairPaint);
    canvas.drawCircle(Offset(w * 0.8, h * 0.25), w * 0.14, hairPaint);

    // Bangs
    final bangsPath = Path();
    bangsPath.moveTo(w * 0.22, h * 0.28);
    bangsPath.lineTo(w * 0.35, h * 0.44);
    bangsPath.lineTo(w * 0.5, h * 0.38);
    bangsPath.lineTo(w * 0.65, h * 0.44);
    bangsPath.lineTo(w * 0.78, h * 0.28);
    bangsPath.close();
    canvas.drawPath(bangsPath, hairPaint);

    // Star eyes (sparkling yellow)
    _drawStar(canvas, Offset(w * 0.36, h * 0.54), w * 0.1, const Color(0xFFFFD54F));
    _drawStar(canvas, Offset(w * 0.64, h * 0.54), w * 0.1, const Color(0xFFFFD54F));

    // Little smile
    final smilePaint = Paint()
      ..color = const Color(0xFFC24A58)
      ..style = PaintingStyle.stroke
      ..strokeWidth = w * 0.04
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(
      Rect.fromCenter(center: Offset(w * 0.5, h * 0.68), width: w * 0.18, height: h * 0.12),
      0.1,
      2.9,
      false,
      smilePaint,
    );

    // Blush
    final blushPaint = Paint()..color = const Color(0x66FF8A80);
    canvas.drawOval(Rect.fromCenter(center: Offset(w * 0.26, h * 0.63), width: w * 0.12, height: h * 0.06), blushPaint);
    canvas.drawOval(Rect.fromCenter(center: Offset(w * 0.74, h * 0.63), width: w * 0.12, height: h * 0.06), blushPaint);
  }

  void _drawStar(Canvas canvas, Offset center, double radius, Color color) {
    final paint = Paint()..color = color;
    final path = Path();
    final p1 = Offset(center.dx, center.dy - radius);
    final p2 = Offset(center.dx + radius * 0.3, center.dy - radius * 0.3);
    final p3 = Offset(center.dx + radius, center.dy);
    final p4 = Offset(center.dx + radius * 0.3, center.dy + radius * 0.3);
    final p5 = Offset(center.dx, center.dy + radius);
    final p6 = Offset(center.dx - radius * 0.3, center.dy + radius * 0.3);
    final p7 = Offset(center.dx - radius, center.dy);
    final p8 = Offset(center.dx - radius * 0.3, center.dy - radius * 0.3);

    path.moveTo(p1.dx, p1.dy);
    path.lineTo(p2.dx, p2.dy);
    path.lineTo(p3.dx, p3.dy);
    path.lineTo(p4.dx, p4.dy);
    path.lineTo(p5.dx, p5.dy);
    path.lineTo(p6.dx, p6.dy);
    path.lineTo(p7.dx, p7.dy);
    path.lineTo(p8.dx, p8.dy);
    path.close();
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _AniListPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;

    // Stylized AniList "A" and cyan "L"
    final bluePaint = Paint()
      ..color = const Color(0xFF00B0FF)
      ..style = PaintingStyle.fill;
    final whitePaint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.fill;

    // Right blue bar
    final cyanBar = Path()
      ..moveTo(w * 0.58, h * 0.32)
      ..lineTo(w * 0.78, h * 0.72)
      ..lineTo(w * 0.65, h * 0.72)
      ..lineTo(w * 0.48, h * 0.38)
      ..close();
    canvas.drawPath(cyanBar, bluePaint);

    // Left white shape
    final whiteShape = Path()
      ..moveTo(w * 0.44, h * 0.28)
      ..lineTo(w * 0.22, h * 0.72)
      ..lineTo(w * 0.35, h * 0.72)
      ..lineTo(w * 0.41, h * 0.60)
      ..lineTo(w * 0.57, h * 0.60)
      ..lineTo(w * 0.53, h * 0.48)
      ..lineTo(w * 0.45, h * 0.48)
      ..close();
    canvas.drawPath(whiteShape, whitePaint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _KitsuPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;

    final paint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.fill;

    // Fox silhouette
    final path = Path();
    path.moveTo(w * 0.25, h * 0.28); // Left ear tip
    path.lineTo(w * 0.40, h * 0.45); // Left ear inner
    path.lineTo(w * 0.60, h * 0.45); // Right ear inner
    path.lineTo(w * 0.75, h * 0.28); // Right ear tip
    path.lineTo(w * 0.78, h * 0.55); // Right cheek
    path.lineTo(w * 0.50, h * 0.75); // Nose
    path.lineTo(w * 0.22, h * 0.55); // Left cheek
    path.close();

    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _BangumiPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;

    final white = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = w * 0.05
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    // Antennae
    canvas.drawLine(Offset(w * 0.38, h * 0.22), Offset(w * 0.48, h * 0.32), white);
    canvas.drawLine(Offset(w * 0.62, h * 0.22), Offset(w * 0.52, h * 0.32), white);

    // TV Box
    final tvRect = RRect.fromRectAndRadius(
      Rect.fromCenter(center: Offset(w * 0.5, h * 0.55), width: w * 0.68, height: h * 0.44),
      Radius.circular(w * 0.1),
    );
    canvas.drawRRect(tvRect, white);

    // Cute face: ≧ ▽ ≦
    // Left eye (>)
    final leftEye = Path()
      ..moveTo(w * 0.30, h * 0.50)
      ..lineTo(w * 0.38, h * 0.54)
      ..lineTo(w * 0.30, h * 0.58);
    canvas.drawPath(leftEye, white);

    // Mouth (\_/)
    final mouth = Path()
      ..moveTo(w * 0.44, h * 0.53)
      ..lineTo(w * 0.50, h * 0.60)
      ..lineTo(w * 0.56, h * 0.53);
    canvas.drawPath(mouth, white);

    // Right eye (<)
    final rightEye = Path()
      ..moveTo(w * 0.70, h * 0.50)
      ..lineTo(w * 0.62, h * 0.54)
      ..lineTo(w * 0.70, h * 0.58);
    canvas.drawPath(rightEye, white);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _HikkaPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;

    // Glowing purple "X" ribbon
    final grad = const LinearGradient(
      colors: [Color(0xFF9D4EDD), Color(0xFFC77DFF), Color(0xFFE0AAFF)],
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
    ).createShader(Rect.fromLTWH(0, 0, w, h));

    final paint = Paint()
      ..shader = grad
      ..strokeWidth = w * 0.16
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;

    canvas.drawLine(Offset(w * 0.28, h * 0.28), Offset(w * 0.72, h * 0.72), paint);
    canvas.drawLine(Offset(w * 0.72, h * 0.28), Offset(w * 0.28, h * 0.72), paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
