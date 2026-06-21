import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:xterm/xterm.dart' as xterm;

import '../providers/terminal_provider.dart';
import '../widgets/keyboard_toolbar.dart';

void showTerminalSnack(BuildContext context, String message, {int seconds = 1}) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(message, style: const TextStyle(color: Colors.white70, fontSize: 13)),
      backgroundColor: const Color(0xFF2A2A2A),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      duration: Duration(seconds: seconds),
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      elevation: 4,
    ),
  );
}

class _NeverScrollBehavior extends ScrollBehavior {
  const _NeverScrollBehavior();

  @override
  ScrollPhysics getScrollPhysics(BuildContext context) {
    return const NeverScrollableScrollPhysics();
  }
}

class TerminalView extends StatefulWidget {
  final TerminalSession session;

  const TerminalView({super.key, required this.session});

  @override
  State<TerminalView> createState() => _TerminalViewState();
}

class _TerminalViewState extends State<TerminalView>
    with WidgetsBindingObserver, TickerProviderStateMixin {
  final _terminalViewKey = GlobalKey<xterm.TerminalViewState>();
  final _termController = xterm.TerminalController();
  final _scrollController = ScrollController();
  final _focusNode = FocusNode();
  final ValueNotifier<bool> _focused = ValueNotifier(false);
  final ValueNotifier<bool> _hasSelection = ValueNotifier(false);
  bool _intentionalFocus = false;
  double _scrollAccum = 0;
  double _scrollAccumX = 0;
  Offset? _pointerDownPos;
  bool _stoppedMomentumOnDown = false;
  bool _userScrolledUp = false;
  bool _hasNewOutput = false;
  bool _autoScrollScheduled = false;
  static const _scrollStep = 18.0;
  static const _tapSlop = 12.0;
  static const _historyEnterThreshold = 48.0;
  VelocityTracker? _velocityTracker;
  late final AnimationController _flingController =
      AnimationController.unbounded(vsync: this)..addListener(_onFlingTick);
  Timer? _wheelFlingTimer;
  double _wheelFlingVel = 0;
  double _wheelFlingAccum = 0;
  bool _flingEdgeHapticDone = false;
  final ValueNotifier<double> _overscroll = ValueNotifier(0);
  static const _kMaxOverscroll = 120.0;
  late final AnimationController _overscrollController =
      AnimationController.unbounded(vsync: this)..addListener(_onOverscrollTick);
  static final SpringDescription _kOverscrollSpring =
      SpringDescription.withDampingRatio(mass: 0.5, stiffness: 200.0, ratio: 1.0);

  bool _historyMode = false;
  bool _historyReady = false;
  bool _historyLoading = false;
  bool _prefetching = false;
  xterm.Terminal? _historyTerminal;
  DateTime? _historyCapturedAt;
  DateTime? _lastPrefetchAttempt;
  Future<void>? _prefetchOp;
  final _historyScrollController = ScrollController();
  final _historyController = xterm.TerminalController();

  double _fontSize = 12.0;
  static const _kMinFontSize = 8.0;
  static const _kMaxFontSize = 24.0;
  final Map<int, Offset> _activePointers = {};
  double? _pinchBaseDistance;
  double? _pinchBaseFontSize;
  final ValueNotifier<bool> _fontBadge = ValueNotifier(false);
  Timer? _fontBadgeTimer;

  xterm.TerminalStyle get _termStyle => xterm.TerminalStyle(
    fontSize: _fontSize,
    fontFamily: 'Menlo',
    fontFamilyFallback: const [
      'Menlo',
      'Courier New',
      'PingFang SC',
      'PingFang TC',
      'PingFang HK',
      'Heiti SC',
      'Apple Color Emoji',
      'Apple Symbols',
      'monospace',
      'sans-serif',
    ],
  );
  static final _kTermTheme = xterm.TerminalTheme(
    cursor: const Color(0xFF61AFEF),
    selection: const Color(0x4061AFEF),
    foreground: const Color(0xFFABB2BF),
    background: const Color(0xFF1A1A1A),
    black: const Color(0xFF3F4451),
    white: const Color(0xFFABB2BF),
    red: const Color(0xFFE06C75),
    green: const Color(0xFF98C379),
    yellow: const Color(0xFFE5C07B),
    blue: const Color(0xFF61AFEF),
    magenta: const Color(0xFFC678DD),
    cyan: const Color(0xFF56B6C2),
    brightBlack: const Color(0xFF5C6370),
    brightRed: const Color(0xFFE06C75),
    brightGreen: const Color(0xFF98C379),
    brightYellow: const Color(0xFFE5C07B),
    brightBlue: const Color(0xFF61AFEF),
    brightMagenta: const Color(0xFFC678DD),
    brightCyan: const Color(0xFF56B6C2),
    brightWhite: const Color(0xFFFFFFFF),
    searchHitBackground: const Color(0xFFE5C07B),
    searchHitBackgroundCurrent: const Color(0xFFE06C75),
    searchHitForeground: Colors.black,
  );

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _focusNode.addListener(_onFocusChange);
    widget.session.terminal.addListener(_onTerminalChange);
    _historyScrollController.addListener(_onHistoryScroll);
    _termController.addListener(_onSelectionChange);
    _loadFontSize();
  }

  Future<void> _loadFontSize() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getDouble('terminal_font_size');
    if (saved != null && mounted) {
      setState(() => _fontSize = saved.clamp(_kMinFontSize, _kMaxFontSize));
    }
  }

  Future<void> _saveFontSize() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('terminal_font_size', _fontSize);
  }

  void _showFontBadge() {
    _fontBadgeTimer?.cancel();
    _fontBadge.value = true;
    _fontBadgeTimer = Timer(const Duration(milliseconds: 800), () {
      _fontBadge.value = false;
    });
  }

  void _onSelectionChange() {
    _hasSelection.value = _termController.selection != null;
  }

  void _copySelection() {
    final sel = _termController.selection;
    if (sel == null) return;
    final text = widget.session.terminal.buffer.getText(sel);
    if (text.trim().isEmpty) {
      _termController.clearSelection();
      return;
    }
    Clipboard.setData(ClipboardData(text: text));
    _termController.clearSelection();
    HapticFeedback.selectionClick();
    showTerminalSnack(context, '已复制到剪贴板');
  }

  void _onHistoryScroll() {
    if (!_historyMode || !_historyScrollController.hasClients) return;
    final pos = _historyScrollController.position;
    if (pos.pixels > pos.maxScrollExtent + 36) {
      _exitHistory();
    }
  }

  void _onTerminalChange() {
    if (!_prefetching && _historyTerminal == null &&
        widget.session.terminal.mouseMode != xterm.MouseMode.none) {
      final last = _lastPrefetchAttempt;
      if (last == null || DateTime.now().difference(last).inSeconds >= 8) {
        _prefetchHistory();
      }
    }
    if (_userScrolledUp) {
      if (!_hasNewOutput) setState(() => _hasNewOutput = true);
      return;
    }
    if (_autoScrollScheduled) return;
    _autoScrollScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _autoScrollScheduled = false;
      if (!mounted || !_scrollController.hasClients) return;
      final max = _scrollController.position.maxScrollExtent;
      if (max > 0) {
        _scrollController.jumpTo(max);
      }
    });
  }

  void _onFocusChange() {
    if (!_intentionalFocus && _focusNode.hasFocus) {
      _focusNode.unfocus();
      return;
    }
    // Only the InputBar slot depends on focus — drive it through a notifier so
    // showing/hiding the keyboard doesn't rebuild the whole terminal tree mid
    // keyboard animation.
    _focused.value = _focusNode.hasFocus;
  }

  @override
  void dispose() {
    _wheelFlingTimer?.cancel();
    _fontBadgeTimer?.cancel();
    _flingController.dispose();
    _overscrollController.dispose();
    _overscroll.dispose();
    _focused.dispose();
    _fontBadge.dispose();
    WidgetsBinding.instance.removeObserver(this);
    _focusNode.removeListener(_onFocusChange);
    widget.session.terminal.removeListener(_onTerminalChange);
    _historyScrollController.removeListener(_onHistoryScroll);
    _termController.removeListener(_onSelectionChange);
    _hasSelection.dispose();
    _scrollController.dispose();
    _historyScrollController.dispose();
    _termController.dispose();
    _historyController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _focusNode.hasFocus) {
      _intentionalFocus = true;
      Future.delayed(const Duration(milliseconds: 500), () {
        if (mounted) _terminalViewKey.currentState?.requestKeyboard();
      });
    }
  }

  void _showKeyboard() {
    _intentionalFocus = true;
    _terminalViewKey.currentState?.requestKeyboard();
  }

  void _hideKeyboard() {
    _intentionalFocus = false;
    _focusNode.unfocus();
  }

  void _handlePointerDown(PointerDownEvent event) {
    if (event.kind == PointerDeviceKind.touch) {
      _activePointers[event.pointer] = event.position;
      if (_activePointers.length == 2) {
        _pinchBaseDistance = _currentPinchDistance();
        _pinchBaseFontSize = _fontSize;
      }
      _pointerDownPos = event.position;
      _scrollAccum = 0;
      _scrollAccumX = 0;
      _stoppedMomentumOnDown = _flingController.isAnimating ||
          _overscrollController.isAnimating ||
          _wheelFlingTimer != null;
      _flingController.stop();
      _stopWheelFling();
      _overscrollController.stop();
      _velocityTracker = VelocityTracker.withKind(event.kind);
      _velocityTracker!.addPosition(event.timeStamp, event.position);
      _scrollController.jumpTo(_scrollController.offset);
    }
  }

  double? _currentPinchDistance() {
    if (_activePointers.length != 2) return null;
    final pts = _activePointers.values.toList();
    return (pts[0] - pts[1]).distance;
  }

  void _handlePointerMove(PointerMoveEvent event) {
    if (event.kind != PointerDeviceKind.touch) return;
    _activePointers[event.pointer] = event.position;
    if (_activePointers.length == 2 &&
        _pinchBaseDistance != null &&
        _pinchBaseFontSize != null) {
      final dist = _currentPinchDistance();
      if (dist != null && _pinchBaseDistance! > 10) {
        final scale = dist / _pinchBaseDistance!;
        final newSize = (_pinchBaseFontSize! * scale)
            .clamp(_kMinFontSize, _kMaxFontSize)
            .roundToDouble();
        if (newSize != _fontSize) {
          HapticFeedback.selectionClick();
          setState(() => _fontSize = newSize);
          _showFontBadge();
        }
      }
      return;
    }
    if (_termController.selection != null) return;
    if (_historyLoading) return;
    if (_historyMode) return;
    _velocityTracker?.addPosition(event.timeStamp, event.position);
    if (widget.session.terminal.mouseMode == xterm.MouseMode.none) {
      _scrollNormalBuffer(event.delta.dy);
      return;
    }
    _scrollAccum += event.delta.dy;
    _scrollAccumX += event.delta.dx.abs();
    if (_scrollAccum > 0) {
      // Pull-down-to-reveal-history. The remote owns the scrollback, so the
      // live view can't scroll here — instead rubber-band it down as the user
      // pulls, so crossing into history feels physical instead of a dead 48px
      // snap. Vertical-dominant pulls only; release before the threshold
      // springs back via _handlePointerUp.
      if (_scrollAccumX < _scrollAccum * 0.5) {
        _addOverscroll(event.delta.dy);
        if (_scrollAccum >= _historyEnterThreshold) {
          HapticFeedback.mediumImpact();
          _enterHistory();
        }
      }
      return;
    }
    // Opposite direction: forward wheel notches to the remote (tmux/program).
    if (_scrollAccum.abs() < _scrollStep) return;
    final notches = (_scrollAccum.abs() / _scrollStep).floor();
    _scrollAccum = _scrollAccum.sign * (_scrollAccum.abs() % _scrollStep);
    _sendWheel(false, notches);
  }

  void _sendWheel(bool up, [int count = 1]) {
    final code = up ? 64 : 65;
    final seq = '\x1b[<$code;1;1M';
    final clamped = count.clamp(1, 5);
    final buf = StringBuffer();
    for (var i = 0; i < clamped; i++) {
      buf.write(seq);
    }
    widget.session.sendKey(buf.toString());
  }

  // Momentum for live tmux scrolling. The remote owns the scrollback, so each
  // notch is a discrete wheel event — without this, a flick stops dead on
  // finger-lift. Emit decaying wheel-down notches on an iOS-like deceleration
  // curve so a fast flick coasts through a pager. Down-only: the up direction
  // is reserved for entering the history overlay.
  void _startWheelFling(double velocityDy) {
    _stopWheelFling();
    _wheelFlingVel = velocityDy;
    _wheelFlingAccum = 0;
    _wheelFlingTimer = Timer.periodic(const Duration(milliseconds: 32), (_) {
      const dt = 0.032;
      const friction = 0.90;
      _wheelFlingVel *= friction;
      if (_wheelFlingVel.abs() < 140) {
        _stopWheelFling();
        return;
      }
      _wheelFlingAccum += _wheelFlingVel.abs() * dt;
      if (_wheelFlingAccum >= _scrollStep) {
        final notches = (_wheelFlingAccum / _scrollStep).floor().clamp(1, 4);
        _wheelFlingAccum -= notches * _scrollStep;
        _sendWheel(false, notches);
      }
    });
  }

  void _stopWheelFling() {
    _wheelFlingTimer?.cancel();
    _wheelFlingTimer = null;
    _wheelFlingVel = 0;
    _wheelFlingAccum = 0;
  }

  void _scrollNormalBuffer(double dy) {
    if (!_scrollController.hasClients) return;
    final max = _scrollController.position.maxScrollExtent;
    if (max <= 0) return;
    final raw = _scrollController.offset - dy;
    if (raw < 0) {
      if (_scrollController.offset != 0) _scrollController.jumpTo(0);
      _addOverscroll(-raw);
    } else if (raw > max) {
      if (_scrollController.offset != max) _scrollController.jumpTo(max);
      _addOverscroll(-(raw - max));
    } else {
      _scrollController.jumpTo(raw);
      if (_overscroll.value != 0) _overscroll.value = 0;
    }
    final wasUp = _userScrolledUp;
    _userScrolledUp = _scrollController.offset < max - 1.0;
    if (!_userScrolledUp) _hasNewOutput = false;
    if (wasUp != _userScrolledUp) setState(() {});
  }

  void _addOverscroll(double delta) {
    _overscrollController.stop();
    final resist =
        1.0 - (_overscroll.value.abs() / _kMaxOverscroll).clamp(0.0, 0.85);
    final prev = _overscroll.value;
    _overscroll.value = (_overscroll.value + delta * resist)
        .clamp(-_kMaxOverscroll, _kMaxOverscroll);
    if (prev.abs() < _kMaxOverscroll * 0.5 &&
        _overscroll.value.abs() >= _kMaxOverscroll * 0.5) {
      HapticFeedback.lightImpact();
    }
  }

  void _springBackOverscroll() {
    if (_overscroll.value == 0) return;
    _overscrollController.animateWith(
      SpringSimulation(_kOverscrollSpring, _overscroll.value, 0.0, 0.0),
    );
  }

  void _onOverscrollTick() {
    _overscroll.value = _overscrollController.value;
  }

  static final SpringDescription _kIosScrollSpring =
      SpringDescription.withDampingRatio(
    mass: 0.5,
    stiffness: 100.0,
    ratio: 1.1,
  );

  void _startFling(double velocity) {
    if (!_scrollController.hasClients) return;
    final max = _scrollController.position.maxScrollExtent;
    if (max <= 0) return;
    _flingEdgeHapticDone = false;
    final sim = BouncingScrollSimulation(
      position: _scrollController.offset,
      velocity: -velocity,
      leadingExtent: 0.0,
      trailingExtent: max,
      spring: _kIosScrollSpring,
    );
    _flingController.animateWith(sim);
  }

  void _onFlingTick() {
    if (!_scrollController.hasClients) {
      _flingController.stop();
      return;
    }
    final max = _scrollController.position.maxScrollExtent;
    final raw = _flingController.value;
    final clamped = raw.clamp(0.0, max);
    _scrollController.jumpTo(clamped);
    // Route the bouncing simulation's beyond-bounds travel into the visual
    // rubber-band instead of clipping it, so a fast flick bounces like iOS.
    final target =
        (-(raw - clamped)).clamp(-_kMaxOverscroll, _kMaxOverscroll);
    if (_overscroll.value != target) _overscroll.value = target;
    if (target.abs() > 0.5 && !_flingEdgeHapticDone) {
      _flingEdgeHapticDone = true;
      HapticFeedback.mediumImpact();
    }
    final wasUp = _userScrolledUp;
    _userScrolledUp = clamped < max - 1.0;
    if (!_userScrolledUp) _hasNewOutput = false;
    if (wasUp != _userScrolledUp) setState(() {});
  }

  // --- History overlay (capture-pane local scroll) ---

  Future<void> _enterHistory() async {
    if (_historyMode || _historyLoading) return;
    if (widget.session.terminal.mouseMode == xterm.MouseMode.none) {
      _historySnack('历史回看仅在 tmux 会话中可用');
      return;
    }
    if (_historyTerminal != null) {
      // Cached snapshot available — open instantly even if stale. A silent
      // background refresh will update the cache for the next entry.
      setState(() {
        _historyMode = true;
        _historyReady = false;
      });
      HapticFeedback.lightImpact();
      _scrollHistoryToBottom();
      final capturedAt = _historyCapturedAt;
      if (capturedAt == null ||
          DateTime.now().difference(capturedAt).inSeconds > 5) {
        _prefetchHistory();
      }
      return;
    }
    // Cold start — no cache at all. Show loading overlay while we capture.
    setState(() => _historyLoading = true);
    if (!_prefetching) _prefetchHistory();
    await _prefetchOp;
    if (!mounted) return;
    setState(() => _historyLoading = false);
    if (_historyTerminal == null) {
      _historySnack('暂无历史内容');
      return;
    }
    setState(() {
      _historyMode = true;
      _historyReady = false;
    });
    HapticFeedback.lightImpact();
    _scrollHistoryToBottom();
  }

  // Silent full-history capture. Runs on tmux connect and on stale exit. Builds
  // the local buffer with zero UI; only swaps it into the cache when NOT viewing
  // history, so we never replace the live overlay's terminal (the freeze bug).
  void _prefetchHistory() {
    if (_prefetching) return;
    _prefetching = true;
    _lastPrefetchAttempt = DateTime.now();
    _prefetchOp = _doPrefetch();
  }

  Future<void> _doPrefetch() async {
    try {
      final full = await _buildHistoryTerminal();
      if (full != null && !_historyMode) {
        _historyTerminal = full;
        _historyCapturedAt = DateTime.now();
      }
    } catch (_) {
    } finally {
      _prefetching = false;
    }
  }

  Future<xterm.Terminal?> _buildHistoryTerminal() async {
    final text = await widget.session.captureTmuxScrollback();
    if (!mounted || text.trim().isEmpty) return null;
    final live = widget.session.terminal;
    final ht = xterm.Terminal(maxLines: 100000);
    ht.resize(live.viewWidth, live.viewHeight);
    ht.write(text.replaceAll('\r\n', '\n').replaceAll('\n', '\r\n'));
    return ht;
  }

  void _scrollHistoryToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_historyScrollController.hasClients) return;
      _historyScrollController
          .jumpTo(_historyScrollController.position.maxScrollExtent);
      if (!_historyReady) setState(() => _historyReady = true);
    });
  }

  void _exitHistory() {
    _historyController.clearSelection();
    setState(() {
      _historyMode = false;
      _historyReady = false;
    });
    HapticFeedback.lightImpact();
    final age = _historyCapturedAt;
    if (age != null && DateTime.now().difference(age).inSeconds > 5) {
      _prefetchHistory();
    }
  }

  void _historySnack(String message) {
    if (!mounted) return;
    showTerminalSnack(context, message);
  }

  void _handlePointerCancel(PointerCancelEvent event) {
    if (event.kind != PointerDeviceKind.touch) return;
    final wasPinching = _pinchBaseDistance != null;
    _activePointers.remove(event.pointer);
    if (_activePointers.length < 2) {
      if (wasPinching) _saveFontSize();
      _pinchBaseDistance = null;
      _pinchBaseFontSize = null;
    }
    _velocityTracker = null;
    _pointerDownPos = null;
    _scrollAccum = 0;
    _scrollAccumX = 0;
  }

  void _handlePointerUp(PointerUpEvent event) {
    if (event.kind == PointerDeviceKind.touch) {
      final wasPinching = _pinchBaseDistance != null;
      _activePointers.remove(event.pointer);
      if (wasPinching) {
        _pinchBaseDistance = null;
        _pinchBaseFontSize = null;
        _velocityTracker = null;
        _pointerDownPos = null;
        _scrollAccum = 0;
        _scrollAccumX = 0;
        _saveFontSize();
        return;
      }
    }
    if (event.kind == PointerDeviceKind.touch && _pointerDownPos != null) {
      if (_overscroll.value.abs() > 0.5) {
        _springBackOverscroll();
        _velocityTracker = null;
        _pointerDownPos = null;
        _scrollAccum = 0;
        _scrollAccumX = 0;
        return;
      }
      final distance = (event.position - _pointerDownPos!).distance;
      if (distance < _tapSlop) {
        if (_stoppedMomentumOnDown) {
          // This tap only halted coasting momentum (iOS convention) — don't
          // also fire the keyboard toggle the user didn't ask for.
        } else if (_historyMode) {
          // history overlay owns its own tap/selection gestures
        } else if (_termController.selection != null) {
          _termController.clearSelection();
        } else if (_focusNode.hasFocus) {
          _hideKeyboard();
        } else {
          _showKeyboard();
        }
      } else if (distance >= _tapSlop &&
          !_historyMode &&
          _termController.selection == null &&
          widget.session.terminal.mouseMode == xterm.MouseMode.none) {
        final v = _velocityTracker?.getVelocity().pixelsPerSecond.dy ?? 0;
        if (v.abs() > 120) _startFling(v);
      } else if (distance >= _tapSlop &&
          !_historyMode &&
          _termController.selection == null &&
          widget.session.terminal.mouseMode != xterm.MouseMode.none) {
        final v = _velocityTracker?.getVelocity().pixelsPerSecond.dy ?? 0;
        // Down-direction only (finger flicked up); up enters history.
        if (v < -150) _startWheelFling(v);
      }
    }
    _velocityTracker = null;
    _pointerDownPos = null;
    _scrollAccum = 0;
    _scrollAccumX = 0;
    _springBackOverscroll();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Expanded(
          child: Listener(
            onPointerDown: _handlePointerDown,
            onPointerMove: _handlePointerMove,
            onPointerUp: _handlePointerUp,
            onPointerCancel: _handlePointerCancel,
            child: Stack(
              children: [
                ValueListenableBuilder<double>(
                  valueListenable: _overscroll,
                  builder: (context, overscroll, child) => Transform.translate(
                    offset: Offset(0, overscroll),
                    child: child,
                  ),
                  child: ScrollConfiguration(
                    behavior: const _NeverScrollBehavior(),
                    child: RawScrollbar(
                      controller: _scrollController,
                      thumbVisibility: false,
                      thumbColor: const Color(0xCC5AC8FA),
                      thickness: 5,
                      radius: const Radius.circular(2.5),
                      fadeDuration: const Duration(milliseconds: 400),
                      timeToFade: const Duration(milliseconds: 1800),
                      child: xterm.TerminalView(
                        widget.session.terminal,
                        key: _terminalViewKey,
                        controller: _termController,
                        scrollController: _scrollController,
                        focusNode: _focusNode,
                        autofocus: false,
                        deleteDetection: true,
                        keyboardType: TextInputType.text,
                        textStyle: _termStyle,
                        theme: _kTermTheme,
                      ),
                    ),
                  ),
                ),
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 200),
                transitionBuilder: (child, animation) {
                  return FadeTransition(
                    opacity: animation,
                    child: child,
                  );
                },
                child: (_historyMode && _historyTerminal != null)
                    ? SizedBox.expand(
                        key: const ValueKey('history'),
                        child: Column(
                    children: [
                      Container(
                        height: 44,
                        decoration: const BoxDecoration(
                          color: Color(0xFF1A1A1A),
                          border: Border(
                            bottom: BorderSide(
                              color: Color(0xFF3A3A3A),
                              width: 0.5,
                            ),
                          ),
                        ),
                        padding: const EdgeInsets.only(left: 14, right: 8),
                        child: Row(
                          children: [
                            const Icon(
                              Icons.history,
                              color: Colors.white70,
                              size: 18,
                            ),
                            const SizedBox(width: 7),
                            const Text(
                              '历史回看',
                              style: TextStyle(
                                color: Colors.white70,
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const Spacer(),
                            _PressableScale(
                              onTap: () {
                                final sel = _historyController.selection;
                                final text = (sel != null && _historyTerminal != null)
                                    ? _historyTerminal!.buffer.getText(sel)
                                    : '';
                                if (text.trim().isNotEmpty) {
                                  Clipboard.setData(ClipboardData(text: text));
                                  _historyController.clearSelection();
                                  HapticFeedback.selectionClick();
                                  _historySnack('已复制到剪贴板');
                                } else {
                                  _historySnack('长按选择文本后再复制');
                                }
                              },
                              builder: (pressed) => Container(
                                width: 36,
                                height: 30,
                                alignment: Alignment.center,
                                margin: const EdgeInsets.only(right: 6),
                                decoration: BoxDecoration(
                                  color: pressed
                                      ? const Color(0xFF3A3A3A)
                                      : const Color(0xFF2A2A2A),
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: Icon(
                                  Icons.copy_outlined,
                                  color: pressed ? Colors.white : Colors.white70,
                                  size: 17,
                                ),
                              ),
                            ),
                            _PressableScale(
                              onTap: _exitHistory,
                              builder: (pressed) => Container(
                                height: 44,
                                alignment: Alignment.center,
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 14),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 12, vertical: 6),
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(13),
                                    color: pressed
                                        ? const Color(0x2234C759)
                                        : null,
                                    border: Border.all(
                                      color: const Color(0xFF34C759),
                                      width: 1.0,
                                    ),
                                  ),
                                  child: const Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Text(
                                        'LIVE',
                                        style: TextStyle(
                                          color: Color(0xFF34C759),
                                          fontSize: 12,
                                          fontWeight: FontWeight.w700,
                                          letterSpacing: 0.5,
                                        ),
                                      ),
                                      SizedBox(width: 3),
                                      Icon(
                                        Icons.arrow_forward,
                                        color: Color(0xFF34C759),
                                        size: 14,
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      Expanded(
                        child: AnimatedOpacity(
                          opacity: _historyReady ? 1.0 : 0.0,
                          duration: const Duration(milliseconds: 120),
                          curve: Curves.easeOut,
                          child: RawScrollbar(
                            controller: _historyScrollController,
                            thumbVisibility: true,
                            thumbColor: const Color(0x805AC8FA),
                            thickness: 4,
                            radius: const Radius.circular(2),
                            child: xterm.TerminalView(
                              _historyTerminal!,
                              controller: _historyController,
                              scrollController: _historyScrollController,
                              readOnly: true,
                              hardwareKeyboardOnly: true,
                              textStyle: _termStyle,
                              theme: _kTermTheme,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                )
                    : const SizedBox.shrink(
                        key: ValueKey('no-history'),
                      ),
              ),
              if (_historyLoading)
                const Positioned.fill(
                  child: ColoredBox(
                    color: Color(0xFF1A1A1A),
                    child: Column(
                      children: [
                        _HistoryHeaderBar(),
                        Expanded(
                          child: Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                SizedBox(
                                  width: 22,
                                  height: 22,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    valueColor: AlwaysStoppedAnimation<Color>(
                                        Color(0xFF5AC8FA)),
                                  ),
                                ),
                                SizedBox(height: 14),
                                Text(
                                  '正在加载历史…',
                                  style: TextStyle(
                                    color: Colors.white38,
                                    fontSize: 13,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              _ScrollToBottomFab(
                visible: _userScrolledUp && !_historyMode,
                hasNewOutput: _hasNewOutput,
                onTap: () {
                  HapticFeedback.lightImpact();
                  _flingController.stop();
                  if (_scrollController.hasClients) {
                    final max = _scrollController.position.maxScrollExtent;
                    final distance = max - _scrollController.offset;
                    if (distance > 2000) {
                      _scrollController.jumpTo(max);
                    } else {
                      _scrollController.animateTo(
                        max,
                        duration: const Duration(milliseconds: 300),
                        curve: Curves.easeOutCubic,
                      );
                    }
                  }
                  setState(() {
                    _userScrolledUp = false;
                    _hasNewOutput = false;
                  });
                },
              ),
              ValueListenableBuilder<bool>(
                valueListenable: _hasSelection,
                builder: (context, hasSelection, _) {
                  if (_historyMode || !hasSelection) {
                    return const SizedBox.shrink();
                  }
                  return Positioned(
                    bottom: 14,
                    left: 0,
                    right: 0,
                    child: Center(
                      child: _PressableScale(
                        onTap: _copySelection,
                        builder: (pressed) => Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 8),
                          decoration: BoxDecoration(
                            color: pressed
                                ? const Color(0xFF3A3A3A)
                                : const Color(0xFF2A2A2A),
                            borderRadius: BorderRadius.circular(18),
                            border: Border.all(
                              color: const Color(0xFF5AC8FA),
                              width: 1.0,
                            ),
                            boxShadow: const [
                              BoxShadow(
                                color: Colors.black54,
                                blurRadius: 8,
                                offset: Offset(0, 2),
                              ),
                            ],
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.copy_outlined,
                                color: pressed
                                    ? Colors.white
                                    : const Color(0xFF5AC8FA),
                                size: 16,
                              ),
                              const SizedBox(width: 6),
                              Text(
                                '复制',
                                style: TextStyle(
                                  color: pressed
                                      ? Colors.white
                                      : const Color(0xFF5AC8FA),
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
              ValueListenableBuilder<bool>(
                valueListenable: _fontBadge,
                builder: (context, show, _) => Positioned.fill(
                  child: IgnorePointer(
                    child: Center(
                      child: AnimatedOpacity(
                        opacity: show ? 1.0 : 0.0,
                        duration: const Duration(milliseconds: 140),
                        curve: Curves.easeOut,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 18, vertical: 10),
                          decoration: BoxDecoration(
                            color: const Color(0xE61A1A1A),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: const Color(0xFF5AC8FA),
                              width: 1.0,
                            ),
                          ),
                          child: Text(
                            '${_fontSize.toInt()} px',
                            style: const TextStyle(
                              color: Color(0xFF5AC8FA),
                              fontSize: 18,
                              fontWeight: FontWeight.w700,
                              fontFamily: 'Menlo',
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
            ),
          ),
        ),
        ValueListenableBuilder<bool>(
          valueListenable: _focused,
          builder: (context, focused, _) {
            final showBar = !_historyMode && !focused;
            return AnimatedSwitcher(
              duration: const Duration(milliseconds: 200),
              switchInCurve: Curves.easeOut,
              switchOutCurve: Curves.easeIn,
              transitionBuilder: (child, animation) {
                return FadeTransition(
                  opacity: animation,
                  child: SizeTransition(
                    sizeFactor: animation,
                    alignment: Alignment.topCenter,
                    child: child,
                  ),
                );
              },
              child: showBar
                  ? _InputBar(key: const ValueKey('input-bar'), onTap: _showKeyboard)
                  : const SizedBox.shrink(key: ValueKey('no-input-bar')),
            );
          },
        ),
        Offstage(
          offstage: _historyMode,
          child: _ToolbarWrapper(
            session: widget.session,
            termController: _termController,
            terminalViewKey: _terminalViewKey,
            scrollController: _scrollController,
            onHideKeyboard: _hideKeyboard,
            onShowHistory: _enterHistory,
          ),
        ),
      ],
    );
  }
}

class _HistoryHeaderBar extends StatelessWidget {
  const _HistoryHeaderBar();

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 44,
      decoration: const BoxDecoration(
        color: Color(0xFF1A1A1A),
        border: Border(
          bottom: BorderSide(color: Color(0xFF3A3A3A), width: 0.5),
        ),
      ),
      padding: const EdgeInsets.only(left: 14),
      child: const Row(
        children: [
          Icon(Icons.history, color: Colors.white70, size: 18),
          SizedBox(width: 7),
          Text(
            '历史回看',
            style: TextStyle(
              color: Colors.white70,
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _PressableScale extends StatefulWidget {
  final VoidCallback onTap;
  final Widget Function(bool pressed) builder;

  const _PressableScale({required this.onTap, required this.builder});

  @override
  State<_PressableScale> createState() => _PressableScaleState();
}

class _PressableScaleState extends State<_PressableScale> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) => setState(() => _pressed = false),
      onTapCancel: () => setState(() => _pressed = false),
      onTap: () {
        HapticFeedback.selectionClick();
        widget.onTap();
      },
      child: AnimatedScale(
        scale: _pressed ? 0.92 : 1.0,
        duration: const Duration(milliseconds: 90),
        curve: Curves.easeOut,
        child: widget.builder(_pressed),
      ),
    );
  }
}

class _ScrollToBottomFab extends StatefulWidget {
  final bool visible;
  final bool hasNewOutput;
  final VoidCallback onTap;

  const _ScrollToBottomFab({
    required this.visible,
    required this.hasNewOutput,
    required this.onTap,
  });

  @override
  State<_ScrollToBottomFab> createState() => _ScrollToBottomFabState();
}

class _ScrollToBottomFabState extends State<_ScrollToBottomFab>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  );

  bool get _shouldPulse => widget.visible && widget.hasNewOutput;

  @override
  void initState() {
    super.initState();
    if (_shouldPulse) _pulse.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(covariant _ScrollToBottomFab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_shouldPulse && !_pulse.isAnimating) {
      _pulse.repeat(reverse: true);
    } else if (!_shouldPulse && _pulse.isAnimating) {
      _pulse.stop();
      _pulse.value = 0;
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final accent = widget.hasNewOutput
        ? const Color(0xFF34C759)
        : const Color(0xFF5AC8FA);
    return Positioned(
      right: 14,
      bottom: 14,
      child: IgnorePointer(
        ignoring: !widget.visible,
        child: AnimatedScale(
          scale: widget.visible ? 1.0 : 0.7,
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
          child: AnimatedOpacity(
            opacity: widget.visible ? 1.0 : 0.0,
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOut,
            child: GestureDetector(
              onTap: widget.onTap,
              child: AnimatedBuilder(
                animation: _pulse,
                builder: (context, _) {
                  final glow = widget.hasNewOutput
                      ? Curves.easeInOut.transform(_pulse.value)
                      : 0.0;
                  return Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: const Color(0xFF2A2A2A),
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: accent,
                        width: 1.5 + glow,
                      ),
                      boxShadow: [
                        const BoxShadow(
                          color: Colors.black54,
                          blurRadius: 8,
                          offset: Offset(0, 2),
                        ),
                        if (widget.hasNewOutput)
                          BoxShadow(
                            color: accent.withValues(alpha: 0.55 * glow),
                            blurRadius: 8 + glow * 12,
                            spreadRadius: glow * 2.5,
                          ),
                      ],
                    ),
                    child: Icon(
                      Icons.keyboard_arrow_down,
                      color: accent,
                      size: 24,
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _InputBar extends StatefulWidget {
  final VoidCallback onTap;

  const _InputBar({super.key, required this.onTap});

  @override
  State<_InputBar> createState() => _InputBarState();
}

class _InputBarState extends State<_InputBar>
    with SingleTickerProviderStateMixin {
  bool _pressed = false;
  late final AnimationController _cursorBlink = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 800),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _cursorBlink.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) => setState(() => _pressed = false),
      onTapCancel: () => setState(() => _pressed = false),
      onTap: () {
        HapticFeedback.selectionClick();
        widget.onTap();
      },
      child: Container(
        height: 44,
        decoration: BoxDecoration(
          color: _pressed ? const Color(0xFF2A2A2A) : const Color(0xFF1A1A1A),
          border: const Border(
            top: BorderSide(color: Color(0xFF2A2A2A), width: 0.5),
          ),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 14),
        child: Row(
          children: [
            FadeTransition(
              opacity: _cursorBlink,
              child: const Text(
                '▏',
                style: TextStyle(
                  color: Color(0xFF5AC8FA),
                  fontSize: 16,
                  height: 1.0,
                ),
              ),
            ),
            const SizedBox(width: 8),
            const Text(
              '点按输入命令',
              style: TextStyle(
                color: Colors.white38,
                fontSize: 13,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ToolbarWrapper extends StatefulWidget {
  final TerminalSession session;
  final xterm.TerminalController termController;
  final GlobalKey<xterm.TerminalViewState> terminalViewKey;
  final ScrollController scrollController;
  final VoidCallback onHideKeyboard;
  final Future<void> Function() onShowHistory;
  const _ToolbarWrapper({
    required this.session,
    required this.termController,
    required this.terminalViewKey,
    required this.scrollController,
    required this.onHideKeyboard,
    required this.onShowHistory,
  });

  @override
  State<_ToolbarWrapper> createState() => _ToolbarWrapperState();
}

class _ToolbarWrapperState extends State<_ToolbarWrapper> {
  static const _clipboardChannel = MethodChannel('com.clawmate.clipboard');
  final _speech = stt.SpeechToText();
  bool _isListening = false;
  bool _speechAvailable = false;

  void _showSnack(String message, {int seconds = 1}) {
    if (!mounted) return;
    showTerminalSnack(context, message, seconds: seconds);
  }

  Future<void> _pasteImage() async {
    Map<dynamic, dynamic>? result;
    try {
      result = await _clipboardChannel
          .invokeMapMethod<dynamic, dynamic>('getImageBase64');
    } catch (_) {
      result = null;
    }
    if (!mounted) return;
    if (result == null) {
      _showSnack('剪贴板没有图片');
      return;
    }
    final format = (result['format'] as String?) ?? 'png';
    final data = result['data'] as String?;
    if (data == null || data.isEmpty) return;

    final lines = StringBuffer();
    for (var i = 0; i < data.length; i += 76) {
      final end = (i + 76 < data.length) ? i + 76 : data.length;
      lines.writeln(data.substring(i, end));
    }

    final ext = format == 'jpg' ? 'jpg' : 'png';
    final marker = 'CLAW_EOF_${DateTime.now().microsecondsSinceEpoch}';
    final cmd =
        '_CLAW=\$(mktemp /tmp/clawmate_XXXXXX.$ext) && base64 -d > "\$_CLAW" << \'$marker\'\n'
        '${lines.toString()}'
        '$marker\n'
        'echo "image saved: \$_CLAW"\n';

    widget.session.sendKey(cmd);

    final kb = (data.length * 3 / 4 / 1024).toStringAsFixed(1);
    _showSnack('已上传图片 (${kb}KB)', seconds: 2);
  }

  @override
  void initState() {
    super.initState();
    _initSpeech();
  }

  Future<void> _initSpeech() async {
    _speechAvailable = await _speech.initialize();
  }

  Future<void> _toggleVoice() async {
    if (_isListening) {
      await _speech.stop();
      setState(() => _isListening = false);
      return;
    }
    if (!_speechAvailable) {
      _speechAvailable = await _speech.initialize();
      if (!_speechAvailable) {
        _showSnack('语音输入不可用，请检查麦克风权限');
        return;
      }
    }
    setState(() => _isListening = true);
    await _speech.listen(
      onResult: (result) {
        if (result.finalResult && result.recognizedWords.isNotEmpty) {
          widget.session.sendKey(result.recognizedWords);
          setState(() => _isListening = false);
        }
      },
      listenOptions: stt.SpeechListenOptions(
        localeId: 'zh_CN',
        listenMode: stt.ListenMode.dictation,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: widget.session.ctrlNotifier,
      builder: (context, ctrlActive, _) {
        return KeyboardToolbar(
          ctrlActive: ctrlActive,
          isListening: _isListening,
          onVoiceToggle: _toggleVoice,
          onCtrlToggle: widget.session.toggleCtrl,
          onCopyTerminal: () {
        final terminal = widget.session.terminal;
        final selection = widget.termController.selection;
        String text;
        if (selection != null) {
          text = terminal.buffer.getText(selection);
          widget.termController.clearSelection();
        } else {
          final buffer = terminal.buffer;
          final viewH = terminal.viewHeight;
          final totalLines = buffer.height;
          final maxTop = (totalLines - viewH).clamp(0, totalLines);
          // Copy what's actually on screen. When the user has scrolled up, the
          // viewport no longer sits at the bottom of the buffer, so derive the
          // top visible line from the scroll offset. Cell height comes from the
          // scroll metrics themselves (maxScrollExtent over scrollable rows) so
          // we don't hard-code any font-internal line height.
          var topLine = maxTop;
          final sc = widget.scrollController;
          if (sc.hasClients && maxTop > 0) {
            final max = sc.position.maxScrollExtent;
            if (max > 0) {
              final cellH = max / maxTop;
              if (cellH > 0) topLine = (sc.offset / cellH).round().clamp(0, maxTop);
            }
          }
          final lines = <String>[];
          for (var i = 0; i < viewH; i++) {
            final idx = topLine + i;
            if (idx >= 0 && idx < totalLines) {
              lines.add(buffer.lines[idx].toString().trimRight());
            }
          }
          text = lines.join('\n').trimRight();
        }
        if (text.isNotEmpty) {
          Clipboard.setData(ClipboardData(text: text));
          _showSnack('已复制到剪贴板');
        }
      },
      onKeyTap: (key) {
        widget.session.sendKey(key);
      },
      onHideKeyboard: widget.onHideKeyboard,
      onShowHistory: widget.onShowHistory,
      onPaste: () async {
        final data = await Clipboard.getData(Clipboard.kTextPlain);
        if (!mounted) return;
        if (data?.text != null && data!.text!.isNotEmpty) {
          widget.session.terminal.paste(data.text!);
        } else {
          _showSnack('剪贴板为空');
        }
      },
      onPasteImage: _pasteImage,
        );
      },
    );
  }
}
