// record on the Vita: the microphone through SceAudioIn.
//
// A recorder is two threads. One reads the RAW port, 16 kHz mono, 256
// samples a grain (16 ms); sceAudioInInput blocks for each grain, which is
// the clock, and every grain goes into a four-second ring. The other, when
// there is a file, drains the ring to it every 100 ms; the Dart side drains
// the same ring through `read` for a stream. The reader does nothing else:
// on gallery build 60 it wrote each grain to the card itself, the writes
// took longer than a grain now and then, and the port dropped a third of
// the samples while it waited. The RAW port: the VOICE port opened and gave
// zeros with the status word reading "muted" (gallery build 45); the voice
// port is the one sceVoice feeds.
//
// Methods, all with `id`: start {path, wav, stream}, stop, pause, resume,
// cancel, dispose, state, amplitude, read (the stream's next bytes as
// base64), and `muted` without an id: the console's own microphone switch.
//
// Four recorders at most; the console has one microphone, and the port is
// opened once per recorder, so a second recorder while one runs fails at
// sceAudioInOpenPort with the port busy.
#include <fvita_plugin.h>

#include <psp2/audioin.h>
#include <psp2/io/fcntl.h>
#include <psp2/kernel/processmgr.h>
#include <psp2/kernel/threadmgr.h>

#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

enum { kRate = 16000, kGrain = 256, kRecorders = 4, kRing = kRate * 4 };
enum { kIdle, kRecording, kPaused, kStopping };

typedef struct Recorder {
  char id[40];
  volatile int state;
  SceUID thread;
  int port;
  // The file, when there is one.
  SceUID fd;
  char path[192];
  int wav;
  uint32_t data_bytes;
  // The ring: written by the reader, drained by the writer (file_r) and by
  // `read` (ring_r). Sample counts, unbounded; taken modulo kRing.
  int16_t* ring;
  volatile uint32_t ring_w, ring_r, file_r;
  SceUID writer;
  int stream;
  // For `amplitude`: the loudest sample of the last grains (decaying) and
  // of the whole recording.
  volatile int peak_now, peak_max;
  volatile int err;
} Recorder;

static Recorder g_rec[kRecorders];
static SceUID g_lock = -1;

static void lock(void) {
  if (g_lock >= 0) sceKernelLockMutex(g_lock, 1, NULL);
}
static void unlock(void) {
  if (g_lock >= 0) sceKernelUnlockMutex(g_lock, 1);
}

static Recorder* find(const char* id, int create) {
  for (int i = 0; i < kRecorders; i++) {
    if (g_rec[i].id[0] && strcmp(g_rec[i].id, id) == 0) return &g_rec[i];
  }
  if (!create) return NULL;
  for (int i = 0; i < kRecorders; i++) {
    if (g_rec[i].id[0] == 0) {
      memset(&g_rec[i], 0, sizeof g_rec[i]);
      snprintf(g_rec[i].id, sizeof g_rec[i].id, "%s", id);
      g_rec[i].fd = -1;
      g_rec[i].port = -1;
      return &g_rec[i];
    }
  }
  return NULL;
}

static void write_wav_header(SceUID fd, uint32_t data_bytes) {
  uint8_t hdr[44];
  memcpy(hdr, "RIFF", 4);
  const uint32_t riff = 36 + data_bytes;
  memcpy(hdr + 4, &riff, 4);
  memcpy(hdr + 8, "WAVEfmt ", 8);
  const uint32_t fmt_len = 16, rate = kRate, byte_rate = kRate * 2;
  const uint16_t pcm_tag = 1, channels = 1, block = 2, bits = 16;
  memcpy(hdr + 16, &fmt_len, 4);
  memcpy(hdr + 20, &pcm_tag, 2);
  memcpy(hdr + 22, &channels, 2);
  memcpy(hdr + 24, &rate, 4);
  memcpy(hdr + 28, &byte_rate, 4);
  memcpy(hdr + 32, &block, 2);
  memcpy(hdr + 34, &bits, 2);
  memcpy(hdr + 36, "data", 4);
  memcpy(hdr + 40, &data_bytes, 4);
  sceIoLseek(fd, 0, SCE_SEEK_SET);
  sceIoWrite(fd, hdr, sizeof hdr);
}

static int rec_thread(SceSize args, void* argp) {
  (void)args;
  Recorder* r = *(Recorder**)argp;
  static int16_t buf[kRecorders][kGrain];
  int16_t* g = buf[r - g_rec];
  while (r->state != kStopping) {
    const int rc = sceAudioInInput(r->port, g);
    if (rc < 0) {
      r->err = rc;
      fvita_log("record", "%s: sceAudioInInput 0x%08X", r->id, (unsigned)rc);
      break;
    }
    if (r->state != kRecording) continue;  // paused: the grain is dropped
    int peak = 0;
    for (int i = 0; i < kGrain; i++) {
      const int v = abs(g[i]);
      if (v > peak) peak = v;
    }
    r->peak_now = peak > r->peak_now * 4 / 5 ? peak : r->peak_now * 4 / 5;
    if (peak > r->peak_max) r->peak_max = peak;
    for (int i = 0; i < kGrain; i++) r->ring[(r->ring_w + (uint32_t)i) % kRing] = g[i];
    __sync_synchronize();
    r->ring_w += kGrain;
  }
  return 0;
}

