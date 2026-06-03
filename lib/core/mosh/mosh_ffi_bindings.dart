import 'dart:ffi';

import 'package:ffi/ffi.dart';

typedef MoshClientPtr = Pointer<Void>;

// C function signatures
typedef MoshClientCreateNative = Pointer<Void> Function(
    Pointer<Utf8> host, Int32 port, Pointer<Utf8> key, Int32 w, Int32 h);
typedef MoshClientStartNative = Int32 Function(Pointer<Void> client);
typedef MoshClientSendInputNative = Void Function(
    Pointer<Void> client, Pointer<Uint8> data, Int32 len);
typedef MoshClientReceiveOutputNative = Int32 Function(
    Pointer<Void> client, Pointer<Uint8> buf, Int32 maxLen);
typedef MoshClientResizeNative = Void Function(
    Pointer<Void> client, Int32 width, Int32 height);
typedef MoshClientGetStateNative = Int32 Function(Pointer<Void> client);
typedef MoshClientGetRttNative = Int32 Function(Pointer<Void> client);
typedef MoshClientGetLastHeardNative = Int64 Function(Pointer<Void> client);
typedef MoshClientStopNative = Void Function(Pointer<Void> client);
typedef MoshClientDestroyNative = Void Function(Pointer<Void> client);

// Dart function signatures
typedef MoshClientCreateDart = Pointer<Void> Function(
    Pointer<Utf8> host, int port, Pointer<Utf8> key, int w, int h);
typedef MoshClientStartDart = int Function(Pointer<Void> client);
typedef MoshClientSendInputDart = void Function(
    Pointer<Void> client, Pointer<Uint8> data, int len);
typedef MoshClientReceiveOutputDart = int Function(
    Pointer<Void> client, Pointer<Uint8> buf, int maxLen);
typedef MoshClientResizeDart = void Function(
    Pointer<Void> client, int width, int height);
typedef MoshClientGetStateDart = int Function(Pointer<Void> client);
typedef MoshClientGetRttDart = int Function(Pointer<Void> client);
typedef MoshClientGetLastHeardDart = int Function(Pointer<Void> client);
typedef MoshClientStopDart = void Function(Pointer<Void> client);
typedef MoshClientDestroyDart = void Function(Pointer<Void> client);

class MoshFfiBindings {
  static final _lib = DynamicLibrary.process();

  static final moshClientCreate =
      _lib.lookupFunction<MoshClientCreateNative, MoshClientCreateDart>(
          'mosh_client_create');

  static final moshClientStart =
      _lib.lookupFunction<MoshClientStartNative, MoshClientStartDart>(
          'mosh_client_start');

  static final moshClientSendInput =
      _lib.lookupFunction<MoshClientSendInputNative, MoshClientSendInputDart>(
          'mosh_client_send_input');

  static final moshClientReceiveOutput = _lib.lookupFunction<
      MoshClientReceiveOutputNative,
      MoshClientReceiveOutputDart>('mosh_client_receive_output');

  static final moshClientResize =
      _lib.lookupFunction<MoshClientResizeNative, MoshClientResizeDart>(
          'mosh_client_resize');

  static final moshClientGetState =
      _lib.lookupFunction<MoshClientGetStateNative, MoshClientGetStateDart>(
          'mosh_client_get_state');

  static final moshClientGetRtt =
      _lib.lookupFunction<MoshClientGetRttNative, MoshClientGetRttDart>(
          'mosh_client_get_rtt');

  static final moshClientGetLastHeard = _lib.lookupFunction<
      MoshClientGetLastHeardNative,
      MoshClientGetLastHeardDart>('mosh_client_get_last_heard');

  static final moshClientStop =
      _lib.lookupFunction<MoshClientStopNative, MoshClientStopDart>(
          'mosh_client_stop');

  static final moshClientDestroy =
      _lib.lookupFunction<MoshClientDestroyNative, MoshClientDestroyDart>(
          'mosh_client_destroy');
}
