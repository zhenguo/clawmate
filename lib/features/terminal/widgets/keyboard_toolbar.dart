import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class KeyboardToolbar extends StatefulWidget {
  final bool ctrlActive;
  final VoidCallback onCtrlToggle;
  final ValueChanged<String> onKeyTap;
  final VoidCallback? onHideKeyboard;
  final VoidCallback? onPaste;
  final VoidCallback? onPasteImage;
  final VoidCallback? onCopyTerminal;
  final VoidCallback? onShowHistory;
  final bool isListening;
  final VoidCallback? onVoiceToggle;

  const KeyboardToolbar({
    super.key,
    required this.ctrlActive,
    required this.onCtrlToggle,
    required this.onKeyTap,
    this.onHideKeyboard,
    this.onPaste,
    this.onPasteImage,
    this.onCopyTerminal,
    this.onShowHistory,
    this.isListening = false,
    this.onVoiceToggle,
  });

  static const _bg = Color(0xFF1A1A1A);
  static const _keyColor = Color(0xFF2A2A2A);
  static const _keyPressColor = Color(0xFF3A3A3A);
  static const _accentColor = Color(0xFF5AC8FA);
  static const _iconSize = 17.0;
  static const _textStyle = TextStyle(
    color: Colors.white70,
    fontSize: 12,
    fontWeight: FontWeight.w500,
    fontFamily: 'Menlo',
  );

  @override
  State<KeyboardToolbar> createState() => _KeyboardToolbarState();
}

