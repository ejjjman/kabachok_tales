import 'dart:async';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

void main() {
  runApp(const KabachokTalesApp());
}

const Color canvasBackgroundColor = Color(0xff050507);

class KabachokTalesApp extends StatelessWidget {
  const KabachokTalesApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: DrawingPage(),
    );
  }
}

enum Tool { marker, airbrush, pen, lasso }

class Stroke {
  List<Offset> points;
  List<double> pressures;
  Color color;
  double baseWidth;
  double opacity;
  Tool tool;
  bool isErasing;

  Stroke({
    required this.points,
    required this.pressures,
    required this.color,
    required this.baseWidth,
    required this.opacity,
    required this.tool,
    required this.isErasing,
  });
}

class DrawingPage extends StatefulWidget {
  const DrawingPage({super.key});

  @override
  State<DrawingPage> createState() => _DrawingPageState();
}

class _DrawingPageState extends State<DrawingPage> {
  // ------ логи мазков ------
  final List<Stroke> history = []; // запечённые мазки
  final List<Stroke> undoHistory = []; // для undo/redo
  final List<Stroke> activeStrokes = []; // то, что рисуется сейчас (ты + боты)

  ui.Image? bakedImage; // запечённый холст

  // ------ текущий инструмент ------
  Color currentColor = Colors.white;
  double currentWidth = 8;
  double currentOpacity = 1.0;
  Tool currentTool = Tool.marker;
  bool eraseMode = false;

  // пользовательский активный мазок
  Stroke? userActiveStroke;
  int? activePointerId; // один активный палец/стилус

  // размер холста
  Size canvasSize = const Size(1920, 1080);

  // ------ HSV палитра ------
  double _hue = 0.0;
  double _sat = 0.0;
  double _val = 1.0;
  final List<Color?> _swatches = List<Color?>.filled(10, null);

  // ------ Боты ------
  final int botCount = 10;
  final Random rng = Random();
  late List<Offset?> botPositions;
  late List<bool> botDrawing;
  late List<Stroke?> botActiveStrokes;
  bool stressMode = false;
  Timer? botTimer;

  // ------ FPS ------
  double _fps = 0.0;
  double _frameMs = 0.0;

  // ограничение истории
  static const int maxHistoryStrokes = 450;

  // ------ UI состояния (Вариант A) ------
  bool chatOpen = false;
  bool micMuted = true;

  // Заглушки под комнату и участников
  String roomId = "0001";
  final List<String> participants = ["Лёша", "Ева", "Василиса"];

  // Мини-всплывашка входящего сообщения
  String? lastIncomingMessage;
  Timer? _toastTimer;

  @override
  void initState() {
    super.initState();

    _setHsvFromColor(currentColor);

    botPositions = List.generate(botCount, (_) => null);
    botDrawing = List.generate(botCount, (_) => false);
    botActiveStrokes = List.generate(botCount, (_) => null);

    // таймер ботов
    botTimer = Timer.periodic(const Duration(milliseconds: 16), (_) {
      if (!mounted || !stressMode || canvasSize == Size.zero) return;

      setState(() {
        for (int i = 0; i < botCount; i++) {
          if (!botDrawing[i]) {
            if (rng.nextDouble() < 0.02) {
              _botBeginStroke(i);
            }
          } else {
            if (rng.nextDouble() < 0.03) {
              _botEndStroke(i);
            } else {
              _botContinueStroke(i);
            }
          }
        }
      });
    });

    // FPS
    WidgetsBinding.instance.addTimingsCallback((timings) {
      for (final t in timings) {
        final dt = t.totalSpan.inMicroseconds / 1000.0;
        _frameMs = _frameMs == 0 ? dt : _frameMs * 0.9 + dt * 0.1;
        _fps = _frameMs == 0 ? 0 : 1000.0 / _frameMs;
      }
      if (mounted) setState(() {});
    });

    // демонстрация: "входящее сообщение" раз в 14 сек (потом заменим на реальный чат)
    Timer.periodic(const Duration(seconds: 14), (_) {
      if (!mounted) return;
      _showIncomingMessage("Привет! Я здесь 🙂");
    });
  }

