import 'dart:convert';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:xterm/xterm.dart' as xterm;

import '../providers/terminal_provider.dart';
import '../widgets/keyboard_toolbar.dart';

class _NoScrollBehavior extends ScrollBehavior {
  @override
  ScrollPhysics getScrollPhysics(BuildContext context) {
    return const NeverScrollableScrollPhysics();
  }
}

class _SuppressableFocusNode extends FocusNode {
  bool _suppressed = false;

  void suppressAndUnfocus() {
    _suppressed = true;
    unfocus();
    Future.delayed(const Duration(milliseconds: 400), () {
      _suppressed = false;
    });
  }

  void allowFocus() {
    _suppressed = false;
  }

  @override
  void requestFocus([FocusNode? node]) {
    if (_suppressed) return;
    super.requestFocus(node);
  }
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
  final _focusNode = _SuppressableFocusNode();
  Offset? _pointerDownPos;
  double _altScrollAccum = 0;
  static const _tapSlop = 12.0;
  static const _altScrollStep = 20.0;
  String _debugInfo = '';
  int _scrollEvents = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _focusNode.addListener(() {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _scrollController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _focusNode.hasFocus) {
      Future.delayed(const Duration(milliseconds: 500), () {
        if (mounted) _terminalViewKey.currentState?.requestKeyboard();
      });
    }
  }

  void _showKeyboard() {
    _focusNode.allowFocus();
    _terminalViewKey.currentState?.requestKeyboard();
  }

  void _hideKeyboard() {
    _focusNode.suppressAndUnfocus();
  }

  bool get _isAltBuffer => widget.session.terminal.isUsingAltBuffer;

  void _handlePointerDown(PointerDownEvent event) {
    if (event.kind == PointerDeviceKind.touch) {
      _pointerDownPos = event.position;
      _altScrollAccum = 0;
    }
  }

  void _sendWheelEvent(bool up) {
    final terminal = widget.session.terminal;
    final mouseMode = terminal.mouseMode;

    if (mouseMode == xterm.MouseMode.none ||
        mouseMode == xterm.MouseMode.clickOnly) {
      terminal.keyInput(
          up ? xterm.TerminalKey.arrowUp : xterm.TerminalKey.arrowDown);
      setState(() => _debugInfo =
          '#$_scrollEvents ${up ? "UP" : "DN"} arrow');
      return;
    }

    // Standard button codes: wheelUp=64, wheelDown=65
    // xterm package has wrong IDs (68/69), so we generate the escape ourselves
    final btn = up ? 64 : 65;
    final cx = terminal.viewWidth ~/ 2 + 1;
    final cy = terminal.viewHeight ~/ 2 + 1;

    final reportMode = terminal.mouseReportMode;
    String esc;
    switch (reportMode) {
      case xterm.MouseReportMode.sgr:
        esc = '\x1b[<$btn;$cx;${cy}M';
      case xterm.MouseReportMode.normal:
      case xterm.MouseReportMode.utf:
        esc =
            '\x1b[M${String.fromCharCode(32 + btn)}${String.fromCharCode(32 + cx)}${String.fromCharCode(32 + cy)}';
      case xterm.MouseReportMode.urxvt:
        esc = '\x1b[${32 + btn};$cx;${cy}M';
    }

    widget.session.ssh.write(utf8.encode(esc));
    setState(() => _debugInfo =
        '#$_scrollEvents ${up ? "UP" : "DN"} $reportMode btn=$btn');
  }

  void _handlePointerMove(PointerMoveEvent event) {
    if (event.kind != PointerDeviceKind.touch) return;

    final dy = event.delta.dy;
    if (_isAltBuffer) {
      _altScrollAccum += dy;
      while (_altScrollAccum.abs() >= _altScrollStep) {
        _scrollEvents++;
        if (_altScrollAccum < 0) {
          _sendWheelEvent(false);
          _altScrollAccum += _altScrollStep;
        } else {
          _sendWheelEvent(true);
          _altScrollAccum -= _altScrollStep;
        }
      }
    } else {
      if (_scrollController.hasClients) {
        final maxExtent = _scrollController.position.maxScrollExtent;
        final newOffset = (_scrollController.offset - dy).clamp(0.0, maxExtent);
        _scrollController.jumpTo(newOffset);
        setState(() => _debugInfo = 'NORM off=${newOffset.toStringAsFixed(0)} max=${maxExtent.toStringAsFixed(0)}');
      } else {
        setState(() => _debugInfo = 'NO CLIENTS');
      }
    }
  }

  void _handlePointerUp(PointerUpEvent event) {
    if (event.kind != PointerDeviceKind.touch) return;
    if (_pointerDownPos != null) {
      final distance = (event.position - _pointerDownPos!).distance;
      if (distance < _tapSlop && _focusNode.hasFocus) {
        _focusNode.suppressAndUnfocus();
      }
    }
    _pointerDownPos = null;
    _altScrollAccum = 0;
  }

  void _handlePointerCancel(PointerCancelEvent event) {
    _pointerDownPos = null;
    _altScrollAccum = 0;
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        if (_debugInfo.isNotEmpty)
          Container(
            color: Colors.red,
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Text(
              _debugInfo,
              style: const TextStyle(color: Colors.white, fontSize: 11, fontFamily: 'Menlo'),
            ),
          ),
        Expanded(
          child: Listener(
            onPointerDown: _handlePointerDown,
            onPointerMove: _handlePointerMove,
            onPointerUp: _handlePointerUp,
            onPointerCancel: _handlePointerCancel,
            child: ScrollConfiguration(
              behavior: _NoScrollBehavior(),
              child: xterm.TerminalView(
                widget.session.terminal,
                key: _terminalViewKey,
                scrollController: _scrollController,
                focusNode: _focusNode,
                autofocus: false,
                deleteDetection: true,
                keyboardType: TextInputType.text,
                textStyle: const xterm.TerminalStyle(
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
                ),
                theme: xterm.TerminalTheme(
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
                ),
              ),
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
  final _speech = stt.SpeechToText();
  bool _isListening = false;
  bool _speechAvailable = false;

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
      onKeyTap: (key) {
        widget.onShowKeyboard();
        widget.session.sendKey(key);
        if (widget.session.ctrlPressed) setState(() {});
        if (key == '\r') widget.onHideKeyboard();
      },
      onHideKeyboard: widget.onHideKeyboard,
      onPaste: (text) {
        widget.session.sendKey(text);
      },
    );
  }
}
