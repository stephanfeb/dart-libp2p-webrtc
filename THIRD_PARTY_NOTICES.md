# Third-party notices

The package ships these sources unmodified under `third_party/` and builds
them into its native library (`libdatachannel`, data channels only). Each
keeps its own license; the full texts are in the directories listed.

| Component | Version | License | Location |
|---|---|---|---|
| [libdatachannel](https://github.com/paullouisageneau/libdatachannel) | v0.24.6 | MPL-2.0 | `third_party/libdatachannel/LICENSE` |
| [libjuice](https://github.com/paullouisageneau/libjuice) (ICE) | as pinned by libdatachannel | MPL-2.0 | `third_party/libdatachannel/deps/libjuice/LICENSE` |
| [usrsctp](https://github.com/sctplab/usrsctp) (SCTP) | as pinned by libdatachannel | BSD-3-Clause | `third_party/libdatachannel/deps/usrsctp/LICENSE.md` |
| [plog](https://github.com/SergiusTheBest/plog) (logging) | as pinned by libdatachannel | MIT | `third_party/libdatachannel/deps/plog/LICENSE` |
| [Mbed TLS](https://github.com/Mbed-TLS/mbedtls) (DTLS) | 3.6.7 | Apache-2.0 OR GPL-2.0-or-later (used under Apache-2.0) | `third_party/mbedtls/LICENSE` |

MPL-2.0 is a file-level copyleft: the source of those files, including any
changes to them, must stay available. This package distributes them as
source and does not modify them.
