# Builds libdatachannel through the Dart build hook and runs the tests on Linux.
#   docker build -f docker/linux-test.Dockerfile -t dart-libp2p-webrtc-test .
#   docker run --rm dart-libp2p-webrtc-test
FROM dart:3.11

RUN apt-get update \
 && apt-get install -y --no-install-recommends cmake ninja-build g++ \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /src
COPY pubspec.yaml pubspec.lock ./
RUN dart pub get
COPY . .
RUN dart pub get --offline
# Run the hook once at image build time so test runs start immediately.
RUN dart run tool/build_native.dart

CMD ["dart", "test", "-r", "expanded"]
