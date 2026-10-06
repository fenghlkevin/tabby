# Axon SSH dependency patches

These sources are vendored from the pinned dependencies used by Axon 0.10.0:

- Citadel: `ae8562f895de06ccb86fdb1cbb65fd99c8976e12` (https://github.com/orlandos-nl/Citadel)
- Wellz26/swift-nio-ssh 0.3.7: `d88989f3d3bb1dfb2a38ce4af598afbf7fc3095c` (https://github.com/Wellz26/swift-nio-ssh)

Original license and contributor files are preserved; license files are included in packaged ThirdPartyNotices. The application depends on these local packages; other dependencies remain pinned in Package.resolved. Tests for Axon changes live in native/Tests/TabbyNativeTests/SSHCompatibilityTests.swift, using an isolated loopback OpenSSH fixture (native/scripts/test-openssh.py).

Changes: distinct RSA key encoding and SHA2 authentication algorithms; SHA-512/SHA-256 signature verification and signing; RSA certificate encoding; certified authentication payload algorithm preservation; multi-attempt custom authentication delegates; configured host CA validation plumbing; OpenSSH Agent channel/request messages and an opt-in inbound handler hook. Agent identity allowlisting and request validation are owned by Axon, not enabled globally by the library.

When updating upstream, reapply these changes and run both SHA2-only servers, user/host certificates including rejection cases, selected-identity forwarding including a second-hop login, and the native regression suite. Do not edit .build/checkouts to maintain these changes.
