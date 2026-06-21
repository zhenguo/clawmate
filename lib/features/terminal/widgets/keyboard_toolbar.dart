import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class KeyboardToolbar extends StatelessWidget {
  final bool ctrlActive;
  final VoidCallback onCtrlToggle;
  final ValueChanged<String> onKeyTap;
  final VoidCallback? onHideKeyboard;
  final ValueChanged<String>? onPaste;
  final VoidCallback? onPasteImage;
  final VoidCallback? onCopyTerminal;
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
  Widget build(BuildContext context) {
    return Container(
      height: 44,
      color: _bg,
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            _ToggleKey(
              label: 'Ctrl',
              active: ctrlActive,
              accentColor: _accentColor,
              onTap: onCtrlToggle,
            ),
            _IconKey(Icons.keyboard_tab, () => onKeyTap('\t'), tooltip: 'Tab'),
            _TextKey('Esc', () => onKeyTap('\x1b')),
            _TextKey('/', () => onKeyTap('/')),
            _IconKey(Icons.keyboard_arrow_up, () => onKeyTap('\x1b[A')),
            _IconKey(Icons.keyboard_arrow_down, () => onKeyTap('\x1b[B')),
            _IconKey(Icons.history, () => onKeyTap('\x02[')),
            _IconKey(Icons.keyboard_return, () => onKeyTap('\r')),
            _TextKey('|', () => onKeyTap('|')),
            _TextKey('~', () => onKeyTap('~')),
            _IconKey(Icons.backspace_outlined, () => onKeyTap('\x7f')),
            _IconKey(Icons.copy_outlined, () => onCopyTerminal?.call()),
            _IconKey(Icons.content_paste, () async {
              final data = await Clipboard.getData(Clipboard.kTextPlain);
              if (data?.text != null && data!.text!.isNotEmpty) {
                onPaste?.call(data.text!);
              }
            }),
            _IconKey(Icons.image_outlined, () => onPasteImage?.call()),
            _VoiceKey(
              isListening: isListening,
              onTap: onVoiceToggle,
            ),
            _IconKey(Icons.keyboard_hide_outlined, () => onHideKeyboard?.call()),
          ],
        ),
      ),
    );
  }
}

class _IconKey extends StatefulWidget {
  final IconData icon;
  final VoidCallback? onTap;
  final String? tooltip;

  const _IconKey(this.icon, this.onTap, {this.tooltip});

  @override
  State<_IconKey> createState() => _IconKeyState();
}

class _IconKeyState extends State<_IconKey> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) => setState(() => _pressed = false),
      onTapCancel: () => setState(() => _pressed = false),
      onTap: () {
        HapticFeedback.selectionClick();
        widget.onTap?.call();
      },
      child: Container(
        width: 40,
        height: 34,
        alignment: Alignment.center,
        margin: const EdgeInsets.symmetric(horizontal: 2),
        decoration: BoxDecoration(
          color: _pressed
              ? KeyboardToolbar._keyPressColor
              : KeyboardToolbar._keyColor,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Icon(
          widget.icon,
          color: _pressed ? Colors.white : Colors.white70,
          size: KeyboardToolbar._iconSize,
        ),
      ),
    );
  }
}

class _TextKey extends StatefulWidget {
  final String label;
  final VoidCallback onTap;

  const _TextKey(this.label, this.onTap);

  @override
  State<_TextKey> createState() => _TextKeyState();
}

class _TextKeyState extends State<_TextKey> {
  bool _pressed = false;

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
        width: 40,
        height: 34,
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

class _ToggleKeyState extends State<_ToggleKey> {
  bool _pressed = false;

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
      child: Container(
        width: 40,
        height: 34,
        alignment: Alignment.center,
        margin: const EdgeInsets.symmetric(horizontal: 2),
        decoration: BoxDecoration(
          color: active
              ? widget.accentColor.withOpacity(_pressed ? 0.9 : 0.7)
              : (_pressed
                  ? KeyboardToolbar._keyPressColor
                  : KeyboardToolbar._keyColor),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          widget.label,
          style: TextStyle(
            color: active ? Colors.black87 : Colors.white70,
            fontSize: 11,
            fontWeight: active ? FontWeight.w700 : FontWeight.w500,
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
      child: Container(
        width: 40,
        height: 34,
        alignment: Alignment.center,
        margin: const EdgeInsets.symmetric(horizontal: 2),
        decoration: BoxDecoration(
          color: listening
              ? const Color(0xFFFF3B30).withOpacity(_pressed ? 0.9 : 0.7)
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
    );
  }
}