  @override
  void dispose() {
    botTimer?.cancel();
    bakedImage?.dispose();
    _toastTimer?.cancel();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // PALITRA HSV
  // ---------------------------------------------------------------------------

  void _setHsvFromColor(Color c) {
    final hsv = HSVColor.fromColor(c);
    _hue = hsv.hue;
    _sat = hsv.saturation;
    _val = hsv.value;
  }

  void _updateColorFromHsv() {
    final c = HSVColor.fromAHSV(1.0, _hue, _sat, _val).toColor();
    setState(() => currentColor = c);
  }

  void _handleSvChange(Offset pos, double size) {
    double x = pos.dx.clamp(0.0, size);
    double y = pos.dy.clamp(0.0, size);
    _sat = x / size;
    _val = 1.0 - y / size;
    _updateColorFromHsv();
  }

  void _handleHueChange(double dx, double width) {
    double x = dx.clamp(0.0, width);
    _hue = (x / width) * 360.0;
    _updateColorFromHsv();
  }

  // ---------------------------------------------------------------------------
  // БОТЫ
  // ---------------------------------------------------------------------------

  void _botBeginStroke(int index) {
    botDrawing[index] = true;

    final start = Offset(
      rng.nextDouble() * canvasSize.width,
      rng.nextDouble() * canvasSize.height,
    );
    botPositions[index] = start;

    final roll = rng.nextDouble();
    Tool tool;
    if (roll < 0.4) {
      tool = Tool.marker;
    } else if (roll < 0.7) {
      tool = Tool.airbrush;
    } else {
      tool = Tool.pen;
    }

    final erasing = rng.nextBool() && rng.nextBool();

    final hue = rng.nextDouble() * 360;
    final sat = 0.4 + rng.nextDouble() * 0.6;
    final val = 0.6 + rng.nextDouble() * 0.4;
    final color = HSVColor.fromAHSV(1.0, hue, sat, val).toColor();

    final width = tool == Tool.pen ? (2 + rng.nextDouble() * 4) : (4 + rng.nextDouble() * 20);
    final op = erasing ? 1.0 : (0.3 + rng.nextDouble() * 0.7);

    final stroke = Stroke(
      points: [start],
      pressures: [1.0],
      color: erasing ? Colors.transparent : color,
      baseWidth: width,
      opacity: op,
      tool: tool,
      isErasing: erasing,
    );

    activeStrokes.add(stroke);
    botActiveStrokes[index] = stroke;
  }

  void _botContinueStroke(int index) {
    final stroke = botActiveStrokes[index];
    if (stroke == null) return;
    final last = stroke.points.last;

    final dx = (rng.nextDouble() - 0.5) * 40;
    final dy = (rng.nextDouble() - 0.5) * 40;

    final next = Offset(
      (last.dx + dx).clamp(0.0, canvasSize.width),
      (last.dy + dy).clamp(0.0, canvasSize.height),
    );

    botPositions[index] = next;
    stroke.points.add(next);
    stroke.pressures.add(1.0);
  }

  void _botEndStroke(int index) {
    final stroke = botActiveStrokes[index];
    if (stroke == null) return;

    botDrawing[index] = false;
    botPositions[index] = null;
    botActiveStrokes[index] = null;

    activeStrokes.remove(stroke);
    _addStrokeToHistory(stroke);
  }

  void _toggleStress() {
    setState(() => stressMode = !stressMode);
  }

  // ---------------------------------------------------------------------------
  // РИСОВАНИЕ ПОЛЬЗОВАТЕЛЯ
  // ---------------------------------------------------------------------------

  void _pointerDown(PointerDownEvent e) {
    final local = e.localPosition;
    if (!_insideCanvas(local, canvasSize)) return;

    if (activePointerId != null) return; // один палец/стилус
    activePointerId = e.pointer;

    undoHistory.clear();

    final bool isErasing = eraseMode;

    double baseWidth;
    if (currentTool == Tool.pen) {
      baseWidth = currentWidth.clamp(1.0, 8.0);
    } else {
      baseWidth = currentWidth.clamp(2.0, 40.0);
    }

    final stroke = Stroke(
      points: [local],
      pressures: [e.pressure == 0 ? 1.0 : e.pressure],
      color: isErasing ? Colors.transparent : currentColor,
      baseWidth: baseWidth,
      opacity: isErasing ? 1.0 : currentOpacity,
      tool: currentTool,
      isErasing: isErasing,
    );

    setState(() {
      activeStrokes.add(stroke);
      userActiveStroke = stroke;
    });
  }

  void _pointerMove(PointerMoveEvent e) {
    if (activePointerId == null || e.pointer != activePointerId) return;
    if (userActiveStroke == null) return;

    final local = e.localPosition;
    if (!_insideCanvas(local, canvasSize)) return;

    final pressure = e.pressure == 0 ? 1.0 : e.pressure;

    setState(() {
      userActiveStroke!.points.add(local);
      userActiveStroke!.pressures.add(pressure);
    });
  }

  void _pointerUp(PointerUpEvent e) {
    if (activePointerId == null || e.pointer != activePointerId) return;
    activePointerId = null;

    if (userActiveStroke == null) return;

    final stroke = userActiveStroke!;
    userActiveStroke = null;

    setState(() {
      activeStrokes.remove(stroke);
    });

    _addStrokeToHistory(stroke);
  }

  bool _insideCanvas(Offset p, Size size) {
    return p.dx >= 0 && p.dy >= 0 && p.dx <= size.width && p.dy <= size.height;
  }

  // ---------------------------------------------------------------------------
  // HISTORY + BAKING
  // ---------------------------------------------------------------------------

  void _addStrokeToHistory(Stroke s) {
    history.add(s);
    if (history.length > maxHistoryStrokes) {
      history.removeAt(0);
    }
    _rebuildBakedImage();
  }

  Future<void> _rebuildBakedImage() async {
    if (canvasSize.isEmpty) return;

    final recorder = ui.PictureRecorder();
    final Canvas c = Canvas(recorder);

    c.drawRect(
      Offset.zero & canvasSize,
      Paint()..color = canvasBackgroundColor,
    );

    for (final s in history) {
      StrokeRenderer.drawStroke(c, s);
    }

    final picture = recorder.endRecording();
    final img = await picture.toImage(
      canvasSize.width.toInt(),
      canvasSize.height.toInt(),
    );

    if (!mounted) return;

    setState(() {
      bakedImage?.dispose();
      bakedImage = img;
    });
  }

  // ---------------------------------------------------------------------------
  // UNDO / REDO / CLEAR
  // ---------------------------------------------------------------------------

  void _undo() {
    if (history.isEmpty) return;
    final last = history.removeLast();
    undoHistory.add(last);
    _rebuildBakedImage();
  }

  void _redo() {
    if (undoHistory.isEmpty) return;
    final s = undoHistory.removeLast();
    history.add(s);
    _rebuildBakedImage();
  }

  void _clear() {
    history.clear();
    undoHistory.clear();
    activeStrokes.clear();
    userActiveStroke = null;
    activePointerId = null;

    for (int i = 0; i < botCount; i++) {
      botDrawing[i] = false;
      botPositions[i] = null;
      botActiveStrokes[i] = null;
    }

    bakedImage?.dispose();
    bakedImage = null;

    setState(() {});
  }

  // ---------------------------------------------------------------------------
  // ЧАТ: поведение "сообщение рядом с кружком"
  // ---------------------------------------------------------------------------

  void _showIncomingMessage(String text) {
    setState(() => lastIncomingMessage = text);
    _toastTimer?.cancel();
    _toastTimer = Timer(const Duration(seconds: 4), () {
      if (mounted) setState(() => lastIncomingMessage = null);
    });
  }

  // ---------------------------------------------------------------------------
  // UI (Вариант A)
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final participantsLine = participants.join(", ");

    return Scaffold(
      backgroundColor: canvasBackgroundColor,
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            canvasSize = Size(constraints.maxWidth, constraints.maxHeight);

            return Stack(
              children: [
                // FULLSCREEN CANVAS
                Positioned.fill(
                  child: ClipRect(
                    child: Listener(
                      onPointerDown: _pointerDown,
                      onPointerMove: _pointerMove,
                      onPointerUp: _pointerUp,
                      child: CustomPaint(
                        painter: DrawingPainter(
                          bakedImage: bakedImage,
                          activeStrokes: activeStrokes,
                        ),
                        size: Size.infinite,
                      ),
                    ),
                  ),
                ),

                // TOP: room + participants
                Positioned(
                  left: 14,
                  right: 14,
                  top: 10,
                  child: _GlassBar(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          "Комната: $roomId",
                          style: const TextStyle(color: Colors.white70, fontSize: 12),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          participantsLine,
                          style: const TextStyle(color: Colors.white, fontSize: 12),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                ),

                // TOP: sliders
                Positioned(
                  left: 14,
                  right: 14,
                  top: 68,
                  child: _GlassBar(
                    child: Column(
                      children: [
                        _MinimalSlider(
                          label: "Размер",
                          value: currentWidth,
                          min: 2,
                          max: 24,
                          onChanged: (v) => setState(() => currentWidth = v),
                        ),
                        const SizedBox(height: 10),
                        _MinimalSlider(
                          label: "Прозрачность",
                          value: currentOpacity,
                          min: 0.1,
                          max: 1.0,
                          onChanged: (v) => setState(() => currentOpacity = v),
                        ),
                      ],
                    ),
                  ),
                ),

                // LEFT TOP: компактная палитра (hue + sv)
                Positioned(
                  left: 14,
                  top: 152,
                  child: _GlassBar(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            _GlassCircle(
                              size: 38,
                              child: Container(
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: currentColor,
                                  border: Border.all(color: Colors.white24),
                                ),
                              ),
                            ),
                            const SizedBox(width: 10),
                            const Text(
                              "Цвет",
                              style: TextStyle(color: Colors.white70, fontSize: 12),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),

                        // SV квадрат
                        GestureDetector(
                          onPanDown: (d) => _handleSvChange(d.localPosition, 120),
                          onPanUpdate: (d) => _handleSvChange(d.localPosition, 120),
                          child: SizedBox(
                            width: 120,
                            height: 120,
                            child: CustomPaint(
                              painter: _SvPainter(_hue),
                            ),
                          ),
                        ),

                        const SizedBox(height: 10),

                        // Hue полоса
                        SizedBox(
                          width: 120,
                          height: 16,
                          child: LayoutBuilder(
                            builder: (context, c) {
                              final w = c.maxWidth;
                              return GestureDetector(
                                onPanDown: (d) => _handleHueChange(d.localPosition.dx, w),
                                onPanUpdate: (d) => _handleHueChange(d.localPosition.dx, w),
                                child: CustomPaint(
                                  painter: _HuePainter(),
                                  size: Size(w, 16),
                                ),
                              );
                            },
                          ),
                        ),

                        const SizedBox(height: 10),

                        // 10 квадратиков
                        Row(
                          children: List.generate(10, (i) {
                            final c = _swatches[i] ?? Colors.white24;
                            return Padding(
                              padding: const EdgeInsets.only(right: 4),
                              child: GestureDetector(
                                onTap: () {
                                  if (_swatches[i] != null) {
                                    final col = _swatches[i]!;
                                    _setHsvFromColor(col);
                                    setState(() => currentColor = col);
                                  }
                                },
                                onLongPress: () => setState(() => _swatches[i] = currentColor),
                                child: Container(
                                  width: 10,
                                  height: 10,
                                  decoration: BoxDecoration(
                                    color: c,
                                    borderRadius: BorderRadius.circular(3),
                                    border: Border.all(color: Colors.white24),
                                  ),
                                ),
                              ),
                            );
                          }),
                        ),
                      ],
                    ),
                  ),
                ),

                // BOTTOM LEFT: инструменты
                Positioned(
                  left: 14,
                  bottom: 14,
                  child: _GlassBar(
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _ToolIcon(
                          icon: Icons.brush,
                          selected: currentTool == Tool.marker && !eraseMode,
                          onTap: () => setState(() {
                            currentTool = Tool.marker;
                            eraseMode = false;
                          }),
                        ),
                        const SizedBox(width: 10),
                        _ToolIcon(
                          icon: Icons.blur_on,
                          selected: currentTool == Tool.airbrush && !eraseMode,
                          onTap: () => setState(() {
                            currentTool = Tool.airbrush;
                            eraseMode = false;
                          }),
                        ),
                        const SizedBox(width: 10),
                        _ToolIcon(
                          icon: Icons.edit,
                          selected: currentTool == Tool.pen && !eraseMode,
                          onTap: () => setState(() {
                            currentTool = Tool.pen;
                            eraseMode = false;
                          }),
                        ),
                        const SizedBox(width: 10),
                        _ToolIcon(
                          icon: Icons.select_all,
                          selected: currentTool == Tool.lasso && !eraseMode,
                          onTap: () => setState(() {
                            currentTool = Tool.lasso;
                            eraseMode = false;
                          }),
                        ),
                        const SizedBox(width: 14),
                        _ToolIcon(
                          icon: Icons.cleaning_services,
                          selected: eraseMode,
                          onTap: () => setState(() => eraseMode = !eraseMode),
                        ),
                        const SizedBox(width: 14),
                        _ToolIcon(icon: Icons.undo, selected: false, onTap: _undo),
                        const SizedBox(width: 10),
                        _ToolIcon(icon: Icons.redo, selected: false, onTap: _redo),
                        const SizedBox(width: 10),
                        _ToolIcon(icon: Icons.delete_outline, selected: false, onTap: _clear),
                        const SizedBox(width: 14),
                        _ToolIcon(
                          icon: stressMode ? Icons.warning_amber : Icons.flash_on,
                          selected: stressMode,
                          onTap: _toggleStress,
                        ),
                      ],
                    ),
                  ),
                ),

