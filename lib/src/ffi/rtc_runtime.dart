import 'dart:ffi';

import 'package:ffi/ffi.dart';

import 'bindings.g.dart' as rtc;

typedef _IdCallback = Void Function(Int, Pointer<Void>);
typedef _IdStateCallback = Void Function(Int, UnsignedInt, Pointer<Void>);
typedef _PcChannelCallback = Void Function(Int, Int, Pointer<Void>);
typedef _IdErrorCallback = Void Function(Int, Pointer<Char>, Pointer<Void>);

/// Thrown when a libdatachannel call returns an error code.
class RtcException implements Exception {
  final String operation;
  final int code;

  RtcException(this.operation, this.code);

  @override
  String toString() => 'RtcException: $operation failed (${_codeName(code)})';

  static String _codeName(int code) => switch (code) {
        rtc.RTC_ERR_INVALID => 'RTC_ERR_INVALID',
        rtc.RTC_ERR_FAILURE => 'RTC_ERR_FAILURE',
        rtc.RTC_ERR_NOT_AVAIL => 'RTC_ERR_NOT_AVAIL',
        rtc.RTC_ERR_TOO_SMALL => 'RTC_ERR_TOO_SMALL',
        _ => '$code',
      };
}

/// Throws [RtcException] if [result] is a libdatachannel error code.
int check(String operation, int result) {
  if (result < 0) throw RtcException(operation, result);
  return result;
}

/// Reads a string from a libdatachannel getter that reports the size it
/// needs when called with a null buffer.
String readNativeString(int Function(Pointer<Char> buffer, int size) getter) {
  final size = check('string size', getter(nullptr, 0));
  return using((arena) {
    final buf = arena<Char>(size);
    check('string read', getter(buf, size));
    return buf.cast<Utf8>().toDartString();
  });
}

/// Native log level, matching `rtcLogLevel`.
enum RtcLogLevel { none, fatal, error, warning, info, debug, verbose }

/// Peer-connection event handlers for one pc id.
final class PcCallbacks {
  final void Function(int state) onStateChange;
  final void Function(int state) onGatheringStateChange;
  final void Function(int channel) onDataChannel;

  const PcCallbacks({
    required this.onStateChange,
    required this.onGatheringStateChange,
    required this.onDataChannel,
  });
}

/// Channel event handlers for one data channel id.
final class ChannelCallbacks {
  final void Function() onOpen;
  final void Function() onClosed;
  final void Function() onError;
  final void Function() onAvailable;
  final void Function() onBufferedAmountLow;

  const ChannelCallbacks({
    required this.onOpen,
    required this.onClosed,
    required this.onError,
    required this.onAvailable,
    required this.onBufferedAmountLow,
  });
}

/// Bridges libdatachannel's callback threads to this isolate.
///
/// libdatachannel calls back on its own threads, which Dart only accepts via
/// [NativeCallable.listener]. Those run after the native call has returned, so
/// any pointer argument is already dangling: every callback here reads only
/// its integer arguments, and the wrappers fetch data synchronously
/// afterwards (`rtcGetLocalDescription`, `rtcReceiveMessage`).
///
/// One callable per callback type is shared by every pc and channel and
/// dispatches on the id, so the number of callables stays fixed.
final class RtcRuntime {
  static final RtcRuntime instance = RtcRuntime._();

  final _pcs = <int, PcCallbacks>{};
  final _channels = <int, ChannelCallbacks>{};

  late final _stateChange = NativeCallable<_IdStateCallback>.listener(
      (int pc, int state, Pointer<Void> _) => _pcs[pc]?.onStateChange(state));
  late final _gatheringStateChange =
      NativeCallable<_IdStateCallback>.listener((int pc, int state, Pointer<Void> _) =>
          _pcs[pc]?.onGatheringStateChange(state));
  late final _dataChannel = NativeCallable<_PcChannelCallback>.listener(
      (int pc, int channel, Pointer<Void> _) => _pcs[pc]?.onDataChannel(channel));
  late final _open = NativeCallable<_IdCallback>.listener(
      (int id, Pointer<Void> _) => _channels[id]?.onOpen());
  late final _closed = NativeCallable<_IdCallback>.listener(
      (int id, Pointer<Void> _) => _channels[id]?.onClosed());
  // The error text is dangling by the time this runs; only the id is used.
  late final _error = NativeCallable<_IdErrorCallback>.listener(
      (int id, Pointer<Char> _, Pointer<Void> __) => _channels[id]?.onError());
  late final _available = NativeCallable<_IdCallback>.listener(
      (int id, Pointer<Void> _) => _channels[id]?.onAvailable());
  late final _bufferedAmountLow = NativeCallable<_IdCallback>.listener(
      (int id, Pointer<Void> _) => _channels[id]?.onBufferedAmountLow());

  late final List<NativeCallable<Function>> _callables = [
    _stateChange,
    _gatheringStateChange,
    _dataChannel,
    _open,
    _closed,
    _error,
    _available,
    _bufferedAmountLow,
  ];

  RtcRuntime._();

  /// Sends native logs at [level] and above to stdout. The C log callback
  /// carries a string, which can't be passed through a listener callback.
  static void enableNativeLogging(RtcLogLevel level) {
    rtc.rtcInitLogger(rtc.rtcLogLevel.fromValue(level.index), nullptr);
  }

  void registerPeerConnection(int pc, PcCallbacks callbacks) {
    _pcs[pc] = callbacks;
    _updateKeepAlive();
    check('rtcSetStateChangeCallback',
        rtc.rtcSetStateChangeCallback(pc, _stateChange.nativeFunction.cast()));
    check(
        'rtcSetGatheringStateChangeCallback',
        rtc.rtcSetGatheringStateChangeCallback(
            pc, _gatheringStateChange.nativeFunction.cast()));
    check('rtcSetDataChannelCallback',
        rtc.rtcSetDataChannelCallback(pc, _dataChannel.nativeFunction.cast()));
  }

  void unregisterPeerConnection(int pc) {
    _pcs.remove(pc);
    _updateKeepAlive();
  }

  void registerChannel(int id, ChannelCallbacks callbacks) {
    _channels[id] = callbacks;
    _updateKeepAlive();
    check('rtcSetOpenCallback', rtc.rtcSetOpenCallback(id, _open.nativeFunction));
    check('rtcSetClosedCallback', rtc.rtcSetClosedCallback(id, _closed.nativeFunction));
    check('rtcSetErrorCallback', rtc.rtcSetErrorCallback(id, _error.nativeFunction));
    check('rtcSetAvailableCallback',
        rtc.rtcSetAvailableCallback(id, _available.nativeFunction));
    check('rtcSetBufferedAmountLowCallback',
        rtc.rtcSetBufferedAmountLowCallback(id, _bufferedAmountLow.nativeFunction));
  }

  void unregisterChannel(int id) {
    _channels.remove(id);
    _updateKeepAlive();
  }

  /// Callbacks keep the isolate alive only while something is open, so a
  /// program that has closed everything can exit.
  void _updateKeepAlive() {
    final keepAlive = _pcs.isNotEmpty || _channels.isNotEmpty;
    for (final callable in _callables) {
      callable.keepIsolateAlive = keepAlive;
    }
  }
}
