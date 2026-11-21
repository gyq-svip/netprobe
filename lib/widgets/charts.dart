import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/models.dart';
import '../theme.dart';

/// 环形信号表
class SignalRing extends StatelessWidget {
  final int quality;
  final String centerTop;
  final String centerBottom;
  final double size;

  const SignalRing({
    super.key,
    required this.quality,
    required this.centerTop,
    required this.centerBottom,
    this.size = 132,
  });

  @override
  Widget build(BuildContext context) {
    final color = qualityColor(quality);
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          CustomPaint(
            size: Size(size, size),
            painter: _RingPainter(quality: quality, color: color),
          ),
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                centerTop,
                style: TextStyle(
                  color: color,
                  fontSize: 30,
                  fontWeight: FontWeight.w700,
                  height: 1.05,
                  letterSpacing: -0.5,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                centerBottom,
                style: const TextStyle(
                  color: AppColors.textDim,
                  fontSize: 11,
                  letterSpacing: 0.6,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  final int quality;
  final Color color;

  _RingPainter({required this.quality, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2 - 9;
    const startAngle = -math.pi * 0.75;
    const sweep = math.pi * 1.5;

    final track = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 9
      ..strokeCap = StrokeCap.round
      ..color = AppColors.border.withOpacity(0.75);

    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      startAngle,
      sweep,
      false,
      track,
    );

    if (quality > 0) {
      final progress = (quality.clamp(0, 100)) / 100.0;
      final glow = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 13
        ..strokeCap = StrokeCap.round
        ..color = color.withOpacity(0.18)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 7);

      final arc = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 9
        ..strokeCap = StrokeCap.round
        ..shader = SweepGradient(
          startAngle: startAngle,
          endAngle: startAngle + sweep,
          colors: [color.withOpacity(0.45), color],
          transform: const GradientRotation(0),
        ).createShader(Rect.fromCircle(center: center, radius: radius));

      final rect = Rect.fromCircle(center: center, radius: radius);
      canvas.drawArc(rect, startAngle, sweep * progress, false, glow);
      canvas.drawArc(rect, startAngle, sweep * progress, false, arc);
    }
  }

  @override
  bool shouldRepaint(covariant _RingPainter old) =>
      old.quality != quality || old.color != color;
}

/// 实时曲线（0-100 数值序列）
class RealtimeSpark extends StatelessWidget {
  final List<double> values;
  final Color color;
  final double height;
  final String? label;

  const RealtimeSpark({
    super.key,
    required this.values,
    this.color = AppColors.accent,
    this.height = 96,
    this.label,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      width: double.infinity,
      child: CustomPaint(
        painter: _SparkPainter(values: values, color: color, label: label),
      ),
    );
  }
}

class _SparkPainter extends CustomPainter {
  final List<double> values;
  final Color color;
  final String? label;

  _SparkPainter({required this.values, required this.color, this.label});

  @override
  void paint(Canvas canvas, Size size) {
    final gridPaint = Paint()
      ..color = AppColors.border.withOpacity(0.55)
      ..strokeWidth = 0.7;

    for (var i = 1; i < 4; i++) {
      final y = size.height * i / 4;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
    }

    if (values.length < 2) {
      final tp = TextPainter(
        text: TextSpan(
          text: '等待数据…',
          style: const TextStyle(color: AppColors.textFaint, fontSize: 11),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(size.width / 2 - tp.width / 2, size.height / 2 - tp.height / 2));
      return;
    }

    final maxPoints = math.max(values.length, 60);
    final stepX = size.width / (maxPoints - 1);
    final offset = size.width - (values.length - 1) * stepX;

    final line = Path();
    final area = Path()..moveTo(offset, size.height);

    for (var i = 0; i < values.length; i++) {
      final x = offset + i * stepX;
      final normalized = (values[i].clamp(0, 100)) / 100.0;
      final y = size.height - normalized * (size.height - 8) - 4;
      if (i == 0) {
        line.moveTo(x, y);
        area.lineTo(x, y);
      } else {
        line.lineTo(x, y);
        area.lineTo(x, y);
      }
    }

    area
      ..lineTo(offset + (values.length - 1) * stepX, size.height)
      ..close();

    canvas.drawPath(
      area,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [color.withOpacity(0.30), color.withOpacity(0.02)],
        ).createShader(Rect.fromLTWH(0, 0, size.width, size.height)),
    );

    canvas.drawPath(
      line,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.8
        ..strokeJoin = StrokeJoin.round
        ..color = color,
    );

    // 末端高亮
    final lastX = offset + (values.length - 1) * stepX;
    final lastY = size.height - (values.last.clamp(0, 100) / 100.0) * (size.height - 8) - 4;
    canvas.drawCircle(Offset(lastX, lastY), 5.5, Paint()..color = color.withOpacity(0.22));
    canvas.drawCircle(Offset(lastX, lastY), 2.6, Paint()..color = color);
  }

  @override
  bool shouldRepaint(covariant _SparkPainter old) =>
      old.values.length != values.length ||
      (values.isNotEmpty && old.values.isNotEmpty && old.values.last != values.last) ||
      old.color != color;
}

/// 信道占用图
class ChannelChart extends StatelessWidget {
  final List<WifiAp> aps;
  final String band;
  final double height;

  const ChannelChart({
    super.key,
    required this.aps,
    required this.band,
    this.height = 170,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      width: double.infinity,
      child: CustomPaint(painter: _ChannelPainter(aps: aps, band: band)),
    );
  }
}

class _ChannelPainter extends CustomPainter {
  final List<WifiAp> aps;
  final String band;

  _ChannelPainter({required this.aps, required this.band});

  static const _channels24 = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13];
  static const _channels5 = [
    36, 40, 44, 48, 52, 56, 60, 64, 100, 104, 108, 112, 116, 120, 124, 128,
    132, 136, 140, 144, 149, 153, 157, 161, 165
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final channels = band == '2.4G' ? _channels24 : _channels5;
    if (channels.isEmpty) return;

    final labelHeight = 16.0;
    final top = 6.0;
    final bottom = size.height - labelHeight;
    final usable = bottom - top;

    final minCh = channels.first.toDouble();
    final maxCh = channels.last.toDouble();
    final chartWidth = size.width;

    double xOf(num channel) {
      if (maxCh == minCh) return chartWidth / 2;
      return (channel - minCh) / (maxCh - minCh) * chartWidth;
    }

    // 基线
    canvas.drawLine(
      Offset(0, bottom),
      Offset(size.width, bottom),
      Paint()
        ..color = AppColors.border
        ..strokeWidth = 1,
    );

    // 信道刻度（按可用宽度自动稀疏，避免 5G 的 25 个标签挤在一起）
    final tickPaint = Paint()
      ..color = AppColors.border.withOpacity(0.5)
      ..strokeWidth = 0.7;

    var lastLabelRight = -1000.0;

    for (final ch in channels) {
      final x = xOf(ch);
      canvas.drawLine(Offset(x, top), Offset(x, bottom), tickPaint);

      final tp = TextPainter(
        text: TextSpan(
          text: '$ch',
          style: const TextStyle(color: AppColors.textFaint, fontSize: 9),
        ),
        textDirection: TextDirection.ltr,
      )..layout();

      if (x - tp.width / 2 > lastLabelRight + 5) {
        tp.paint(canvas, Offset(x - tp.width / 2, bottom + 3));
        lastLabelRight = x + tp.width / 2;
      }
    }

    final bandAps = aps.where((a) => a.band == band && a.channel > 0).toList()
      ..sort((a, b) => a.rssi.compareTo(b.rssi));

    for (final ap in bandAps) {
      final color = qualityColor(ap.quality);
      final channelWidth = ap.width <= 20 ? 20 : (ap.width <= 40 ? 40 : 80);
      final halfSpan = (channelWidth / 5) / 2;
      final left = xOf(ap.channel - halfSpan).clamp(0.0, size.width);
      final right = xOf(ap.channel + halfSpan).clamp(0.0, size.width);
      final center = ((left + right) / 2).clamp(0.0, size.width);

      // 即使信号很差也留一点可见高度，否则曲线会完全消失
      final ratio = ap.quality.clamp(0, 100) / 100.0;
      final peak = bottom - usable * (0.08 + ratio * 0.92);

      final path = Path()
        ..moveTo(left, bottom)
        ..quadraticBezierTo(center, peak, right, bottom)
        ..close();

      canvas.drawPath(
        path,
        Paint()..color = color.withOpacity(0.16),
      );
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.4
          ..color = color.withOpacity(0.85),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _ChannelPainter old) =>
      old.band != band || old.aps.length != aps.length || !identical(old.aps, aps);
}

/// 信号强度分格条（小尺寸，用于列表）
class SignalBars extends StatelessWidget {
  final int quality;
  final double width;

  const SignalBars(this.quality, {super.key, this.width = 26});

  @override
  Widget build(BuildContext context) {
    final color = qualityColor(quality);
    final active = (quality / 25).ceil().clamp(0, 4);
    return SizedBox(
      width: width,
      height: width * 0.72,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: List.generate(4, (i) {
          final h = (width * 0.72) * (0.28 + i * 0.24);
          return Container(
            width: width * 0.17,
            height: h,
            decoration: BoxDecoration(
              color: i < active ? color : AppColors.border,
              borderRadius: BorderRadius.circular(1.4),
            ),
          );
        }),
      ),
    );
  }
}
