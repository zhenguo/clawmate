import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class KeyboardToolbar extends StatelessWidget {
  final bool ctrlActive;
  final VoidCallback onCtrlToggle;
  final ValueChanged<String> onKeyTap;
  final VoidCallback? onHideKeyboard;
  final ValueChanged<String>? onPaste;
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
    this.onCopyTerminal,
    this.isListening = false,
    this.onVoiceToggle,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 44,
      color: Colors.grey[900],
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            _buildKey('📄', () => onCopyTerminal?.call()),
            _buildKey('Esc', () => onKeyTap('\x1b')),
            _buildKey('/', () => onKeyTap('/')),
            _buildKey('↑', () => onKeyTap('\x1b[A')),
            _buildKey('↓', () => onKeyTap('\x1b[B')),
            _buildKey('⏎', () => onKeyTap('\r')),
            _buildKey('|', () => onKeyTap('|')),
            _buildKey('~', () => onKeyTap('~')),
            _buildKey('⌫', () => onKeyTap('\x7f')),
            _buildKey('📋', () async {
              final data = await Clipboard.getData(Clipboard.kTextPlain);
              if (data?.text != null && data!.text!.isNotEmpty) {
                onPaste?.call(data.text!);
              }
            }),
            _buildVoice(),
            _buildKey('⌨↓', () => onHideKeyboard?.call()),
          ],
        ),
      ),
    );
  }

  Widget _buildKey(String label, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 44,
        alignment: Alignment.center,
        margin: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
        decoration: BoxDecoration(
          color: Colors.grey[800],
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(
          label,
          style: const TextStyle(color: Colors.white, fontSize: 14),
        ),
      ),
    );
  }

  Widget _buildCtrl() {
    return GestureDetector(
      onTap: onCtrlToggle,
      child: Container(
        width: 44,
        alignment: Alignment.center,
        margin: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
        decoration: BoxDecoration(
          color: ctrlActive ? Colors.blue : Colors.grey[800],
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(
          'Ctrl',
          style: TextStyle(
            color: Colors.white,
            fontSize: 14,
            fontWeight: ctrlActive ? FontWeight.bold : FontWeight.normal,
          ),
        ),
      ),
    );
  }

  Widget _buildVoice() {
    return GestureDetector(
      onTap: onVoiceToggle,
      child: Container(
        width: 44,
        alignment: Alignment.center,
        margin: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
        decoration: BoxDecoration(
          color: isListening ? Colors.red : Colors.grey[800],
          borderRadius: BorderRadius.circular(4),
        ),
        child: Icon(
          isListening ? Icons.mic : Icons.mic_none,
          color: Colors.white,
          size: 18,
        ),
      ),
    );
  }
}
