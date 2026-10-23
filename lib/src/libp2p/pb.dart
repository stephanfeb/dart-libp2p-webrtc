// Wire formats from the libp2p WebRTC specs. Each message has two fields, so
// they are encoded by hand rather than with generated protobuf code.
import 'dart:convert';
import 'dart:typed_data';

/// Largest encoded stream frame, length prefix included (spec: 16 KiB).
const maxFrameSize = 16 * 1024;

/// Payload that always fits in one frame: [maxFrameSize] minus the length
/// prefix (2), flag field (2), and message tag + length (1 + 2).
const maxFramePayload = maxFrameSize - 7;

/// Signaling message type (`/webrtc-signaling/0.0.1`).
enum SignalingType { sdpOffer, sdpAnswer, iceCandidate }

/// `Message` from the `/webrtc-signaling/0.0.1` protocol (proto3).
class SignalingMessage {
  final SignalingType type;
  final String data;

  const SignalingMessage(this.type, this.data);

  Uint8List encode() {
    // `type` is declared `optional`, so it is always written, even as
    // SDP_OFFER (0): js-libp2p rejects an offer whose type is absent.
    final out = BytesBuilder(copy: false)
      ..addByte(0x08) // field 1, varint
      ..add(encodeVarint(type.index));
    final bytes = utf8.encode(data);
    out
      ..addByte(0x12) // field 2, length-delimited
      ..add(encodeVarint(bytes.length))
      ..add(bytes);
    return out.takeBytes();
  }

  static SignalingMessage decode(Uint8List bytes) {
    var type = 0;
    var data = '';
    for (final (field, value) in _fields(bytes)) {
      if (field == 1 && value is int) type = value;
      if (field == 2 && value is Uint8List) data = utf8.decode(value);
    }
    if (type >= SignalingType.values.length) {
      throw FormatException('unknown signaling message type $type');
    }
    return SignalingMessage(SignalingType.values[type], data);
  }

  @override
  String toString() => 'SignalingMessage(${type.name}, ${data.length} chars)';
}

/// Stream frame flag (`webrtc.pb.Message.Flag`).
enum FrameFlag { fin, stopSending, resetStream, finAck }

/// `webrtc.pb.Message` (proto2): an optional flag and optional payload.
class StreamFrame {
  final FrameFlag? flag;
  final Uint8List? message;

  const StreamFrame({this.flag, this.message});

  /// The frame with its varint length prefix, ready to send as one
  /// data-channel message.
  Uint8List encodeWithLength() {
    final body = BytesBuilder(copy: false);
    if (flag != null) {
      body
        ..addByte(0x08)
        ..add(encodeVarint(flag!.index));
    }
    if (message != null) {
      body
        ..addByte(0x12)
        ..add(encodeVarint(message!.length))
        ..add(message!);
    }
    final bytes = body.takeBytes();
    return (BytesBuilder(copy: false)
          ..add(encodeVarint(bytes.length))
          ..add(bytes))
        .takeBytes();
  }

  static StreamFrame decode(Uint8List bytes) {
    FrameFlag? flag;
    Uint8List? message;
    for (final (field, value) in _fields(bytes)) {
      if (field == 1 && value is int && value < FrameFlag.values.length) {
        flag = FrameFlag.values[value];
      }
      if (field == 2 && value is Uint8List) message = value;
    }
    return StreamFrame(flag: flag, message: message);
  }

  @override
  String toString() => 'StreamFrame(${flag?.name ?? '-'}, ${message?.length ?? 0} bytes)';
}

/// Splits a byte stream into varint-length-prefixed messages. Messages may
/// span or share data-channel messages, so input is buffered.
class LengthPrefixedDecoder {
  final int maxLength;
  Uint8List _buffer = Uint8List(0);

  LengthPrefixedDecoder({this.maxLength = maxFrameSize});

  /// Adds [chunk] and returns every message now complete.
  List<Uint8List> add(Uint8List chunk) {
    _buffer = _buffer.isEmpty ? chunk : (BytesBuilder(copy: false)..add(_buffer)..add(chunk)).takeBytes();
    final messages = <Uint8List>[];
    var offset = 0;
    while (true) {
      final prefix = tryDecodeVarint(_buffer, offset);
      if (prefix == null) break;
      final (length, prefixLength) = prefix;
      if (length > maxLength) throw FormatException('message of $length bytes exceeds $maxLength');
      final start = offset + prefixLength;
      if (_buffer.length < start + length) break;
      messages.add(Uint8List.sublistView(_buffer, start, start + length));
      offset = start + length;
    }
    _buffer = Uint8List.sublistView(_buffer, offset);
    return messages;
  }
}

Uint8List encodeVarint(int value) {
  if (value < 0) throw ArgumentError.value(value, 'value', 'must be non-negative');
  final out = <int>[];
  while (value >= 0x80) {
    out.add((value & 0x7f) | 0x80);
    value >>= 7;
  }
  out.add(value);
  return Uint8List.fromList(out);
}

/// (value, bytes consumed), or null if [bytes] ends mid-varint.
(int, int)? tryDecodeVarint(Uint8List bytes, [int offset = 0]) {
  var value = 0;
  var shift = 0;
  for (var i = offset; i < bytes.length; i++) {
    if (shift > 63) throw const FormatException('varint too long');
    final b = bytes[i];
    value |= (b & 0x7f) << shift;
    if (b < 0x80) return (value, i - offset + 1);
    shift += 7;
  }
  return null;
}

/// (field number, int for varints / bytes for length-delimited) pairs.
Iterable<(int, Object)> _fields(Uint8List bytes) sync* {
  var offset = 0;
  while (offset < bytes.length) {
    final (key, keyLength) = tryDecodeVarint(bytes, offset) ?? (throw const FormatException('truncated key'));
    offset += keyLength;
    final field = key >> 3;
    switch (key & 7) {
      case 0:
        final (value, n) = tryDecodeVarint(bytes, offset) ?? (throw const FormatException('truncated varint'));
        offset += n;
        yield (field, value);
      case 2:
        final (length, n) = tryDecodeVarint(bytes, offset) ?? (throw const FormatException('truncated length'));
        offset += n;
        if (offset + length > bytes.length) throw const FormatException('truncated field');
        yield (field, Uint8List.sublistView(bytes, offset, offset + length));
        offset += length;
      case 1:
        offset += 8; // fixed64, unused
      case 5:
        offset += 4; // fixed32, unused
      default:
        throw FormatException('unsupported wire type ${key & 7}');
    }
  }
}
