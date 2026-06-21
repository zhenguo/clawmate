import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:xterm/xterm.dart' as xterm;

import '../providers/terminal_provider.dart';
import '../widgets/keyboard_toolbar.dart';

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
  Offset? _pointerDownPos;
  bool _userScrolledUp = false;
  static const _scrollStep = 18.0;
  static const _tapSlop = 12.0;
  bool _wheelInFlight = false;
  Timer? _wheelTimeout;
  VelocityTracker? _velocityTracker;
  late final AnimationController _flingController =
      AnimationController.unbounded(vsync: this)..addListener(_onFlingTick);

  bool _historyMode = false;
  bool _historyLoading = false;
  bool _prefetching = false;
  xterm.Terminal? _historyTerminal;
  DateTime? _historyCapturedAt;
  Future<void>? _prefetchOp;
  final _historyScrollController = ScrollController();

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
    background: Colors.black,
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
    _wheelTimeout?.cancel();
    _wheelTimeout = null;
    _wheelInFlight = false;
    if (!_prefetching && _historyTerminal == null &&
        widget.session.terminal.mouseMode != xterm.MouseMode.none) {
      _prefetchHistory();
    }
    if (_userScrolledUp) return;
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
    _flingController.dispose();
    _wheelTimeout?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _focusNode.removeListener(_onFocusChange);
    widget.session.terminal.removeListener(_onTerminalChange);
    _historyScrollController.removeListener(_onHistoryScroll);
    _scrollController.dispose();
    _historyScrollController.dispose();
    _termController.dispose();
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
      _flingController.stop();
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
    if (widget.session.terminal.mouseMode == xterm.MouseMode.none) {
      _velocityTracker?.addPosition(event.timeStamp, event.position);
      _scrollNormalBuffer(event.delta.dy);
      return;
    }
    _scrollAccum += event.delta.dy;
    if (_scrollAccum.abs() < _scrollStep) return;
    final up = _scrollAccum > 0;
    _scrollAccum = 0;
    if (up) {
      _enterHistory();
      return;
    }
    _sendWheel(up);
  }

  void _sendWheel(bool up) {
    if (_wheelInFlight) return;
    _wheelInFlight = true;
    _wheelTimeout?.cancel();
    _wheelTimeout = Timer(const Duration(milliseconds: 200), () {
      _wheelInFlight = false;
    });
    final code = up ? 64 : 65;
    widget.session.sendKey('\x1b[<$code;1;1M');
  }

  void _scrollNormalBuffer(double dy) {
    if (!_scrollController.hasClients) return;
    final max = _scrollController.position.maxScrollExtent;
    if (max <= 0) return;
    final newOffset = (_scrollController.offset - dy).clamp(0.0, max);
    _scrollController.jumpTo(newOffset);
    final wasUp = _userScrolledUp;
    _userScrolledUp = newOffset < max - 1.0;
    if (wasUp != _userScrolledUp) setState(() {});
  }

  void _startFling(double velocity) {
    if (!_scrollController.hasClients) return;
    final max = _scrollController.position.maxScrollExtent;
    if (max <= 0) return;
    final sim = ClampingScrollSimulation(
      position: _scrollController.offset,
      velocity: -velocity,
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
    if (wasUp != _userScrolledUp) setState(() {});
    if (v <= 0.0 || v >= max) _flingController.stop();
  }

  // --- History overlay (capture-pane local scroll) ---

  Future<void> _enterHistory() async {
    if (_historyMode || _historyLoading) return;
    if (_historyTerminal == null) {
      // Full history not preloaded yet — show a minimal loading bar and wait
      // for the in-flight (or freshly started) silent prefetch to finish.
      setState(() => _historyLoading = true);
      if (!_prefetching) _prefetchHistory();
      await _prefetchOp;
      if (!mounted) return;
      setState(() => _historyLoading = false);
    }
    if (_historyTerminal == null) return;
    setState(() => _historyMode = true);
    HapticFeedback.lightImpact();
    _scrollHistoryToBottom();
  }

  // Silent full-history capture. Runs on tmux connect and on stale exit. Builds
  // the local buffer with zero UI; only swaps it into the cache when NOT viewing
  // history, so we never replace the live overlay's terminal (the freeze bug).
  void _prefetchHistory() {
    if (_prefetching) return;
    _prefetching = true;
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
    });
  }

  void _exitHistory() {
    setState(() => _historyMode = false);
    HapticFeedback.lightImpact();
    final age = _historyCapturedAt;
    if (age != null && DateTime.now().difference(age).inSeconds > 5) {
      _prefetchHistory();
    }
  }

  void _handlePointerUp(PointerUpEvent event) {
    if (event.kind == PointerDeviceKind.touch && _pointerDownPos != null) {
      final distance = (event.position - _pointerDownPos!).distance;
      if (distance < _tapSlop) {
        if (_termController.selection != null) {
          _termController.clearSelection();
        } else if (_focusNode.hasFocus) {
          _hideKeyboard();
        }
      } else if (distance >= _tapSlop &&
          !_historyMode &&
          _termController.selection == null &&
          widget.session.terminal.mouseMode == xterm.MouseMode.none) {
        final v = _velocityTracker?.getVelocity().pixelsPerSecond.dy ?? 0;
        if (v.abs() > 50) _startFling(v);
      }
    }
    _velocityTracker = null;
    _pointerDownPos = null;
    _scrollAccum = 0;
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
              if (_historyMode && _historyTerminal != null)
                Positioned.fill(
                  child: Column(
                    children: [
                      Container(
                        height: 32,
                        decoration: const BoxDecoration(
                          color: Color(0xFF1A1A1A),
                          border: Border(
                            bottom: BorderSide(
                              color: Color(0xFF3A3A3A),
                              width: 0.5,
                            ),
                          ),
                        ),
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        child: Row(
                          children: [
                            const Icon(
                              Icons.history,
                              color: Colors.white54,
                              size: 15,
                            ),
                            const SizedBox(width: 5),
                            const Text(
                              '历史回看',
                              style: TextStyle(
                                color: Colors.white54,
                                fontSize: 12,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                            const Spacer(),
                            GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onTap: _exitHistory,
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 10, vertical: 4),
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(12),
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
                                        fontSize: 11,
                                        fontWeight: FontWeight.w700,
                                        letterSpacing: 0.5,
                                      ),
                                    ),
                                    SizedBox(width: 3),
                                    Icon(
                                      Icons.arrow_forward,
                                      color: Color(0xFF34C759),
                                      size: 13,
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      Expanded(
                        child: xterm.TerminalView(
                          _historyTerminal!,
                          scrollController: _historyScrollController,
                          readOnly: true,
                          hardwareKeyboardOnly: true,
                          textStyle: _kTermStyle,
                          theme: _kTermTheme,
                        ),
                      ),
                    ],
                  ),
                ),
              if (_historyLoading)
                const Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: LinearProgressIndicator(minHeight: 2),
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
                            _scrollController.jumpTo(
                                _scrollController.position.maxScrollExtent);
                          }
                          setState(() => _userScrolledUp = false);
                        },
                        child: Container(
                          width: 40,
                          height: 40,
                          decoration: BoxDecoration(
                            color: const Color(0xFF2A2A2A),
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: const Color(0xFF5AC8FA),
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
                          child: const Icon(
                            Icons.keyboard_arrow_down,
                            color: Color(0xFF5AC8FA),
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
        if (!_focusNode.hasFocus)
          _InputBar(
            onTap: _showKeyboard,
          ),
        _ToolbarWrapper(
          session: widget.session,
          termController: _termController,
          terminalViewKey: _terminalViewKey,
          onHideKeyboard: _hideKeyboard,
          onShowKeyboard: _showKeyboard,
        ),
      ],
    );
  }
}

class _InputBar extends StatelessWidget {
  final VoidCallback onTap;

  const _InputBar({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 36,
        decoration: const BoxDecoration(
          color: Color(0xFF1A1A1A),
          border: Border(
            top: BorderSide(color: Color(0xFF2A2A2A), width: 0.5),
          ),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 14),
        child: const Row(
          children: [
            Icon(
              Icons.keyboard_outlined,
              color: Colors.white38,
              size: 18,
            ),
            SizedBox(width: 8),
            Text(
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
  final VoidCallback onShowKeyboard;
  const _ToolbarWrapper({
    required this.session,
    required this.termController,
    required this.terminalViewKey,
    required this.onHideKeyboard,
    required this.onShowKeyboard,
  });

  @override
  State<_ToolbarWrapper> createState() => _ToolbarWrapperState();
}

class _ToolbarWrapperState extends State<_ToolbarWrapper> {
  static const _clipboardChannel = MethodChannel('com.clawmate.clipboard');
  final _speech = stt.SpeechToText();
  bool _isListening = false;
  bool _speechAvailable = false;

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
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('剪贴板没有图片'),
          duration: Duration(seconds: 1),
        ),
      );
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
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('已上传图片 (${kb}KB)'),
        duration: const Duration(seconds: 2),
      ),
    );
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
      localeId: 'zh_CN',
      listenMode: stt.ListenMode.dictation,
    );
  }

  @override
  Widget build(BuildContext context) {
    return KeyboardToolbar(
      ctrlActive: widget.session.ctrlPressed,
      isListening: _isListening,
      onVoiceToggle: _toggleVoice,
      onCtrlToggle: () {
        widget.session.toggleCtrl();
        setState(() {});
      },
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
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('已复制到剪贴板'),
              duration: Duration(seconds: 1),
            ),
          );
        }
      },
      onKeyTap: (key) {
        widget.onShowKeyboard();
        widget.session.sendKey(key);
        if (widget.session.ctrlPressed) setState(() {});
      },
      onHideKeyboard: widget.onHideKeyboard,
      onPaste: (text) {
        widget.session.sendKey(text);
      },
      onPasteImage: _pasteImage,
    );
  }
}
