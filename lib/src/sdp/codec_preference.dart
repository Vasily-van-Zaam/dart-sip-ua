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

/// Restricts audio payload-types in [sdp] to only [allowed] codecs.
///
/// В отличие от [preferAudioCodecs] (только reorder, fallback'и остаются),
/// эта функция **удаляет** все аудио-кодеки кроме [allowed] из:
///   * списка PT в `m=audio` строке;
///   * атрибутов `a=rtpmap:N`, `a=rtcp-fb:N`, `a=fmtp:N` для удалённых PT.
///
/// Используется когда сервер ожидает «чистый» offer с одним кодеком и
/// ругается / падает на opus/G722/PCMU/etc в списке. Типично для PSTN-
/// gateway'ев настроенных под единственный G.711a (Россия).
///
/// Параметры:
///   * [allowed] — codec names как в `a=rtpmap` (case-insensitive).
///     Если пуст или ни один из allowed не присутствует в исходном SDP —
///     возвращаем исходный SDP без изменений (no-op safety: нельзя удалить
///     все кодеки сразу — сломали бы offer).
///   * [keepDtmf] — оставлять `telephone-event` payload-types с rate'ом,
///     совпадающим с rate'ом одного из [allowed]. По умолчанию `true` —
///     иначе сломается DTMF через RFC 2833 (например, spy whisper через
///     `sendDTMF`). При `dtmf_mode = INFO` можно ставить `false` для
///     получения SDP вида `m=audio … 8` (только PCMA).
///   * [keepCn] — оставлять `CN` (comfort noise). По умолчанию `false` —
///     CN редко требуется и большинство PSTN-gateway'ев игнорируют его.
String restrictAudioCodecs(
  String sdp,
  List<String> allowed, {
  bool keepDtmf = true,
  bool keepCn = false,
}) {
  if (allowed.isEmpty) return sdp;
  if (!sdp.contains('m=audio')) return sdp;

  final String eol = sdp.contains('\r\n') ? '\r\n' : '\n';
  final List<String> lines = sdp.split(eol);

  // 1. PT → (codec, rate). Пример: '8' → ('PCMA', '8000').
  final Map<String, String> ptToCodec = <String, String>{};
  final Map<String, String> ptToRate = <String, String>{};
  final RegExp rtpmapRe = RegExp(r'^a=rtpmap:(\d+)\s+([^/]+)/(\d+)');
  for (final String l in lines) {
    final RegExpMatch? m = rtpmapRe.firstMatch(l);
    if (m == null) continue;
    final String pt = m.group(1)!;
    ptToCodec[pt] = m.group(2)!.toUpperCase();
    ptToRate[pt] = m.group(3)!;
  }
  if (ptToCodec.isEmpty) return sdp;

  // 2. Какие PT оставляем.
  final Set<String> allowedUp =
      allowed.map((String c) => c.toUpperCase()).toSet();
  final Set<String> keepPts = <String>{};
  final Set<String> allowedRates = <String>{};
  ptToCodec.forEach((String pt, String codec) {
    if (allowedUp.contains(codec)) {
      keepPts.add(pt);
      final String? r = ptToRate[pt];
      if (r != null) allowedRates.add(r);
    }
  });

  // No-op safety: ни один allowed кодек не предложен libwebrtc — оставляем
  // SDP как есть, иначе мы убили бы все аудио-PT и сломали оффер.
  if (keepPts.isEmpty) return sdp;

  if (keepDtmf) {
    ptToCodec.forEach((String pt, String codec) {
      if (codec == 'TELEPHONE-EVENT' && allowedRates.contains(ptToRate[pt])) {
        keepPts.add(pt);
      }
    });
  }
  if (keepCn) {
    ptToCodec.forEach((String pt, String codec) {
      if (codec == 'CN' && allowedRates.contains(ptToRate[pt])) {
        keepPts.add(pt);
      }
    });
  }

  // 3. Фильтр m=audio + удаление a=rtpmap/rtcp-fb/fmtp для drop'нутых PT.
  final RegExp audioMRe = RegExp(r'^(m=audio\s+\S+\s+\S+)\s+(.+)$');
  final RegExp ptAttrRe = RegExp(r'^a=(rtpmap|rtcp-fb|fmtp):(\d+)');
  bool mAudioReplaced = false;
  final List<String> out = <String>[];
  for (final String l in lines) {
    if (!mAudioReplaced) {
      final RegExpMatch? m = audioMRe.firstMatch(l);
      if (m != null) {
        final List<String> originalPts = m.group(2)!.split(RegExp(r'\s+'));
        final List<String> filteredPts =
            originalPts.where(keepPts.contains).toList();
        if (filteredPts.isEmpty) {
          // Защита от рассогласования между rtpmap и m= (нестандартный
          // SDP) — оставляем исходную строку, не убиваем оффер.
          out.add(l);
        } else {
          out.add('${m.group(1)!} ${filteredPts.join(' ')}');
        }
        mAudioReplaced = true;
        continue;
      }
    }
    final RegExpMatch? ptM = ptAttrRe.firstMatch(l);
    if (ptM != null && !keepPts.contains(ptM.group(2))) {
      continue; // drop attribute for removed PT
    }
    out.add(l);
  }
  return out.join(eol);
}