// Drains the ring to the file: what the reader added since the last pass,
// in one write, up to the ring's length.
static void drain_to_file(Recorder* r) {
  __sync_synchronize();
  uint32_t avail = r->ring_w - r->file_r;
  if (avail > kRing) {  // the card was slower than four seconds of audio
    r->file_r = r->ring_w - kRing;
    avail = kRing;
  }
  while (avail) {
    const uint32_t at = r->file_r % kRing;
    const uint32_t run = at + avail <= kRing ? avail : kRing - at;  // to the ring's end
    const int wrote = sceIoWrite(r->fd, r->ring + at, run * 2);
    if (wrote > 0) r->data_bytes += (uint32_t)wrote;
    if (wrote != (int)(run * 2)) {
      r->err = wrote < 0 ? wrote : -1;
      return;
    }
    r->file_r += run;
    avail -= run;
  }
}

static int writer_thread(SceSize args, void* argp) {
  (void)args;
  Recorder* r = *(Recorder**)argp;
  while (r->state != kStopping) {
    sceKernelDelayThread(100 * 1000);
    if (r->fd >= 0) drain_to_file(r);
  }
  return 0;
}

static int rec_start(Recorder* r, const char* path, int wav, int stream, char* out, size_t cap) {
  if (r->state != kIdle) return fvita_reply_err(out, cap, "state", "already recording", 0);
  r->port = sceAudioInOpenPort(SCE_AUDIO_IN_PORT_TYPE_RAW, kGrain, kRate, SCE_AUDIO_IN_PARAM_FORMAT_S16_MONO);
  if (r->port < 0) return fvita_reply_err(out, cap, "failed", "sceAudioInOpenPort", r->port);
  r->fd = -1;
  r->data_bytes = 0;
  r->peak_now = r->peak_max = 0;
  r->err = 0;
  r->wav = wav;
  r->path[0] = 0;
  if (path != NULL && path[0]) {
    snprintf(r->path, sizeof r->path, "%s", path);
    r->fd = sceIoOpen(path, SCE_O_WRONLY | SCE_O_CREAT | SCE_O_TRUNC, 0777);
    if (r->fd < 0) {
      const int e = r->fd;
      sceAudioInReleasePort(r->port);
      r->port = -1;
      return fvita_reply_err(out, cap, "failed", path, e);
    }
    if (wav) write_wav_header(r->fd, 0);  // patched at stop
  }
  free(r->ring);
  r->ring = calloc(kRing, sizeof(int16_t));
  r->ring_w = r->ring_r = r->file_r = 0;
  r->stream = stream;
  r->state = kRecording;
  // The reader at priority 96, above the app's threads (160 is the default):
  // a grain must never wait for anything.
  r->thread = r->ring == NULL ? -1 : sceKernelCreateThread("fvita-record", rec_thread, 0x60, 0x4000, 0, 0, NULL);
  r->writer = r->thread < 0 ? -1 : sceKernelCreateThread("fvita-record-w", writer_thread, 0x10000100, 0x4000, 0, 0, NULL);
  if (r->thread < 0 || r->writer < 0) {
    const int e = r->thread < 0 ? r->thread : r->writer;
    r->state = kIdle;
    if (r->thread >= 0) sceKernelDeleteThread(r->thread);
    if (r->fd >= 0) sceIoClose(r->fd);
    sceAudioInReleasePort(r->port);
    r->port = -1;
    free(r->ring);
    r->ring = NULL;
    return fvita_reply_err(out, cap, "failed", "sceKernelCreateThread", e);
  }
  sceKernelStartThread(r->thread, sizeof r, &r);
  sceKernelStartThread(r->writer, sizeof r, &r);
  fvita_log("record", "%s: started, %s%s, mic switch %s", r->id, r->path[0] ? r->path : "no file",
            stream ? ", stream" : "", sceAudioInGetStatus(SCE_AUDIO_IN_GETSTATUS_MUTE) ? "muted" : "on");
  return fvita_reply_ok(out, cap, "{\"rate\":%d,\"channels\":1,\"grain\":%d}", kRate, kGrain);
}