                // BOTTOM RIGHT: mic + chat + logo
                Positioned(
                  right: 14,
                  bottom: 14,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (!chatOpen && lastIncomingMessage != null) ...[
                        _GlassBar(
                          child: Text(
                            lastIncomingMessage!,
                            style: const TextStyle(color: Colors.white, fontSize: 12),
                          ),
                        ),
                        const SizedBox(width: 10),
                      ],

                      _GlassCircle(
                        size: 48,
                        child: IconButton(
                          onPressed: () => setState(() => micMuted = !micMuted),
                          icon: Icon(
                            micMuted ? Icons.mic_off : Icons.mic,
                            color: Colors.white,
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),

                      _GlassCircle(
                        size: 48,
                        child: IconButton(
                          onPressed: () => setState(() => chatOpen = !chatOpen),
                          icon: Icon(
                            chatOpen ? Icons.chat_bubble : Icons.chat_bubble_outline,
                            color: Colors.white,
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),

                      _GlassCircle(
                        size: 48,
                        child: InkWell(
                          onTap: () {
                            showModalBottomSheet(
                              context: context,
                              backgroundColor: Colors.transparent,
                              builder: (_) => _GlassModal(
                                child: Padding(
                                  padding: const EdgeInsets.all(16),
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      const Text(
                                        "Профиль",
                                        style: TextStyle(color: Colors.white, fontSize: 16),
                                      ),
                                      const SizedBox(height: 8),
                                      Text(
                                        "Комната: $roomId",
                                        style: const TextStyle(color: Colors.white70),
                                      ),
                                      const SizedBox(height: 8),
                                      const Text(
                                        "Участник: Лёша",
                                        style: TextStyle(color: Colors.white70),
                                      ),
                                      const SizedBox(height: 14),
                                      SizedBox(
                                        width: double.infinity,
                                        child: ElevatedButton(
                                          style: ElevatedButton.styleFrom(
                                            backgroundColor: Colors.white.withOpacity(0.18),
                                            elevation: 0,
                                            shape: RoundedRectangleBorder(
                                              borderRadius: BorderRadius.circular(14),
                                              side: BorderSide(color: Colors.white.withOpacity(0.18)),
                                            ),
                                          ),
                                          onPressed: () {},
                                          child: const Text(
                                            "Записаться на другой курс",
                                            style: TextStyle(color: Colors.white),
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            );
                          },
                          child: Padding(
                            padding: const EdgeInsets.all(9),
                            child: Image.asset(
                              "assets/kabachok_logo.png",
                              fit: BoxFit.contain,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),

                // CHAT PANEL
                if (chatOpen)
                  Positioned(
                    top: 0,
                    right: 0,
                    bottom: 0,
                    width: 280,
                    child: ClipRRect(
                      borderRadius: const BorderRadius.only(
                        topLeft: Radius.circular(18),
                        bottomLeft: Radius.circular(18),
                      ),
                      child: BackdropFilter(
                        filter: ui.ImageFilter.blur(sigmaX: 18, sigmaY: 18),
                        child: Container(
                          decoration: BoxDecoration(
                            color: Colors.black.withOpacity(0.35),
                            border: Border(
                              left: BorderSide(color: Colors.white.withOpacity(0.12)),
                            ),
                          ),
                          padding: const EdgeInsets.all(14),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                "Чат",
                                style: TextStyle(color: Colors.white, fontSize: 14),
                              ),
                              const SizedBox(height: 10),
                              Expanded(
                                child: ListView(
                                  children: const [
                                    Text("Ева: Привет!", style: TextStyle(color: Colors.white70)),
                                    SizedBox(height: 8),
                                    Text("Лёша: Я рисую 🙂", style: TextStyle(color: Colors.white70)),
                                  ],
                                ),
                              ),
                              const SizedBox(height: 10),
                              const _ChatInput(),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),

                // маленький FPS индикатор
                Positioned(
                  right: 14,
                  top: 10,
                  child: _GlassBar(
                    child: Text(
                      "FPS ${_fps.toStringAsFixed(0)}",
                      style: const TextStyle(color: Colors.white70, fontSize: 12),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// StrokeRenderer – рисует один Stroke (маркер, аэрограф, перо, лассо)
// -----------------------------------------------------------------------------
class StrokeRenderer {
  static void drawStroke(Canvas canvas, Stroke s) {
    if (s.points.length < 2) return;

    // Лассо-заливка
    if (s.tool == Tool.lasso) {
      final path = Path()..moveTo(s.points[0].dx, s.points[0].dy);
      for (int i = 1; i < s.points.length; i++) {
        path.lineTo(s.points[i].dx, s.points[i].dy);
      }
      path.close();

      final paint = Paint()
        ..isAntiAlias = true
        ..style = PaintingStyle.fill
        ..blendMode = BlendMode.srcOver
        ..color = s.isErasing ? canvasBackgroundColor : s.color.withOpacity(s.opacity);

      canvas.drawPath(path, paint);
      return;
    }

    // Перо: лента (ribbon), без кругов
    if (s.tool == Tool.pen) {
      _drawPenRibbon(canvas, s);
      return;
    }

    // Маркер / аэрограф
    final paint = Paint()
      ..isAntiAlias = true
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..strokeWidth = s.baseWidth
      ..blendMode = BlendMode.srcOver
      ..color = s.isErasing ? canvasBackgroundColor : s.color.withOpacity(s.opacity);

    if (s.tool == Tool.airbrush) {
      paint.maskFilter = ui.MaskFilter.blur(ui.BlurStyle.normal, s.baseWidth * 0.7);
    }

    final path = Path()..moveTo(s.points[0].dx, s.points[0].dy);
    for (int i = 1; i < s.points.length; i++) {
      path.lineTo(s.points[i].dx, s.points[i].dy);
    }
    canvas.drawPath(path, paint);
  }

  static void _drawPenRibbon(Canvas canvas, Stroke s) {
    final pts = s.points;
    final prs = s.pressures;
    final int n = pts.length;
    if (n < 2) return;

    final List<Offset> smoothPts = [];
    final List<double> smoothPrs = [];

    if (n == 2) {
      smoothPts.addAll(pts);
      smoothPrs.addAll(prs.length == 2 ? prs : [1.0, 1.0]);
    } else {
      smoothPts.add(pts[0]);
      smoothPrs.add(prs.isNotEmpty ? prs[0] : 1.0);

      for (int i = 1; i < n - 1; i++) {
        final p0 = pts[i];
        final p1 = pts[i + 1];
        final mid = Offset((p0.dx + p1.dx) / 2, (p0.dy + p1.dy) / 2);

        final pr0 = prs.length > i ? prs[i] : 1.0;
        final pr1 = prs.length > i + 1 ? prs[i + 1] : pr0;
        final midPr = (pr0 + pr1) / 2;

        smoothPts.add(p0);
        smoothPrs.add(pr0);

        smoothPts.add(mid);
        smoothPrs.add(midPr);
      }

      smoothPts.add(pts.last);
      smoothPrs.add(prs.isNotEmpty ? prs.last : 1.0);
    }

    final int m = smoothPts.length;
    if (m < 2) return;

    final double base = s.baseWidth.clamp(1.0, 8.0);

    final List<Offset> left = List.filled(m, Offset.zero);
    final List<Offset> right = List.filled(m, Offset.zero);

    for (int i = 0; i < m; i++) {
      final p = smoothPts[i];

      Offset t;
      if (i == 0) {
        t = smoothPts[1] - p;
      } else if (i == m - 1) {
        t = p - smoothPts[m - 2];
      } else {
        t = smoothPts[i + 1] - smoothPts[i - 1];
      }
      if (t.distance == 0) t = const Offset(1, 0);
      t = t / t.distance;

      final nrm = Offset(-t.dy, t.dx);

      final double tt = m == 1 ? 0.0 : i / (m - 1);
      const double edge = 0.18;
      double taper = 1.0;
      if (tt < edge) {
        taper = (tt / edge).clamp(0.15, 1.0);
      } else if (tt > 1.0 - edge) {
        taper = ((1.0 - tt) / edge).clamp(0.15, 1.0);
      }

      double pr = smoothPrs.length > i ? smoothPrs[i] : 1.0;
      pr = pr.clamp(0.3, 1.5);

      double width = base * (0.6 + 0.9 * pr) * taper;
      width = width.clamp(0.5, base * 1.8);
      final halfW = width / 2;

      left[i] = p + nrm * halfW;
      right[i] = p - nrm * halfW;
    }

    final path = Path()..moveTo(left[0].dx, left[0].dy);
    for (int i = 1; i < m; i++) {
      path.lineTo(left[i].dx, left[i].dy);
    }
    for (int i = m - 1; i >= 0; i--) {
      path.lineTo(right[i].dx, right[i].dy);
    }
    path.close();

    final paint = Paint()
      ..isAntiAlias = true
      ..style = PaintingStyle.fill
      ..blendMode = BlendMode.srcOver
      ..color = s.isErasing ? canvasBackgroundColor : s.color.withOpacity(s.opacity);

    canvas.drawPath(path, paint);
  }
}

// -----------------------------------------------------------------------------
// PAINTER холста
// -----------------------------------------------------------------------------
class DrawingPainter extends CustomPainter {
  final ui.Image? bakedImage;
  final List<Stroke> activeStrokes;

  const DrawingPainter({
    required this.bakedImage,
    required this.activeStrokes,
  });

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = canvasBackgroundColor,
    );

    if (bakedImage != null) {
      canvas.drawImage(bakedImage!, Offset.zero, Paint());
    }

    for (final s in activeStrokes) {
      StrokeRenderer.drawStroke(canvas, s);
    }
  }

  @override
  bool shouldRepaint(covariant DrawingPainter oldDelegate) =>
      oldDelegate.bakedImage != bakedImage || oldDelegate.activeStrokes != activeStrokes;
}

// -----------------------------------------------------------------------------
// painters палитры
// -----------------------------------------------------------------------------
class _SvPainter extends CustomPainter {
  final double hue;
  _SvPainter(this.hue);

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final baseColor = HSVColor.fromAHSV(1.0, hue, 1.0, 1.0).toColor();

    final grad1 = LinearGradient(
      begin: Alignment.centerLeft,
      end: Alignment.centerRight,
      colors: [Colors.white, baseColor],
    );
    final p1 = Paint()..shader = grad1.createShader(rect);
    canvas.drawRect(rect, p1);

    final grad2 = const LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: [Colors.transparent, Colors.black],
    );
    final p2 = Paint()
      ..shader = grad2.createShader(rect)
      ..blendMode = BlendMode.multiply;
    canvas.drawRect(rect, p2);
  }

  @override
  bool shouldRepaint(_SvPainter oldDelegate) => oldDelegate.hue != hue;
}

class _HuePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final List<Color> colors = [];
    for (int i = 0; i <= 6; i++) {
      final h = i * 60.0;
      colors.add(HSVColor.fromAHSV(1.0, h, 1.0, 1.0).toColor());
    }
    final grad = LinearGradient(
      begin: Alignment.centerLeft,
      end: Alignment.centerRight,
      colors: colors,
    );
    final paint = Paint()..shader = grad.createShader(rect);
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, const Radius.circular(8)),
      paint,
    );
  }

  @override
  bool shouldRepaint(_HuePainter oldDelegate) => false;
}

// -----------------------------------------------------------------------------
// Glass UI components
// -----------------------------------------------------------------------------
class _GlassBar extends StatelessWidget {
  final Widget child;
  const _GlassBar({required this.child});

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(18),
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 18, sigmaY: 18),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.08),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: Colors.white.withOpacity(0.12)),
          ),
          child: child,
        ),
      ),
    );
  }
}

class _GlassCircle extends StatelessWidget {
  final double size;
  final Widget child;
  const _GlassCircle({required this.size, required this.child});

  @override
  Widget build(BuildContext context) {
    return ClipOval(
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 18, sigmaY: 18),
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.08),
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white.withOpacity(0.12)),
          ),
          child: Center(child: child),
        ),
      ),
    );
  }
}