/// Renumbers `telephone-event` payload-type to a fixed [targetPt].
///
/// libwebrtc выдаёт `telephone-event` с динамическими PT (обычно 110 для
/// 48000 и 126 для 8000). Многие PSTN-gateway'и (особенно legacy SIP-АТС)
/// **хардкодят PT 101** для DTMF и не negotiate'ят другой — RFC 4733 не
/// фиксирует значение, но 101 стал стандартом де-факто. Наш Dart-клиент
/// вычищает SDP до `m=audio … 8 126`, FreeSWITCH такое принимает и сам
/// negotiate'ит 126, но другие реализации могут не уметь.
///
/// Эта функция перенумеровывает единственный (после `restrictAudioCodecs`)
/// `telephone-event` PT в [targetPt]. Меняет в:
///   * списке PT в `m=audio` строке;
///   * `a=rtpmap:N`, `a=fmtp:N`, `a=rtcp-fb:N` для этого PT.
///
/// No-op safety:
///   * `targetPt == null` или `<= 0` — выходим.
///   * `telephone-event` в SDP отсутствует — выходим.
///   * Старый PT уже равен [targetPt] — выходим.
///   * [targetPt] уже занят другим кодеком в SDP — выходим (нельзя
///     создать collision, иначе сломали бы оффер).
///
/// Если несколько `telephone-event` (например, после restriction
/// keepDtmf=true оставлены оба rate) — переименовываем только первый
/// найденный с тем `rate`, который соответствует preferred codec'у.
/// Других trogeать не имеет смысла, потому что 101 — единый PT.
String normalizeDtmfPayloadType(String sdp, {int targetPt = 101}) {
  if (targetPt <= 0) return sdp;
  if (!sdp.contains('telephone-event')) return sdp;

  final String eol = sdp.contains('\r\n') ? '\r\n' : '\n';
  final List<String> lines = sdp.split(eol);

  // 1. Собираем PT всех кодеков (для проверки что target не занят) и
  // отдельно — PT именно telephone-event (всех его вариантов по rate).
  final Set<String> usedPts = <String>{};
  final List<String> dtmfPts = <String>[];
  final RegExp rtpmapRe = RegExp(r'^a=rtpmap:(\d+)\s+([^/]+)/');
  for (final String l in lines) {
    final RegExpMatch? m = rtpmapRe.firstMatch(l);
    if (m == null) continue;
    final String pt = m.group(1)!;
    final String codec = m.group(2)!.toUpperCase();
    usedPts.add(pt);
    if (codec == 'TELEPHONE-EVENT') dtmfPts.add(pt);
  }
  if (dtmfPts.isEmpty) return sdp;

  final String targetStr = '$targetPt';
  if (dtmfPts.contains(targetStr)) return sdp; // уже стандарт.
  if (usedPts.contains(targetStr)) return sdp; // collision — не трогаем.

  // 2. Перенумеровываем первый telephone-event PT (после restrict
  // обычно один). Меняем во всех местах: m=audio + a=rtpmap/fmtp/rtcp-fb.
  final String oldPt = dtmfPts.first;
  final RegExp audioMRe = RegExp(r'^(m=audio\s+\S+\s+\S+)\s+(.+)$');
  final RegExp ptAttrRe = RegExp(r'^a=(rtpmap|rtcp-fb|fmtp):(\d+)(\s.*)?$');

  final List<String> out = <String>[];
  bool mAudioReplaced = false;
  for (final String l in lines) {
    if (!mAudioReplaced) {
      final RegExpMatch? m = audioMRe.firstMatch(l);
      if (m != null) {
        final List<String> pts = m
            .group(2)!
            .split(RegExp(r'\s+'))
            .map((String pt) => pt == oldPt ? targetStr : pt)
            .toList();
        out.add('${m.group(1)!} ${pts.join(' ')}');
        mAudioReplaced = true;
        continue;
      }
    }
    final RegExpMatch? am = ptAttrRe.firstMatch(l);
    if (am != null && am.group(2) == oldPt) {
      final String tail = am.group(3) ?? '';
      out.add('a=${am.group(1)!}:$targetStr$tail');
      continue;
    }
    out.add(l);
  }
  return out.join(eol);
}
