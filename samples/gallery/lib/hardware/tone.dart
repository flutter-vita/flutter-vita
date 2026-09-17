// A sine, as a WAV in memory, for audioplayers' BytesSource. The speaker
// check plays it; the microphone check looks for it in the recording.

import 'dart:math' as math;
import 'dart:typed_data';

/// [ms] of a sine at [hz], PCM16 stereo at [rate], with a 10 ms fade at
/// both ends so the speaker does not click. 48 kHz is what the console's
/// main port takes, so a 48 kHz file goes out as it is.
Uint8List makeToneWav(
  int hz,
  int ms, {
  int rate = 48000,
  int amp = 24000,
}) {
  final frames = rate * ms ~/ 1000;
  final fade = rate ~/ 100;
  final data = ByteData(44 + frames * 4);
  void ascii(int at, String s) {
    for (var i = 0; i < s.length; i++) {
      data.setUint8(at + i, s.codeUnitAt(i));
    }
  }

  ascii(0, 'RIFF');
  data.setUint32(4, 36 + frames * 4, Endian.little);
  ascii(8, 'WAVEfmt ');
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little); // PCM
  data.setUint16(22, 2, Endian.little); // stereo
  data.setUint32(24, rate, Endian.little);
  data.setUint32(28, rate * 4, Endian.little);
  data.setUint16(32, 4, Endian.little);
  data.setUint16(34, 16, Endian.little);
  ascii(36, 'data');
  data.setUint32(40, frames * 4, Endian.little);
  for (var n = 0; n < frames; n++) {
    var env = 1.0;
    if (n < fade) env = n / fade;
    if (n > frames - fade) env = (frames - n) / fade;
    final v = (math.sin(2 * math.pi * hz * n / rate) * amp * env).round();
    data.setInt16(44 + n * 4, v, Endian.little);
    data.setInt16(46 + n * 4, v, Endian.little);
  }
  return data.buffer.asUint8List();
}
