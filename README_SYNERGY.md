# Synergy fork of dart-sip-ua

- **Upstream:** [flutter-webrtc/dart-sip-ua](https://github.com/flutter-webrtc/dart-sip-ua)
- **Pub baseline:** `1.0.1` (lib mirrored from pub.dev)
- **Fork version:** `1.0.1+1` — see [CHANGELOG.md](CHANGELOG.md)

## Patch

`re-INVITE`: if `setRemoteDescription` fails, upstream already sends **SIP 488** but then throws
`Exceptions.TypeError` (extends `AssertionError`), which was **uncaught** in `_receiveReinvite`
(unlike `_receiveUpdate`). That crashed the Flutter app. We wrap
`await _processInDialogSdpOffer(request)` in **try/catch** and **return** after logging.

## Push to GitHub (replace remote if needed)

```bash
cd packages/sip_ua_fork
git remote -v
# If origin is not your fork:
# git remote set-url origin https://github.com/Vasily-van-Zaam/dart-sip-ua.git
git add -A
git commit -m "fix: do not crash on re-INVITE after setRemoteDescription failure (align with UPDATE)"
git push origin main
```

## Monorepo `client_apps`

Apps use **git** override (no `path`):

```yaml
dependency_overrides:
  sip_ua:
    git:
      url: https://github.com/Vasily-van-Zaam/dart-sip-ua.git
      ref: main   # or pin: ref: <commit_sha> / tag after you tag a release
```

For **local** edits before push, temporarily use `path: ../sip_ua_fork` (or this folder) instead of `git`.
