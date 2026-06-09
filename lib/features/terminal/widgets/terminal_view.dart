import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:xterm/xterm.dart' as xterm;

import '../providers/terminal_provider.dart';
import '../widgets/keyboard_toolbar.dart';

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
  double _altScrollAccum = 0;
  Offset? _pointerDownPos;
  static const _altScrollStep = 20.0;
  static const _tapSlop = 12.0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _focusNode.addListener(_onFocusChange);
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
    WidgetsBinding.instance.removeObserver(this);
    _focusNode.removeListener(_onFocusChange);
    _scrollController.dispose();
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

  bool get _isAltBuffer => widget.session.terminal.isUsingAltBuffer;

  void _handlePointerDown(PointerDownEvent event) {
    if (event.kind == PointerDeviceKind.touch) {
      _pointerDownPos = event.position;
      _altScrollAccum = 0;
    }
  }

  void _handlePointerMove(PointerMoveEvent event) {
    if (event.kind != PointerDeviceKind.touch) return;
    if (!_isAltBuffer) return;

    _altScrollAccum += event.delta.dy;
    while (_altScrollAccum.abs() >= _altScrollStep) {
      if (_altScrollAccum < 0) {
        widget.session.terminal.keyInput(xterm.TerminalKey.arrowDown);
        _altScrollAccum += _altScrollStep;
      } else {
        widget.session.terminal.keyInput(xterm.TerminalKey.arrowUp);
        _altScrollAccum -= _altScrollStep;
      }
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
    _altScrollAccum = 0;
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
    );
  }
}
