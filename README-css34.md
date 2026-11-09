# Socket 3.0.2 for CS:S v34 on SourceMod 1.13

Fork of [JoinedSenses/sm-ext-socket](https://github.com/JoinedSenses/sm-ext-socket) with a build for
CS:S v34 servers on SourceMod 1.13 ([fmu1337/sourcemod-css34](https://github.com/fmu1337/sourcemod-css34)).
It keeps the legacy natives (`SocketCreate`, `SocketConnect`, ...). The upstream code is not changed. Only
the build is new (`ci/build.sh`, `.github/workflows/css34.yml`, run in manylinux2014_i686, GCC 10.2.1,
glibc 2.17), and it changes a copy of the sources:
- `sdk/smsdk_ext.*` are taken from SourceMod 1.13, so the extension API matches. The upstream copies are too old: "Extension version is too old to load".
- boost thread/mutex types become C++17 `std::` types. asio stays header-only (boost 1.83.0).

Only `GetSMExtAPI` is exported, and libstdc++/libgcc are linked statically.
A `v*-css34` tag publishes `socket-<ver>-sm13-css34-linux.tar.gz` and `socket.ext.so`.
Servers on SourceMod 1.7.3 keep the old Socket 3.0.1.
