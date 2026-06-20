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

class _ScrollDbg {
  static int downs = 0;
  static int moves = 0;
  static int steps = 0;
  static double lastDy = 0;
  static String mode = '-';
  static String handled = '-';
  static String path = '-';
}

class TerminalView extends StatefulWidget {
  final TerminalSession session;

  const TerminalView({super.key, required this.session});

  @override
  State<TerminalView> createState() => _TerminalViewState();
}

class _TerminalViewState extends State<TerminalView>
    with WidgetsBindingObserver {
  final _terminalViewKey = GlobalKey<xterm.TerminalViewState>();
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
    cursor: Colors.white,
    selection: Colors.white24,
    foreground: Colors.white,
    background: Colors.black,
    black: Colors.black,
    white: Colors.white,
    red: Colors.red,
    green: Colors.green,
    yellow: Colors.yellow,
    blue: Colors.blue,
    magenta: const Color(0xFFFF00FF),
    cyan: Colors.cyan,
    brightBlack: Colors.grey,
    brightRed: Colors.redAccent,
    brightGreen: Colors.greenAccent,
    brightYellow: Colors.yellowAccent,
    brightBlue: Colors.blueAccent,
    brightMagenta: const Color(0xFFFF79C6),
    brightCyan: Colors.cyanAccent,
    brightWhite: Colors.white,
    searchHitBackground: Colors.yellow,
    searchHitBackgroundCurrent: Colors.orange,
    searchHitForeground: Colors.black,
  );

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _focusNode.addListener(_onFocusChange);
    widget.session.terminal.addListener(_onTerminalChange);
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
    _wheelTimeout?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _focusNode.removeListener(_onFocusChange);
    widget.session.terminal.removeListener(_onTerminalChange);
    _scrollController.dispose();
    _historyScrollController.dispose();
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
      _ScrollDbg.downs++;
    }
  }

  void _handlePointerMove(PointerMoveEvent event) {
    if (event.kind != PointerDeviceKind.touch) return;
    if (_historyLoading) return;
    if (_historyMode) {
      _scrollAccum += event.delta.dy;
      if (_scrollAccum.abs() < _scrollStep) return;
      final down = _scrollAccum < 0;
      _scrollAccum = 0;
      if (down && _historyScrollController.hasClients) {
        final pos = _historyScrollController.position;
        if (pos.pixels >= pos.maxScrollExtent - 1.0) {
          _exitHistory();
        }
      }
      return;
    }
    _ScrollDbg.moves++;
    _ScrollDbg.lastDy = event.delta.dy;
    _scrollAccum += event.delta.dy;
    if (_scrollAccum.abs() < _scrollStep) return;
    final up = _scrollAccum > 0;
    _scrollAccum = 0;
    if (up && widget.session.terminal.mouseMode != xterm.MouseMode.none) {
      _enterHistory();
      return;
    }
    _sendWheel(up);
  }

  void _sendWheel(bool up) {
    final terminal = widget.session.terminal;
    _ScrollDbg.steps++;
    _ScrollDbg.mode = terminal.mouseMode.toString();
    if (terminal.mouseMode != xterm.MouseMode.none) {
      if (_wheelInFlight) {
        _ScrollDbg.path = 'skip(inflight)';
        return;
      }
      _wheelInFlight = true;
      _wheelTimeout?.cancel();
      _wheelTimeout = Timer(const Duration(milliseconds: 200), () {
        _wheelInFlight = false;
      });
      final code = up ? 64 : 65;
      widget.session.sendKey('\x1b[<$code;1;1M');
      _ScrollDbg.handled = 'sgr';
      _ScrollDbg.path = 'wheel>tmux';
    } else {
      _ScrollDbg.path = 'normal';
      _ScrollDbg.handled = 'n/a';
      _scrollNormalBuffer(up);
    }
  }

  void _scrollNormalBuffer(bool up) {
    if (!_scrollController.hasClients) return;
    final step = _scrollStep * 3.0;
    final max = _scrollController.position.maxScrollExtent;
    if (max <= 0) return;
    final current = _scrollController.offset;
    final newOffset = up
        ? (current - step).clamp(0.0, max)
        : (current + step).clamp(0.0, max);
    _scrollController.jumpTo(newOffset);
    _userScrolledUp = newOffset < max - 1.0;
  }

  // --- History overlay (capture-pane local scroll) ---

  Future<void> _enterHistory() async {
    if (_historyMode || _historyLoading) return;
    if (_historyTerminal == null) {
      // Full history not preloaded yet — show a minimal loading bar and wait
      // for the in-flight (or freshly started) silent prefetch to finish.
      setState(() => _historyLoading = true);
      _ScrollDbg.path = 'capture…';
      if (!_prefetching) _prefetchHistory();
      await _prefetchOp;
      if (!mounted) return;
      setState(() => _historyLoading = false);
    }
    if (_historyTerminal == null) return;
    setState(() => _historyMode = true);
    _scrollHistoryToBottom();
    _ScrollDbg.path = 'history';
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
    _ScrollDbg.path = 'live';
    final age = _historyCapturedAt;
    if (age != null && DateTime.now().difference(age).inSeconds > 5) {
      _prefetchHistory();
    }
  }

  void _handlePointerUp(PointerUpEvent event) {
    if (event.kind == PointerDeviceKind.touch && _pointerDownPos != null) {
      final distance = (event.position - _pointerDownPos!).distance;
      if (distance < _tapSlop && _focusNode.hasFocus) {
        _hideKeyboard();
      }
    }
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
                        color: Colors.black87,
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        child: Row(
                          children: [
                            const Text(
                              '⏪ 历史回看',
                              style: TextStyle(
                                color: Colors.white70,
                                fontSize: 12,
                              ),
                            ),
                            const Spacer(),
                            GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onTap: _exitHistory,
                              child: const Padding(
                                padding: EdgeInsets.symmetric(
                                    horizontal: 8, vertical: 6),
                                child: Text(
                                  '返回实时 ▶',
                                  style: TextStyle(
                                    color: Colors.greenAccent,
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                  ),
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
            ],
            ),
          ),
        ),
        _InputBar(
          hasFocus: _focusNode.hasFocus,
          onTap: _showKeyboard,
        ),
        _ToolbarWrapper(
          session: widget.session,
          terminalViewKey: _terminalViewKey,
          onHideKeyboard: _hideKeyboard,
          onShowKeyboard: _showKeyboard,
        ),
      ],
    );
  }
}

