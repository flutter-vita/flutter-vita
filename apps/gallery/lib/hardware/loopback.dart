// The speaker-to-microphone loopback: does a tone the speaker plays come
// back through the microphone?
//
// The console records for two seconds; the speaker plays one second of a
// 1 kHz sine, starting half a second in. The recording is cut into 100 ms
// blocks and each block is measured twice: its power at 1 kHz (Goertzel, one
// bin of a DFT, at the tone's frequency) and its total power. The quietest
// blocks are the room; the loudest run of blocks should be the tone. The
// verdict is the ratio between the two at 1 kHz, in dB, and how many blocks
// the tone lasted. Nobody has to listen.
//
// What the numbers separate:
//   every sample zero          the microphone is off (the console's switch)
//   room noise, no tone        the speaker is silent, or the volume is down
//   tone well above the room   both work, and the path between them
//
// On the console the tone reads +70 dB over the room (build 56). Builds 46
// to 55 read nothing at 1 kHz: the two hardware calls ran one after the
// other, the platform thread waiting on each, and the tone played after the
// recording had ended. The calls answer from their own threads now.

import 'dart:math' as math;
import 'dart:typed_data';

class LoopbackResult {
  const LoopbackResult({
    required this.sampleRate,
    required this.samples,
    required this.peak,
    required this.blocks,
    required this.toneBlocks,
    required this.snrDb,
    required this.toneShare,
  });

  final int sampleRate;
  final int samples;
  final int peak;

  /// Blocks of 100 ms in the recording.
  final int blocks;

  /// Consecutive blocks whose power at the tone's frequency stands more
  /// than 10 dB over the quiet blocks: the tone's length, in tenths.
  final int toneBlocks;

  /// Power at the tone's frequency, loud blocks over quiet blocks, in dB.
  final double snrDb;

  /// Of the loud blocks' total power, the share at the tone's frequency.
  /// A clean sine through a small speaker still keeps most of it.
  final double toneShare;

  bool get silent => peak == 0;
  bool get heard => toneBlocks >= 5 && snrDb >= 10;
}

/// Reads a canonical PCM16 mono WAV and measures it for [hz].
LoopbackResult analyzeLoopback(Uint8List wav, {required int hz}) {
  final bd = ByteData.sublistView(wav);
  // 44-byte header: "RIFF" size "WAVE" "fmt " 16 tag ch rate ... "data" n.
  final sampleRate = bd.getUint32(24, Endian.little);
  final dataBytes = bd.getUint32(40, Endian.little);
  final n = math.min(dataBytes ~/ 2, (wav.length - 44) ~/ 2);
  final pcm = Int16List(n);
  var peak = 0;
  for (var i = 0; i < n; i++) {
    final v = bd.getInt16(44 + i * 2, Endian.little);
    pcm[i] = v;
    if (v.abs() > peak) peak = v.abs();
  }

  final blockLen = sampleRate ~/ 10;
  final blocks = n ~/ blockLen;
  final band = List<double>.filled(blocks, 0);
  final total = List<double>.filled(blocks, 0);
  // Goertzel: the bin nearest hz in a blockLen-point DFT.
  final k = (0.5 + blockLen * hz / sampleRate).floor();
  final w = 2 * math.pi * k / blockLen;
  final coeff = 2 * math.cos(w);
  for (var b = 0; b < blocks; b++) {
    double s1 = 0, s2 = 0, sq = 0;
    for (var i = 0; i < blockLen; i++) {
      final x = pcm[b * blockLen + i].toDouble();
      final s = x + coeff * s1 - s2;
      s2 = s1;
      s1 = s;
      sq += x * x;
    }
    // Scaled so a full-block sine at hz reads as its mean square: the
    // share below is then 1.0 for a pure tone.
    band[b] = 2 * (s1 * s1 + s2 * s2 - coeff * s1 * s2) / (blockLen * blockLen);
    total[b] = sq / blockLen;
  }

  // Quiet: the lower third of the blocks by band power. Loud: the longest
  // run of blocks more than 10 dB over the quiet mean.
  final sorted = List<double>.of(band)..sort();
  final quietCount = math.max(1, blocks ~/ 3);
  var quiet = 0.0;
  for (var i = 0; i < quietCount; i++) {
    quiet += sorted[i];
  }
  quiet /= quietCount;
  if (quiet < 1e-3) quiet = 1e-3; // an all-zero recording
  var bestRun = 0, bestStart = 0, run = 0;
  for (var b = 0; b < blocks; b++) {
    if (band[b] > quiet * 10) {
      run++;
      if (run > bestRun) {
        bestRun = run;
        bestStart = b - run + 1;
      }
    } else {
      run = 0;
    }
  }
  var loudBand = 0.0, loudTotal = 0.0;
  for (var b = bestStart; b < bestStart + bestRun; b++) {
    loudBand += band[b];
    loudTotal += total[b];
  }
  final snrDb = bestRun == 0
      ? 0.0
      : 10 * math.log(loudBand / bestRun / quiet) / math.ln10;
  final share = loudTotal > 0 ? loudBand / loudTotal : 0.0;
  return LoopbackResult(
    sampleRate: sampleRate,
    samples: n,
    peak: peak,
    blocks: blocks,
    toneBlocks: bestRun,
    snrDb: snrDb,
    toneShare: share,
  );
}

/// For a sound that is not one tone (the mp3): the loudest run of 100 ms
/// blocks against the quiet third, on total power, in dB.
double levelRiseDb(Uint8List wav) {
  final bd = ByteData.sublistView(wav);
  final sampleRate = bd.getUint32(24, Endian.little);
  final dataBytes = bd.getUint32(40, Endian.little);
  final n = math.min(dataBytes ~/ 2, (wav.length - 44) ~/ 2);
  final blockLen = sampleRate ~/ 10;
  final blocks = n ~/ blockLen;
  if (blocks == 0) return 0;
  final total = List<double>.filled(blocks, 0);
  for (var b = 0; b < blocks; b++) {
    var sq = 0.0;
    for (var i = 0; i < blockLen; i++) {
      final x = bd.getInt16(44 + (b * blockLen + i) * 2, Endian.little);
      sq += x.toDouble() * x;
    }
    total[b] = sq / blockLen;
  }
  final sorted = List<double>.of(total)..sort();
  final quietCount = math.max(1, blocks ~/ 3);
  var quiet = 0.0;
  for (var i = 0; i < quietCount; i++) {
    quiet += sorted[i];
  }
  quiet /= quietCount;
  if (quiet < 1e-3) quiet = 1e-3;
  final loud = sorted[blocks - 1];
  // A muted microphone gives loud = 0, and log(0) is not a number JSON
  // can hold: the result file went unwritten on build 53 over it.
  if (loud <= 0) return 0;
  return 10 * math.log(loud / quiet) / math.ln10;
}
