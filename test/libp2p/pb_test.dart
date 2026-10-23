import 'dart:typed_data';

import 'package:dart_libp2p_webrtc/src/libp2p/pb.dart';
import 'package:test/test.dart';

void main() {
  group('StreamFrame', () {
    test('round-trips flag and payload through the length-prefixed decoder', () {
      final frames = [
        StreamFrame(message: Uint8List.fromList([1, 2, 3])),
        const StreamFrame(flag: FrameFlag.fin),
        StreamFrame(flag: FrameFlag.finAck, message: Uint8List(0)),
        StreamFrame(message: Uint8List(maxFramePayload)),
      ];
      final decoder = LengthPrefixedDecoder();
      final decoded = [
        for (final f in frames) ...decoder.add(f.encodeWithLength()).map(StreamFrame.decode),
      ];
      expect(decoded.map((f) => f.flag), [null, FrameFlag.fin, FrameFlag.finAck, null]);
      expect(decoded[0].message, [1, 2, 3]);
      expect(decoded[3].message, hasLength(maxFramePayload));
    });

    test('a full-size data frame fits the 16 KiB limit', () {
      final encoded = StreamFrame(message: Uint8List(maxFramePayload)).encodeWithLength();
      expect(encoded.length, lessThanOrEqualTo(maxFrameSize));
    });

    test('decoder handles frames split across and packed into chunks', () {
      final a = StreamFrame(message: Uint8List.fromList(List.generate(300, (i) => i & 255))).encodeWithLength();
      final b = const StreamFrame(flag: FrameFlag.fin).encodeWithLength();
      final all = Uint8List.fromList([...a, ...b]);
      final decoder = LengthPrefixedDecoder();
      final out = <StreamFrame>[];
      for (var i = 0; i < all.length; i += 7) {
        out.addAll(decoder.add(Uint8List.sublistView(all, i, i + 7 > all.length ? all.length : i + 7)).map(StreamFrame.decode));
      }
      expect(out, hasLength(2));
      expect(out[0].message, hasLength(300));
      expect(out[1].flag, FrameFlag.fin);
    });

    test('rejects oversized frames', () {
      final decoder = LengthPrefixedDecoder();
      expect(() => decoder.add(encodeVarint(maxFrameSize + 1)), throwsFormatException);
    });
  });

  group('SignalingMessage', () {
    test('always encodes the type, including SDP_OFFER (0)', () {
      final bytes = const SignalingMessage(SignalingType.sdpOffer, 'v=0').encode();
      expect(bytes.take(2), [0x08, 0x00]);
      final decoded = SignalingMessage.decode(bytes);
      expect(decoded.type, SignalingType.sdpOffer);
      expect(decoded.data, 'v=0');
    });

    test('round-trips candidates', () {
      const json = '{"candidate":"candidate:1 1 UDP 1 1.2.3.4 5 typ host","sdpMid":"0"}';
      final decoded = SignalingMessage.decode(const SignalingMessage(SignalingType.iceCandidate, json).encode());
      expect(decoded.type, SignalingType.iceCandidate);
      expect(decoded.data, json);
    });
  });
}
