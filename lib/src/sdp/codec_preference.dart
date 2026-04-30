/// SDP codec-preference munger.
///
/// Переупорядочивает payload-types в `m=audio` строке так, чтобы кодеки из
/// [preferred] оказались первыми (в порядке списка), а остальные — после
/// (в исходном порядке). Кодеки которые не присутствуют в SDP-offer'е
/// libwebrtc/браузера — просто игнорируются: форсить кодек, которого
/// нет в системе, мы не можем.
///
/// Это **только reorder, не filter** — все исходные кодеки остаются в SDP
/// как fallback. Обе стороны выбирают первый общий, поэтому если поднять
/// `PCMA` на первое место — обе пиры на нём и сойдутся.
///
/// Используется в [RTCSession.createLocalDescription] поверх любых
/// пользовательских [modifiers]. Управляется через
/// `Settings.preferredAudioCodecs` (см. `config.dart`).

/// Reorders audio payload-types in [sdp] by [preferred] codec list.
///
/// [preferred] — list of codec names as they appear in `a=rtpmap` (case-
/// insensitive). E.g. `['PCMA', 'opus', 'G722']`.
///
/// Returns munged SDP; if [preferred] is empty or no `m=audio` line found —
/// returns [sdp] unchanged.
///
/// Algorithm:
/// 1. Parse all `a=rtpmap:N codec/...` to build `codec → [payload-types]` map.
/// 2. Find `m=audio PORT PROTO PT1 PT2 ...` line.
/// 3. Build new PT order: first PTs of codecs from [preferred] (in the order
///    they appear in the list), then the remaining PTs (in original order).
/// 4. Replace the PT list, leave everything else untouched.
String preferAudioCodecs(String sdp, List<String> preferred) {
  if (preferred.isEmpty) return sdp;
  if (!sdp.contains('m=audio')) return sdp;

  // Detect line ending — SDP must use CRLF, but be defensive.
  final eol = sdp.contains('\r\n') ? '\r\n' : '\n';
  final lines = sdp.split(eol);

  // 1. Build codec → payload-types map (uppercase keys for case-insensitive
  // matching).
  final codecToPts = <String, List<String>>{};
  final rtpmapRe = RegExp(r'^a=rtpmap:(\d+)\s+([^/]+)/');
  for (final l in lines) {
    final m = rtpmapRe.firstMatch(l);
    if (m == null) continue;
    final pt = m.group(1)!;
    final codec = m.group(2)!.toUpperCase();
    codecToPts.putIfAbsent(codec, () => <String>[]).add(pt);
  }
  if (codecToPts.isEmpty) return sdp;

  // 2. Find m=audio line and reorder.
  // Format: "m=audio <port> <proto> <pt1> <pt2> ..."
  final audioMRe = RegExp(r'^(m=audio\s+\S+\s+\S+)\s+(.+)$');
  bool replaced = false;
  final out = <String>[];
  for (final l in lines) {
    if (replaced) {
      out.add(l);
      continue;
    }
    final m = audioMRe.firstMatch(l);
    if (m == null) {
      out.add(l);
      continue;
    }
    final prefix = m.group(1)!;
    final originalPts = m.group(2)!.split(RegExp(r'\s+'));

    // 3. Build preferred PT list (in order of preferred codec list).
    final preferredPts = <String>[];
    for (final codec in preferred) {
      final cu = codec.toUpperCase();
      final pts = codecToPts[cu];
      if (pts == null) continue;
      for (final pt in pts) {
        if (originalPts.contains(pt) && !preferredPts.contains(pt)) {
          preferredPts.add(pt);
        }
      }
    }

    // 4. Append the rest in original order.
    final ordered = <String>[...preferredPts];
    for (final pt in originalPts) {
      if (!ordered.contains(pt)) ordered.add(pt);
    }

    out.add('$prefix ${ordered.join(' ')}');
    replaced = true; // only first m=audio line.
  }
  return out.join(eol);
}