class _KeyboardToolbarState extends State<KeyboardToolbar> {
  final _scrollController = ScrollController();
  bool _showRightFade = true;
  bool _showLeftFade = false;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) => _onScroll());
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final offset = _scrollController.offset;
    final max = _scrollController.position.maxScrollExtent;
    final atEnd = offset >= max - 8;
    final atStart = offset <= 8;
    bool changed = false;
    if (atEnd != !_showRightFade) {
      _showRightFade = !atEnd;
      changed = true;
    }
    if (atStart != !_showLeftFade) {
      _showLeftFade = !atStart;
      changed = true;
    }
    if (changed) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 44,
      decoration: const BoxDecoration(
        color: KeyboardToolbar._bg,
        border: Border(
          top: BorderSide(color: Color(0xFF2A2A2A), width: 0.5),
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: Stack(
        children: [
          SingleChildScrollView(
            controller: _scrollController,
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                // --- Modifiers ---
                _ToggleKey(
                  label: 'Ctrl',
                  active: widget.ctrlActive,
                  accentColor: KeyboardToolbar._accentColor,
                  onTap: widget.onCtrlToggle,
                ),
                _TextKey('Esc', () => widget.onKeyTap('\x1b')),
                _TextKey('^C', () => widget.onKeyTap('\x03')),
                _IconKey(Icons.keyboard_return, () => widget.onKeyTap('\r'),
                    accent: KeyboardToolbar._accentColor),
                const _GroupDivider(),
                // --- Navigation ---
                _IconKey(Icons.keyboard_arrow_left, () => widget.onKeyTap('\x1b[D'), tooltip: '←', repeat: true),
                _IconKey(Icons.keyboard_arrow_up, () => widget.onKeyTap('\x1b[A'), tooltip: '↑', repeat: true),
                _IconKey(Icons.keyboard_arrow_down, () => widget.onKeyTap('\x1b[B'), tooltip: '↓', repeat: true),
                _IconKey(Icons.keyboard_arrow_right, () => widget.onKeyTap('\x1b[C'), tooltip: '→', repeat: true),
                _IconKey(Icons.keyboard_double_arrow_up, () => widget.onKeyTap('\x1b[5~'), tooltip: 'PgUp'),
                _IconKey(Icons.keyboard_double_arrow_down, () => widget.onKeyTap('\x1b[6~'), tooltip: 'PgDn'),
                _IconKey(Icons.backspace_outlined, () => widget.onKeyTap('\x7f'), repeat: true),
                const _GroupDivider(),
                // --- Editing ---
                _IconKey(Icons.keyboard_tab, () => widget.onKeyTap('\t'), tooltip: 'Tab'),
                _TextKey('/', () => widget.onKeyTap('/'), repeat: true),
                _TextKey('Home', () => widget.onKeyTap('\x01')),
                _TextKey('End', () => widget.onKeyTap('\x05')),
                const _GroupDivider(),
                // --- Symbols ---
                _TextKey('-', () => widget.onKeyTap('-'), repeat: true),
                _TextKey('_', () => widget.onKeyTap('_'), repeat: true),
                _TextKey('.', () => widget.onKeyTap('.'), repeat: true),
                _TextKey('\$', () => widget.onKeyTap('\$'), repeat: true),
                _TextKey('&', () => widget.onKeyTap('&'), repeat: true),
                _TextKey('|', () => widget.onKeyTap('|'), repeat: true),
                _TextKey('~', () => widget.onKeyTap('~'), repeat: true),
                _TextKey('=', () => widget.onKeyTap('='), repeat: true),
                _TextKey(':', () => widget.onKeyTap(':'), repeat: true),
                _TextKey('@', () => widget.onKeyTap('@')),
                _TextKey('*', () => widget.onKeyTap('*'), repeat: true),
                _TextKey('#', () => widget.onKeyTap('#'), repeat: true),
                const _GroupDivider(),
                // --- Actions ---
                _IconKey(Icons.history, () => widget.onShowHistory?.call()),
                _IconKey(Icons.copy_outlined, () => widget.onCopyTerminal?.call()),
                _IconKey(Icons.content_paste, () => widget.onPaste?.call()),
                _IconKey(Icons.image_outlined, () => widget.onPasteImage?.call()),
                _VoiceKey(
                  isListening: widget.isListening,
                  onTap: widget.onVoiceToggle,
                ),
                _IconKey(Icons.keyboard_hide_outlined, () => widget.onHideKeyboard?.call()),
              ],
            ),
          ),
          Positioned(
            right: 0,
            top: 0,
            bottom: 0,
            width: 36,
            child: IgnorePointer(
              child: AnimatedOpacity(
                opacity: _showRightFade ? 1.0 : 0.0,
                duration: const Duration(milliseconds: 160),
                curve: Curves.easeOut,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.centerLeft,
                      end: Alignment.centerRight,
                      colors: [
                        KeyboardToolbar._bg.withValues(alpha: 0),
                        KeyboardToolbar._bg,
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            left: 0,
            top: 0,
            bottom: 0,
            width: 36,
            child: IgnorePointer(
              child: AnimatedOpacity(
                opacity: _showLeftFade ? 1.0 : 0.0,
                duration: const Duration(milliseconds: 160),
                curve: Curves.easeOut,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.centerRight,
                      end: Alignment.centerLeft,
                      colors: [
                        KeyboardToolbar._bg.withValues(alpha: 0),
                        KeyboardToolbar._bg,
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _GroupDivider extends StatelessWidget {
  const _GroupDivider();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 1,
      height: 20,
      margin: const EdgeInsets.symmetric(horizontal: 5),
      color: const Color(0xFF3A3A3A),
    );
  }
}

class _PressScale extends StatelessWidget {
  final bool pressed;
  final Widget child;
  const _PressScale({required this.pressed, required this.child});

  @override
  Widget build(BuildContext context) {
    return AnimatedScale(
      scale: pressed ? 0.92 : 1.0,
      duration: const Duration(milliseconds: 90),
      curve: Curves.easeOut,
      child: child,
    );
  }
}

mixin _RepeatableKey<T extends StatefulWidget> on State<T> {
  bool _pressed = false;
  bool _didRepeat = false;
  Timer? _repeatDelay;
  Timer? _repeatTimer;

  bool get repeatEnabled;
  VoidCallback? get repeatAction;

  void _startRepeat() {
    if (!repeatEnabled) return;
    _repeatDelay = Timer(const Duration(milliseconds: 400), () {
      _repeatTimer = Timer.periodic(const Duration(milliseconds: 70), (_) {
        _didRepeat = true;
        HapticFeedback.selectionClick();
        repeatAction?.call();
      });
    });
  }

  void _stopRepeat() {
    _repeatDelay?.cancel();
    _repeatDelay = null;
    _repeatTimer?.cancel();
    _repeatTimer = null;
  }

  @override
  void dispose() {
    _stopRepeat();
    super.dispose();
  }

  void _handleTapDown() {
    _didRepeat = false;
    _startRepeat();
    setState(() => _pressed = true);
  }

  void _handleTapUp() {
    _stopRepeat();
    setState(() => _pressed = false);
  }

  void _handleTapCancel() {
    _stopRepeat();
    setState(() => _pressed = false);
  }

  void _handleTap() {
    if (_didRepeat) return;
    HapticFeedback.selectionClick();
    repeatAction?.call();
  }
}

class _IconKey extends StatefulWidget {
  final IconData icon;
  final VoidCallback? onTap;
  final String? tooltip;
  final bool repeat;
  final Color? accent;

  const _IconKey(this.icon, this.onTap,
      {this.tooltip, this.repeat = false, this.accent});

  @override
  State<_IconKey> createState() => _IconKeyState();
}

class _IconKeyState extends State<_IconKey> with _RepeatableKey {
  @override
  bool get repeatEnabled => widget.repeat;
  @override
  VoidCallback? get repeatAction => widget.onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => _handleTapDown(),
      onTapUp: (_) => _handleTapUp(),
      onTapCancel: _handleTapCancel,
      onTap: _handleTap,
      child: _PressScale(
        pressed: _pressed,
        child: Container(
          width: 40,
          height: 38,
          alignment: Alignment.center,
          margin: const EdgeInsets.symmetric(horizontal: 2),
          decoration: BoxDecoration(
            color: widget.accent != null
                ? (_pressed
                    ? widget.accent!.withValues(alpha: 0.35)
                    : widget.accent!.withValues(alpha: 0.2))
                : (_pressed
                    ? KeyboardToolbar._keyPressColor
                    : KeyboardToolbar._keyColor),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Icon(
            widget.icon,
            color: widget.accent != null
                ? (_pressed ? Colors.white : widget.accent!)
                : (_pressed ? Colors.white : Colors.white70),
            size: KeyboardToolbar._iconSize,
          ),
        ),
      ),
    );
  }
}

class _TextKey extends StatefulWidget {
  final String label;
  final VoidCallback onTap;
  final bool repeat;

  const _TextKey(this.label, this.onTap, {this.repeat = false});

  @override
  State<_TextKey> createState() => _TextKeyState();
}

class _TextKeyState extends State<_TextKey> with _RepeatableKey {
  @override
  bool get repeatEnabled => widget.repeat;
  @override
  VoidCallback? get repeatAction => widget.onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => _handleTapDown(),
      onTapUp: (_) => _handleTapUp(),
      onTapCancel: _handleTapCancel,
      onTap: _handleTap,
      child: _PressScale(
        pressed: _pressed,
        child: Container(
          width: 40,
          height: 38,
          alignment: Alignment.center,
          margin: const EdgeInsets.symmetric(horizontal: 2),
          decoration: BoxDecoration(
            color: _pressed
                ? KeyboardToolbar._keyPressColor
                : KeyboardToolbar._keyColor,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(
            widget.label,
            style: KeyboardToolbar._textStyle.copyWith(
              color: _pressed ? Colors.white : Colors.white70,
            ),
          ),
        ),
      ),
    );
  }
}

class _ToggleKey extends StatefulWidget {
  final String label;
  final bool active;
  final Color accentColor;
  final VoidCallback onTap;

  const _ToggleKey({
    required this.label,
    required this.active,
    required this.accentColor,
    required this.onTap,
  });

  @override
  State<_ToggleKey> createState() => _ToggleKeyState();
}

class _ToggleKeyState extends State<_ToggleKey>
    with SingleTickerProviderStateMixin {
  bool _pressed = false;
  late final AnimationController _pulseController = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 800),
  );
  late final Animation<double> _pulseAnim = Tween<double>(
    begin: 0.6,
    end: 1.0,
  ).animate(CurvedAnimation(
    parent: _pulseController,
    curve: Curves.easeInOut,
  ));

  @override
  void initState() {
    super.initState();
    if (widget.active) _pulseController.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(covariant _ToggleKey oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active && !_pulseController.isAnimating) {
      _pulseController.repeat(reverse: true);
    } else if (!widget.active && _pulseController.isAnimating) {
      _pulseController.stop();
      _pulseController.value = 0;
    }
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final active = widget.active;
    return GestureDetector(
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) => setState(() => _pressed = false),
      onTapCancel: () => setState(() => _pressed = false),
      onTap: () {
        HapticFeedback.selectionClick();
        widget.onTap();
      },
      child: _PressScale(
        pressed: _pressed,
        child: AnimatedBuilder(
        animation: _pulseAnim,
        builder: (context, child) {
          return Container(
            width: 40,
            height: 38,
            alignment: Alignment.center,
            margin: const EdgeInsets.symmetric(horizontal: 2),
            decoration: BoxDecoration(
              color: active
                  ? widget.accentColor.withValues(alpha:
                      _pressed ? 0.9 : _pulseAnim.value)
                  : (_pressed
                      ? KeyboardToolbar._keyPressColor
                      : KeyboardToolbar._keyColor),
              borderRadius: BorderRadius.circular(6),
            ),
            child: child,
          );
        },
        child: Text(
          widget.label,
          style: TextStyle(
            color: active ? Colors.black87 : Colors.white70,
            fontSize: 11,
            fontWeight: active ? FontWeight.w700 : FontWeight.w500,
          ),
        ),
        ),
      ),
    );
  }
}

class _VoiceKey extends StatefulWidget {
  final bool isListening;
  final VoidCallback? onTap;

  const _VoiceKey({required this.isListening, this.onTap});

  @override
  State<_VoiceKey> createState() => _VoiceKeyState();
}

class _VoiceKeyState extends State<_VoiceKey> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final listening = widget.isListening;
    return GestureDetector(
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) => setState(() => _pressed = false),
      onTapCancel: () => setState(() => _pressed = false),
      onTap: widget.onTap == null
          ? null
          : () {
              HapticFeedback.selectionClick();
              widget.onTap!();
            },
      child: _PressScale(
        pressed: _pressed,
        child: Container(
          width: 40,
          height: 38,
          alignment: Alignment.center,
          margin: const EdgeInsets.symmetric(horizontal: 2),
          decoration: BoxDecoration(
            color: listening
                ? const Color(0xFFFF3B30).withValues(alpha: _pressed ? 0.9 : 0.7)
                : (_pressed
                    ? KeyboardToolbar._keyPressColor
                    : KeyboardToolbar._keyColor),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Icon(
            listening ? Icons.mic : Icons.mic_none_outlined,
            color: listening ? Colors.white : Colors.white70,
            size: KeyboardToolbar._iconSize,
          ),
        ),
      ),
    );
  }
}