class _DebugBar extends StatefulWidget {
  final TerminalSession session;
  final ScrollController scrollController;

  const _DebugBar({
    required this.session,
    required this.scrollController,
  });

  @override
  State<_DebugBar> createState() => _DebugBarState();
}

class _DebugBarState extends State<_DebugBar> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.session.terminal;
    final alt = t.isUsingAltBuffer;
    final lines = t.buffer.lines.length;
    final vh = t.viewHeight;
    final vw = t.viewWidth;
    final mouse = t.mouseMode;

    String scrollInfo = 'no clients';
    if (widget.scrollController.hasClients) {
      final pos = widget.scrollController.position;
      scrollInfo = 'off=${pos.pixels.toStringAsFixed(0)}'
          ' max=${pos.maxScrollExtent.toStringAsFixed(0)}';
    }

    return Container(
      height: 40,
      color: Colors.red[900],
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              'alt=$alt lines=$lines vh=$vh vw=$vw mouse=$mouse $scrollInfo',
              style: const TextStyle(color: Colors.white, fontSize: 9),
            ),
          ),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              'dn=${_ScrollDbg.downs} mv=${_ScrollDbg.moves} st=${_ScrollDbg.steps} '
              'dy=${_ScrollDbg.lastDy.toStringAsFixed(1)} '
              'mode=${_ScrollDbg.mode} hdl=${_ScrollDbg.handled} path=${_ScrollDbg.path}',
              style: const TextStyle(color: Colors.yellowAccent, fontSize: 9),
            ),
          ),
        ],
      ),
    );
  }
}

class _InputBar extends StatelessWidget {
  final bool hasFocus;
  final VoidCallback onTap;

  const _InputBar({
    required this.hasFocus,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 36,
        color: Colors.grey[850],
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(
          children: [
            Icon(
              hasFocus ? Icons.keyboard : Icons.keyboard_outlined,
              color: hasFocus ? Colors.blue : Colors.grey[500],
              size: 18,
            ),
            const SizedBox(width: 8),
            Text(
              hasFocus ? 'Typing...' : 'Tap to type',
              style: TextStyle(
                color: hasFocus ? Colors.blue : Colors.grey[500],
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
  final GlobalKey<xterm.TerminalViewState> terminalViewKey;
  final VoidCallback onHideKeyboard;
  final VoidCallback onShowKeyboard;
  const _ToolbarWrapper({
    required this.session,
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
        final buffer = terminal.buffer;
        final lines = <String>[];
        final scrollBack = buffer.height - terminal.viewHeight;
        for (var i = 0; i < terminal.viewHeight; i++) {
          lines.add(buffer.lines[i + scrollBack].toString().trimRight());
        }
        final text = lines.join('\n').trimRight();
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
