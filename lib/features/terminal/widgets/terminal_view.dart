import 'dart:async';
import 'dart:convert';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
  bool _scrolledDuringGesture = false;
  static const _tapSlop = 12.0;
  static const _altScrollStep = 20.0;

  // Local scroll for alt buffer mode
  int _localScrollOffset = 0;
  bool get _isLocalScrolling => _localScrollOffset > 0;

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
      _scrolledDuringGesture = false;
    }
  }

  void _sendWheelEvent(bool up) {
    final terminal = widget.session.terminal;
    final mouseMode = terminal.mouseMode;

    if (mouseMode == xterm.MouseMode.none ||
        mouseMode == xterm.MouseMode.clickOnly) {
      terminal.keyInput(
          up ? xterm.TerminalKey.arrowUp : xterm.TerminalKey.arrowDown);
      return;
    }

    // Local buffer scroll — no network round-trip
    final lines = widget.session.scrollBackLines;
    final viewH = terminal.viewHeight;
    final maxOffset = (lines.length - viewH).clamp(0, lines.length);
    if (up) {
      _localScrollOffset = (_localScrollOffset + 3).clamp(0, maxOffset);
    } else {
      _localScrollOffset = (_localScrollOffset - 3).clamp(0, maxOffset);
    }
    setState(() {});
  }

  void _exitLocalScroll() {
    if (_localScrollOffset > 0) {
      _localScrollOffset = 0;
      setState(() {});
    }
  }

  void _handlePointerMove(PointerMoveEvent event) {
    if (event.kind != PointerDeviceKind.touch) return;

    final dy = event.delta.dy;
    if (dy.abs() > 2) _scrolledDuringGesture = true;
    if (_isAltBuffer) {
      _altScrollAccum += dy;
      while (_altScrollAccum.abs() >= _altScrollStep) {
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
      }
    }
  }

  void _handlePointerUp(PointerUpEvent event) {
    if (event.kind != PointerDeviceKind.touch) return;
    if (!_scrolledDuringGesture && _pointerDownPos != null) {
      final distance = (event.position - _pointerDownPos!).distance;
      if (distance < _tapSlop) {
        if (_isLocalScrolling) {
          _exitLocalScroll();
        } else if (_focusNode.hasFocus) {
          _focusNode.suppressAndUnfocus();
        }
      }
    }
    _pointerDownPos = null;
    _altScrollAccum = 0;
    _scrolledDuringGesture = false;
  }

  void _handlePointerCancel(PointerCancelEvent event) {
    _pointerDownPos = null;
    _altScrollAccum = 0;
    _scrolledDuringGesture = false;
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
                ScrollConfiguration(
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
                if (_isLocalScrolling)
                  Positioned.fill(
                    child: _LocalScrollOverlay(
                      lines: widget.session.scrollBackLines,
                      offset: _localScrollOffset,
                      viewHeight: widget.session.terminal.viewHeight,
                    ),
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

class _LocalScrollOverlay extends StatelessWidget {
  final List<String> lines;
  final int offset;
  final int viewHeight;

  const _LocalScrollOverlay({
    required this.lines,
    required this.offset,
    required this.viewHeight,
  });

  @override
  Widget build(BuildContext context) {
    final end = (lines.length - offset).clamp(0, lines.length);
    final start = (end - viewHeight).clamp(0, end);
    final visibleLines = lines.sublist(start, end);
    final content = visibleLines.join('\n');

    return Container(
      color: Colors.black,
      padding: const EdgeInsets.all(4),
      child: Stack(
        children: [
          Text(
            content,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 12,
              fontFamily: 'Menlo',
              height: 1.2,
            ),
          ),
          Positioned(
            top: 4,
            right: 4,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: Colors.blue.withValues(alpha: 0.8),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                '↑$offset 点击返回',
                style: const TextStyle(color: Colors.white, fontSize: 10),
              ),
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
        if (key == '\r') widget.onHideKeyboard();
      },
      onHideKeyboard: widget.onHideKeyboard,
      onPaste: (text) {
        widget.session.sendKey(text);
      },
    );
  }
}
