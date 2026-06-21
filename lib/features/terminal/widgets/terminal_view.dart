import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  final _terminalViewKey = GlobalKey<xterm.TerminalViewState>();
  final _termController = xterm.TerminalController();
  final _scrollController = ScrollController();
  final _focusNode = FocusNode();
  bool _intentionalFocus = false;
  double _scrollAccum = 0;
  double _scrollAccumX = 0;
  Offset? _pointerDownPos;
  bool _userScrolledUp = false;
  bool _hasNewOutput = false;
  static const _scrollStep = 18.0;
  static const _tapSlop = 12.0;
  static const _historyEnterThreshold = 48.0;
  VelocityTracker? _velocityTracker;
  late final AnimationController _flingController =
      AnimationController.unbounded(vsync: this)..addListener(_onFlingTick);
  Timer? _wheelFlingTimer;
  double _wheelFlingVel = 0;
  double _wheelFlingAccum = 0;

  bool _historyMode = false;
  bool _historyReady = false;
  bool _historyLoading = false;
  bool _historyCopyPressed = false;
  bool _prefetching = false;
  xterm.Terminal? _historyTerminal;
  DateTime? _historyCapturedAt;
  DateTime? _lastPrefetchAttempt;
  Future<void>? _prefetchOp;
  final _historyScrollController = ScrollController();
  final _historyController = xterm.TerminalController();

  static const _kTermStyle = xterm.TerminalStyle(
    fontSize: 12,
    fontFamily: 'Menlo',
    fontFamilyFallback: [
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
    WidgetsBinding.instance.addPostFrameCallback((_) {
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
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _wheelFlingTimer?.cancel();
    _flingController.dispose();
    WidgetsBinding.instance.removeObserver(this);
    _focusNode.removeListener(_onFocusChange);
    widget.session.terminal.removeListener(_onTerminalChange);
    _historyScrollController.removeListener(_onHistoryScroll);
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
      _pointerDownPos = event.position;
      _scrollAccum = 0;
      _scrollAccumX = 0;
      _flingController.stop();
      _stopWheelFling();
      _velocityTracker = VelocityTracker.withKind(event.kind);
      _velocityTracker!.addPosition(event.timeStamp, event.position);
      _scrollController.jumpTo(_scrollController.offset);
    }
  }

  void _handlePointerMove(PointerMoveEvent event) {
    if (event.kind != PointerDeviceKind.touch) return;
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
      // History direction: accumulate freely until a deliberate,
      // vertical-dominant pull crosses the threshold. Upward movement is
      // reserved for history, so never emit wheel events here.
      if (_scrollAccum >= _historyEnterThreshold &&
          _scrollAccumX < _scrollAccum * 0.5) {
        _enterHistory();
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
    final newOffset = (_scrollController.offset - dy).clamp(0.0, max);
    _scrollController.jumpTo(newOffset);
    final wasUp = _userScrolledUp;
    _userScrolledUp = newOffset < max - 1.0;
    if (!_userScrolledUp) _hasNewOutput = false;
    if (wasUp != _userScrolledUp) setState(() {});
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
    final v = _flingController.value.clamp(0.0, max);
    _scrollController.jumpTo(v);
    final wasUp = _userScrolledUp;
    _userScrolledUp = v < max - 1.0;
    if (!_userScrolledUp) _hasNewOutput = false;
    if (wasUp != _userScrolledUp) setState(() {});
    if (v <= 0.0 || v >= max) _flingController.stop();
  }

  // --- History overlay (capture-pane local scroll) ---

  Future<void> _enterHistory() async {
    if (_historyMode || _historyLoading) return;
    if (widget.session.terminal.mouseMode == xterm.MouseMode.none) {
      _historySnack('历史回看仅在 tmux 会话中可用');
      return;
    }
    final capturedAt = _historyCapturedAt;
    final stale = capturedAt == null ||
        DateTime.now().difference(capturedAt).inSeconds > 5;
    if (_historyTerminal == null || stale) {
      // No snapshot yet, or the cached one is stale — capture fresh so the
      // user always sees recent history, then show the minimal loading bar
      // while the (possibly in-flight) capture finishes.
      setState(() => _historyLoading = true);
      if (!_prefetching) _prefetchHistory();
      await _prefetchOp;
      if (!mounted) return;
      setState(() => _historyLoading = false);
    }
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

  void _handlePointerUp(PointerUpEvent event) {
    if (event.kind == PointerDeviceKind.touch && _pointerDownPos != null) {
      final distance = (event.position - _pointerDownPos!).distance;
      if (distance < _tapSlop) {
        if (_historyMode) {
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
        if (v.abs() > 50) _startFling(v);
      } else if (distance >= _tapSlop &&
          !_historyMode &&
          _termController.selection == null &&
          widget.session.terminal.mouseMode != xterm.MouseMode.none) {
        final v = _velocityTracker?.getVelocity().pixelsPerSecond.dy ?? 0;
        // Down-direction only (finger flicked up); up enters history.
        if (v < -250) _startWheelFling(v);
      }
    }
    _velocityTracker = null;
    _pointerDownPos = null;
    _scrollAccum = 0;
    _scrollAccumX = 0;
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
            child: Stack(
              children: [
                ScrollConfiguration(
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
                      textStyle: _kTermStyle,
                      theme: _kTermTheme,
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
                            GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onTapDown: (_) => setState(() => _historyCopyPressed = true),
                              onTapUp: (_) => setState(() => _historyCopyPressed = false),
                              onTapCancel: () => setState(() => _historyCopyPressed = false),
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
                              child: Container(
                                width: 36,
                                height: 30,
                                alignment: Alignment.center,
                                margin: const EdgeInsets.only(right: 6),
                                decoration: BoxDecoration(
                                  color: _historyCopyPressed
                                      ? const Color(0xFF3A3A3A)
                                      : const Color(0xFF2A2A2A),
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: Icon(
                                  Icons.copy_outlined,
                                  color: _historyCopyPressed ? Colors.white : Colors.white70,
                                  size: 17,
                                ),
                              ),
                            ),
                            GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onTap: _exitHistory,
                              child: Container(
                                height: 44,
                                alignment: Alignment.center,
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 14),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 12, vertical: 6),
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(13),
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
                              textStyle: _kTermStyle,
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
                const Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: LinearProgressIndicator(
                    minHeight: 2,
                    backgroundColor: Color(0xFF1A1A1A),
                    valueColor: AlwaysStoppedAnimation<Color>(Color(0xFF5AC8FA)),
                  ),
                ),
              Positioned(
                right: 14,
                bottom: 14,
                child: IgnorePointer(
                  ignoring: !(_userScrolledUp && !_historyMode),
                  child: AnimatedScale(
                    scale: (_userScrolledUp && !_historyMode) ? 1.0 : 0.7,
                    duration: const Duration(milliseconds: 180),
                    curve: Curves.easeOut,
                    child: AnimatedOpacity(
                      opacity: (_userScrolledUp && !_historyMode) ? 1.0 : 0.0,
                      duration: const Duration(milliseconds: 180),
                      curve: Curves.easeOut,
                      child: GestureDetector(
                        onTap: () {
                          HapticFeedback.lightImpact();
                          _flingController.stop();
                          if (_scrollController.hasClients) {
                            final max =
                                _scrollController.position.maxScrollExtent;
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
                        child: Container(
                          width: 40,
                          height: 40,
                          decoration: BoxDecoration(
                            color: const Color(0xFF2A2A2A),
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: _hasNewOutput
                                  ? const Color(0xFF34C759)
                                  : const Color(0xFF5AC8FA),
                              width: 1.5,
                            ),
                            boxShadow: const [
                              BoxShadow(
                                color: Colors.black54,
                                blurRadius: 8,
                                offset: Offset(0, 2),
                              ),
                            ],
                          ),
                          child: Icon(
                            Icons.keyboard_arrow_down,
                            color: _hasNewOutput
                                ? const Color(0xFF34C759)
                                : const Color(0xFF5AC8FA),
                            size: 24,
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
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 200),
          switchInCurve: Curves.easeOut,
          switchOutCurve: Curves.easeIn,
          transitionBuilder: (child, animation) {
            return FadeTransition(
              opacity: animation,
              child: SizeTransition(
                sizeFactor: animation,
                axisAlignment: -1.0,
                child: child,
              ),
            );
          },
          child: (!_historyMode && !_focusNode.hasFocus)
              ? _InputBar(key: const ValueKey('input-bar'), onTap: _showKeyboard)
              : const SizedBox.shrink(key: ValueKey('no-input-bar')),
        ),
        if (!_historyMode)
          _ToolbarWrapper(
          session: widget.session,
          termController: _termController,
          terminalViewKey: _terminalViewKey,
          onHideKeyboard: _hideKeyboard,
          onShowHistory: _enterHistory,
        ),
      ],
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
  final VoidCallback onHideKeyboard;
  final Future<void> Function() onShowHistory;
  const _ToolbarWrapper({
    required this.session,
    required this.termController,
    required this.terminalViewKey,
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
      if (!_speechAvailable) return;
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
          final lines = <String>[];
          final scrollBack = buffer.height - terminal.viewHeight;
          for (var i = 0; i < terminal.viewHeight; i++) {
            lines.add(buffer.lines[i + scrollBack].toString().trimRight());
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