class _GlassModal extends StatelessWidget {
  final Widget child;
  const _GlassModal({required this.child});

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(22),
          child: BackdropFilter(
            filter: ui.ImageFilter.blur(sigmaX: 20, sigmaY: 20),
            child: Container(
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.35),
                border: Border.all(color: Colors.white.withOpacity(0.12)),
                borderRadius: BorderRadius.circular(22),
              ),
              child: child,
            ),
          ),
        ),
      ),
    );
  }
}

class _MinimalSlider extends StatelessWidget {
  final String label;
  final double value;
  final double min;
  final double max;
  final ValueChanged<double> onChanged;

  const _MinimalSlider({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(
          width: 98,
          child: Text(
            label,
            style: const TextStyle(color: Colors.white70, fontSize: 12),
          ),
        ),
        Expanded(
          child: SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 2,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 10),
              activeTrackColor: Colors.white.withOpacity(0.8),
              inactiveTrackColor: Colors.white.withOpacity(0.18),
              thumbColor: Colors.white.withOpacity(0.9),
            ),
            child: Slider(
              value: value.clamp(min, max),
              min: min,
              max: max,
              onChanged: onChanged,
            ),
          ),
        ),
      ],
    );
  }
}

class _ToolIcon extends StatelessWidget {
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  const _ToolIcon({
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Icon(
        icon,
        size: 18,
        color: selected ? Colors.white : Colors.white70,
      ),
    );
  }
}

class _ChatInput extends StatefulWidget {
  const _ChatInput();

  @override
  State<_ChatInput> createState() => _ChatInputState();
}

class _ChatInputState extends State<_ChatInput> {
  final controller = TextEditingController();

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.08),
          border: Border.all(color: Colors.white.withOpacity(0.12)),
          borderRadius: BorderRadius.circular(14),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: controller,
                style: const TextStyle(color: Colors.white),
                decoration: const InputDecoration(
                  isDense: true,
                  border: InputBorder.none,
                  hintText: "Написать…",
                  hintStyle: TextStyle(color: Colors.white54),
                ),
                onSubmitted: (_) => controller.clear(),
              ),
            ),
            IconButton(
              onPressed: () => controller.clear(),
              icon: const Icon(Icons.send, color: Colors.white70, size: 18),
            ),
          ],
        ),
      ),
    );
  }
}