// Ends the thread and the port; the file stays unless `discard`.
static void rec_end(Recorder* r, int discard) {
  if (r->state == kIdle) return;
  r->state = kStopping;
  SceUInt timeout = 500 * 1000;
  sceKernelWaitThreadEnd(r->thread, NULL, &timeout);
  sceKernelDeleteThread(r->thread);
  timeout = 500 * 1000;
  sceKernelWaitThreadEnd(r->writer, NULL, &timeout);
  sceKernelDeleteThread(r->writer);
  if (r->port >= 0) sceAudioInReleasePort(r->port);
  r->port = -1;
  if (r->fd >= 0) {
    drain_to_file(r);  // the last hundred milliseconds
    if (r->wav) write_wav_header(r->fd, r->data_bytes);
    sceIoClose(r->fd);
    r->fd = -1;
    if (discard) sceIoRemove(r->path);
  }
  free(r->ring);
  r->ring = NULL;
  r->state = kIdle;
  fvita_log("record", "%s: stopped, %u bytes%s", r->id, r->data_bytes, discard ? ", discarded" : "");
}

static double dbfs(int peak) { return peak <= 0 ? -160.0 : 20.0 * log10(peak / 32768.0); }

static int handle(const char* method, const char* body, size_t len, char* out, size_t cap) {
  if (strcmp(method, "muted") == 0) {
    return fvita_reply_ok(out, cap, "%s", sceAudioInGetStatus(SCE_AUDIO_IN_GETSTATUS_MUTE) ? "true" : "false");
  }
  char id[40];
  if (fvita_json_str(body, len, "id", id, sizeof id) <= 0) return fvita_reply_err(out, cap, "args", "no id", 0);
  lock();
  int n;
  Recorder* r = find(id, strcmp(method, "start") == 0 || strcmp(method, "create") == 0);
  if (r == NULL) {
    n = strcmp(method, "dispose") == 0 ? fvita_reply_ok(out, cap, "null")
                                       : fvita_reply_err(out, cap, "state", "no such recorder", 0);
  } else if (strcmp(method, "create") == 0) {
    n = fvita_reply_ok(out, cap, "null");
  } else if (strcmp(method, "start") == 0) {
    char path[192] = "";
    fvita_json_str(body, len, "path", path, sizeof path);
    n = rec_start(r, path, fvita_json_bool(body, len, "wav", 1), fvita_json_bool(body, len, "stream", 0), out, cap);
  } else if (strcmp(method, "stop") == 0) {
    const int had_file = r->path[0] != 0;
    rec_end(r, 0);
    n = had_file ? fvita_reply_ok(out, cap, "{\"path\":\"%s\",\"bytes\":%u}", r->path, r->data_bytes)
                 : fvita_reply_ok(out, cap, "{\"path\":null,\"bytes\":%u}", r->data_bytes);
  } else if (strcmp(method, "cancel") == 0) {
    rec_end(r, 1);
    n = fvita_reply_ok(out, cap, "null");
  } else if (strcmp(method, "dispose") == 0) {
    rec_end(r, 0);
    r->id[0] = 0;
    n = fvita_reply_ok(out, cap, "null");
  } else if (strcmp(method, "pause") == 0) {
    if (r->state == kRecording) r->state = kPaused;
    n = fvita_reply_ok(out, cap, "null");
  } else if (strcmp(method, "resume") == 0) {
    if (r->state == kPaused) r->state = kRecording;
    n = fvita_reply_ok(out, cap, "null");
  } else if (strcmp(method, "state") == 0) {
    n = fvita_reply_ok(out, cap, "{\"state\":%d,\"err\":%d,\"bytes\":%u}", r->state, r->err, r->data_bytes);
  } else if (strcmp(method, "amplitude") == 0) {
    n = fvita_reply_ok(out, cap, "{\"current\":%.1f,\"max\":%.1f,\"peak\":%d}", dbfs(r->peak_now), dbfs(r->peak_max),
                       r->peak_max);
  } else if (strcmp(method, "read") == 0) {
    if (r->ring == NULL || !r->stream) {
      n = fvita_reply_err(out, cap, "state", "not streaming", 0);
    } else {
      // Everything since the last read, up to a second; base64 of PCM16.
      __sync_synchronize();
      uint32_t avail = r->ring_w - r->ring_r;
      if (avail > kRing) {  // the reader fell behind: the oldest samples are gone
        r->ring_r = r->ring_w - kRing;
        avail = kRing;
      }
      if (avail > kRate) avail = kRate;
      static int16_t chunk[kRate];
      for (uint32_t i = 0; i < avail; i++) chunk[i] = r->ring[(r->ring_r + i) % kRing];
      r->ring_r += avail;
      const size_t need = 4 * ((avail * 2 + 2) / 3) + 64;
      if (need > cap) {
        n = fvita_reply_err(out, cap, "failed", "reply buffer too small", 0);
      } else {
        n = snprintf(out, cap, "[{\"samples\":%u,\"pcm\":\"", (unsigned)avail);
        n += (int)fvita_base64_encode((const unsigned char*)chunk, avail * 2, out + n);
        n += snprintf(out + n, cap - (size_t)n, "\"}]");
      }
    }
  } else {
    n = fvita_reply_err(out, cap, "unknown", method, 0);
  }
  unlock();
  return n;
}

__attribute__((constructor)) static void reg(void) {
  g_lock = sceKernelCreateMutex("fvita-record", 0, 0, NULL);
  fvita_channel_register("vita/record", handle);
}
