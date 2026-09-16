// audioplayers on the Vita.
//
// A player is a thread. Two kinds of source:
//
//   WAV, from bytes or a file: decoded here to 48 kHz stereo PCM16 in
//   memory, played through a MAIN port (48 kHz is the one rate that port
//   takes). Up to eight players at once; a game's sounds.
//
//   Anything else (AAC in an MP4 or M4A box is what the console's player
//   decodes; MP3 it refuses, 0x806A0002 from sceAvPlayerAddSource): the
//   system's sceAvPlayer, decoded frame by frame into a BGM port at the
//   file's own rate. There is one BGM port, so one such player plays at a
//   time; music.
//
// Commands from the Dart side are handed to the player's thread through
// `cmd` and acknowledged there, so sceAvPlayer is only ever called from
// the thread that owns it. The Dart side polls `poll` for the state, the
// position and event counters (prepared, complete, seek), and turns
// counter increments into audioplayers' events.
#include <fvita_plugin.h>

#include <psp2/appmgr.h>
#include <psp2/audioout.h>
#include <psp2/avplayer.h>
#include <psp2/io/dirent.h>
#include <psp2/io/fcntl.h>
#include <psp2/io/stat.h>
#include <psp2/kernel/processmgr.h>
#include <psp2/kernel/sysmem.h>
#include <psp2/kernel/threadmgr.h>
#include <psp2/sysmodule.h>

#include <malloc.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>

enum { kPlayers = 8, kRate = 48000, kGrain = 768 };  // 16 ms a grain
enum { kNone, kPcm, kAv };
enum { kIdle, kPrepared, kPlaying, kPaused, kCompleted };
enum { kCmdNone, kCmdPlay, kCmdPause, kCmdStop, kCmdSeek, kCmdRelease, kCmdQuit };
enum { kRelease, kLoop, kStopMode };

typedef struct Player {
  char id[40];
  SceUID thread;
  volatile int alive;
  volatile int state;
  volatile int cmd;
  volatile int cmd_arg;
  int kind;
  // pcm
  int16_t* pcm;  // stereo 48 kHz
  uint32_t frames;
  volatile uint32_t pos;  // frame index
  // av
  char path[256];
  SceAvPlayerHandle av;
  SceUID av_fd;
  uint64_t av_dur;
  volatile uint32_t av_pos_ms;
  // both
  volatile float volume, balance;
  volatile int gain_dirty;
  volatile int release_mode;
  int port;
  volatile unsigned ev_prepared, ev_complete, ev_seek;
  volatile int err;
  char err_what[64];
} Player;

static Player g_players[kPlayers];
static SceUID g_lock = -1;

static void lock(void) {
  if (g_lock >= 0) sceKernelLockMutex(g_lock, 1, NULL);
}
static void unlock(void) {
  if (g_lock >= 0) sceKernelUnlockMutex(g_lock, 1);
}

static Player* find(const char* id) {
  for (int i = 0; i < kPlayers; i++) {
    if (g_players[i].id[0] && strcmp(g_players[i].id, id) == 0) return &g_players[i];
  }
  return NULL;
}

// ---- gain ---------------------------------------------------------------------

static void apply_gain(Player* p) {
  if (p->port < 0) return;
  const float v = p->volume < 0 ? 0 : p->volume > 1 ? 1 : p->volume;
  const float b = p->balance < -1 ? -1 : p->balance > 1 ? 1 : p->balance;
  int vol[2] = {(int)(SCE_AUDIO_OUT_MAX_VOL * v * (b > 0 ? 1 - b : 1)),
                (int)(SCE_AUDIO_OUT_MAX_VOL * v * (b < 0 ? 1 + b : 1))};
  sceAudioOutSetVolume(p->port, SCE_AUDIO_VOLUME_FLAG_L_CH | SCE_AUDIO_VOLUME_FLAG_R_CH, vol);
  p->gain_dirty = 0;
}

// ---- WAV -----------------------------------------------------------------------

// RIFF/WAVE, PCM16 (or extensible with 16-bit samples), 1 or 2 channels, any
// rate: converted to 48 kHz stereo. Returns the frame count, or -1.
static int load_wav(Player* p, const uint8_t* d, size_t n, const char** why) {
  if (n < 12 || memcmp(d, "RIFF", 4) != 0 || memcmp(d + 8, "WAVE", 4) != 0) {
    *why = "not a RIFF/WAVE file";
    return -1;
  }
  int channels = 0, rate = 0, bits = 0, tag = 0;
  const uint8_t* data = NULL;
  uint32_t data_len = 0;
  for (size_t at = 12; at + 8 <= n;) {
    uint32_t len;
    memcpy(&len, d + at + 4, 4);
    const uint8_t* body = d + at + 8;
    if (memcmp(d + at, "fmt ", 4) == 0 && len >= 16) {
      uint16_t u16;
      uint32_t u32;
      memcpy(&u16, body, 2);
      tag = u16;
      memcpy(&u16, body + 2, 2);
      channels = u16;
      memcpy(&u32, body + 4, 4);
      rate = (int)u32;
      memcpy(&u16, body + 14, 2);
      bits = u16;
    } else if (memcmp(d + at, "data", 4) == 0) {
      data = body;
      data_len = (uint32_t)(len < n - at - 8 ? len : n - at - 8);
    }
    at += 8 + len + (len & 1);
  }
  if (data == NULL || rate <= 0) {
    *why = "no data chunk";
    return -1;
  }
  if ((tag != 1 && tag != 0xFFFE) || bits != 16 || channels < 1 || channels > 2) {
    *why = "only PCM16 mono or stereo";
    return -1;
  }
  const uint32_t in_frames = data_len / (2u * (uint32_t)channels);
  const uint32_t out_frames = (uint32_t)((uint64_t)in_frames * kRate / (uint32_t)rate);
  int16_t* out = malloc((size_t)out_frames * 4 + 16);
  if (out == NULL) {
    *why = "out of memory";
    return -1;
  }
  const int16_t* in = (const int16_t*)data;
  for (uint32_t i = 0; i < out_frames; i++) {
    // Linear interpolation between the two nearest input frames.
    const uint64_t src = (uint64_t)i * (uint32_t)rate;
    const uint32_t k = (uint32_t)(src / kRate);
    const int frac = (int)((src % kRate) * 256 / kRate);
    const uint32_t k1 = k + 1 < in_frames ? k + 1 : k;
    for (int c = 0; c < 2; c++) {
      const int ci = channels == 1 ? 0 : c;
      const int a = in[k * (uint32_t)channels + (uint32_t)ci];
      const int b = in[k1 * (uint32_t)channels + (uint32_t)ci];
      out[i * 2 + (uint32_t)c] = (int16_t)(a + (b - a) * frac / 256);
    }
  }
  free(p->pcm);
  p->pcm = out;
  p->frames = out_frames;
  p->pos = 0;
  return (int)out_frames;
}

static int read_file(const char* path, uint8_t** out, size_t* n) {
  const SceUID fd = sceIoOpen(path, SCE_O_RDONLY, 0);
  if (fd < 0) return fd;
  const SceOff size = sceIoLseek(fd, 0, SCE_SEEK_END);
  sceIoLseek(fd, 0, SCE_SEEK_SET);
  uint8_t* buf = malloc((size_t)size + 1);
  if (buf == NULL) {
    sceIoClose(fd);
    return -1;
  }
  const int got = sceIoRead(fd, buf, (SceSize)size);
  sceIoClose(fd);
  if (got != (int)size) {
    free(buf);
    return got < 0 ? got : -1;
  }
  *out = buf;
  *n = (size_t)size;
  return 0;
}

// ---- sceAvPlayer ----------------------------------------------------------------

static void* av_alloc(void* arg, uint32_t alignment, uint32_t size) {
  (void)arg;
  if (alignment < 16) alignment = 16;  // newlib refuses 0
  return memalign(alignment, size);
}
static void av_free(void* arg, void* ptr) {
  (void)arg;
  free(ptr);
}
// Frame buffers come from physically contiguous memblocks: the decoders
// write through hardware.
enum { kAvFrames = 16 };
static struct {
  void* base;
  SceUID uid;
} g_av_frames[kAvFrames];
static void* av_alloc_frame(void* arg, uint32_t alignment, uint32_t size) {
  (void)arg;
  (void)alignment;
  for (int i = 0; i < kAvFrames; i++) {
    if (g_av_frames[i].base != NULL) continue;
    const SceSize bytes = (size + 0xFFFFF) & ~0xFFFFFu;
    const SceUID uid = sceKernelAllocMemBlock("fvita-avframe", SCE_KERNEL_MEMBLOCK_TYPE_USER_MAIN_PHYCONT_NC_RW, bytes, NULL);
    void* base = NULL;
    if (uid >= 0) sceKernelGetMemBlockBase(uid, &base);
    if (base == NULL) return NULL;
    g_av_frames[i].base = base;
    g_av_frames[i].uid = uid;
    return base;
  }
  return NULL;
}
static void av_free_frame(void* arg, void* ptr) {
  (void)arg;
  for (int i = 0; i < kAvFrames; i++) {
    if (g_av_frames[i].base != ptr) continue;
    sceKernelFreeMemBlock(g_av_frames[i].uid);
    g_av_frames[i].base = NULL;
    return;
  }
}
// File I/O through sceIo, per player. The player's own I/O accepted the
// file and decoded nothing (gallery build 49).
static int av_open(void* arg, const char* filename) {
  Player* p = arg;
  p->av_fd = sceIoOpen(filename, SCE_O_RDONLY, 0);
  return p->av_fd >= 0 ? 0 : -1;
}
static int av_close(void* arg) {
  Player* p = arg;
  if (p->av_fd >= 0) sceIoClose(p->av_fd);
  p->av_fd = -1;
  return 0;
}
static int av_read_offset(void* arg, uint8_t* buffer, uint64_t position, uint32_t length) {
  Player* p = arg;
  if (p->av_fd < 0) return -1;
  sceIoLseek(p->av_fd, (SceOff)position, SCE_SEEK_SET);
  return sceIoRead(p->av_fd, buffer, length);
}
static uint64_t av_size(void* arg) {
  Player* p = arg;
  if (p->av_fd < 0) return 0;
  const SceOff end = sceIoLseek(p->av_fd, 0, SCE_SEEK_END);
  sceIoLseek(p->av_fd, 0, SCE_SEEK_SET);
  return (uint64_t)end;
}
static void av_event(void* arg, int32_t event, int32_t source, void* data) {
  (void)source;
  Player* p = arg;
  // 1 stop, 2 ready, 3 play, 4 pause, 5 buffering, 0x20 warning.
  if (event == 0x20 && data) fvita_log("audioplayers", "%s: avplayer warning 0x%08X", p->id, *(unsigned*)data);
}

static int av_open_player(Player* p) {
  static int loaded;
  if (!loaded) {
    const int r = sceSysmoduleLoadModule(SCE_SYSMODULE_AVPLAYER);
    if (r < 0) return r;
    loaded = 1;
  }
  SceAvPlayerInitData init;
  memset(&init, 0, sizeof init);
  init.memoryReplacement.objectPointer = p;
  init.memoryReplacement.allocate = av_alloc;
  init.memoryReplacement.deallocate = av_free;
  init.memoryReplacement.allocateTexture = av_alloc_frame;
  init.memoryReplacement.deallocateTexture = av_free_frame;
  init.fileReplacement.objectPointer = p;
  init.fileReplacement.open = av_open;
  init.fileReplacement.close = av_close;
  init.fileReplacement.readOffset = av_read_offset;
  init.fileReplacement.size = av_size;
  init.eventReplacement.objectPointer = p;
  init.eventReplacement.eventCallback = av_event;
  init.basePriority = 0xA0;
  init.numOutputVideoFrameBuffers = 2;
  init.autoStart = SCE_TRUE;
  init.defaultLanguage = "en";
  const SceAvPlayerHandle h = sceAvPlayerInit(&init);
  // A good handle is a heap pointer, above 0x81000000; an error 0x80xxxxxx.
  if (h == 0 || ((unsigned)h >> 24) == 0x80u) return h == 0 ? -1 : (int)h;
  const int r = sceAvPlayerAddSource(h, p->path);
  if (r < 0) {
    sceAvPlayerClose(h);
    return r;
  }
  sceAvPlayerSetLooping(h, p->release_mode == kLoop);
  p->av = h;
  return 0;
}

static void av_close_player(Player* p) {
  if (p->av == 0) return;
  sceAvPlayerStop(p->av);
  sceAvPlayerClose(p->av);
  p->av = 0;
  if (p->port >= 0) {
    sceAudioOutOutput(p->port, NULL);
    sceAudioOutReleasePort(p->port);
    p->port = -1;
  }
}

// ---- the player thread ------------------------------------------------------------

static void close_port(Player* p) {
  if (p->port < 0) return;
  sceAudioOutOutput(p->port, NULL);  // drain
  sceAudioOutReleasePort(p->port);
  p->port = -1;
}

static void finished(Player* p) {
  if (p->release_mode == kLoop) {
    p->pos = 0;
    return;
  }
  p->pos = 0;
  p->state = kCompleted;
  p->ev_complete++;
  if (p->kind == kAv) av_close_player(p);
  else close_port(p);
  if (p->release_mode == kRelease) {
    // audioplayers' default: the source is let go after it played.
    free(p->pcm);
    p->pcm = NULL;
    p->frames = 0;
    p->kind = kNone;
  }
}

static void pcm_grain(Player* p) {
  if (p->port < 0) {
    p->port = sceAudioOutOpenPort(SCE_AUDIO_OUT_PORT_TYPE_MAIN, kGrain, kRate, SCE_AUDIO_OUT_MODE_STEREO);
    if (p->port < 0) {
      p->err = p->port;
      snprintf(p->err_what, sizeof p->err_what, "sceAudioOutOpenPort");
      p->state = kPrepared;
      return;
    }
    p->gain_dirty = 1;
  }
  if (p->gain_dirty) apply_gain(p);
  static int16_t grains[kPlayers][kGrain * 2];
  int16_t* g = grains[p - g_players];
  const uint32_t left = p->frames > p->pos ? p->frames - p->pos : 0;
  const uint32_t n = left < kGrain ? left : kGrain;
  if (n) memcpy(g, p->pcm + (size_t)p->pos * 2, (size_t)n * 4);
  if (n < kGrain) memset(g + n * 2, 0, (size_t)(kGrain - n) * 4);
  sceAudioOutOutput(p->port, g);
  p->pos += n;
  if (p->pos >= p->frames) finished(p);
}

static void av_grain(Player* p) {
  if (p->av == 0) {
    const int r = av_open_player(p);
    if (r < 0) {
      p->err = r;
      snprintf(p->err_what, sizeof p->err_what, "sceAvPlayer open");
      fvita_log("audioplayers", "%s: %s 0x%08X", p->id, p->err_what, (unsigned)r);
      p->state = kPrepared;
      return;
    }
    // The player opens the stream on its own thread; IsActive is false for a
    // while after AddSource.
    const uint64_t t0 = sceKernelGetProcessTimeWide();
    while (!sceAvPlayerIsActive(p->av) && sceKernelGetProcessTimeWide() - t0 < 3000000ULL) sceKernelDelayThread(2000);
    if (!sceAvPlayerIsActive(p->av)) {
      p->err = -1;
      snprintf(p->err_what, sizeof p->err_what, "the player never became active");
      av_close_player(p);
      p->state = kPrepared;
      return;
    }
    SceAvPlayerStreamInfo si;
    memset(&si, 0, sizeof si);
    if (sceAvPlayerGetStreamInfo(p->av, 0, &si) >= 0) p->av_dur = si.duration;
    if (p->av_pos_ms) sceAvPlayerJumpToTime(p->av, p->av_pos_ms);
  }
  if (!sceAvPlayerIsActive(p->av)) {
    finished(p);
    return;
  }
  SceAvPlayerFrameInfo f;
  memset(&f, 0, sizeof f);
  if (!sceAvPlayerGetAudioData(p->av, &f)) {
    sceKernelDelayThread(1000);
    return;
  }
  if (p->port < 0) {
    const unsigned channels = f.details.audio.channelCount ? f.details.audio.channelCount : 2;
    const int grain = (int)(f.details.audio.size / (2 * channels));
    p->port = sceAudioOutOpenPort(SCE_AUDIO_OUT_PORT_TYPE_BGM, grain, (int)f.details.audio.sampleRate,
                                  channels == 1 ? SCE_AUDIO_OUT_MODE_MONO : SCE_AUDIO_OUT_MODE_STEREO);
    if (p->port < 0) {
      p->err = p->port;
      snprintf(p->err_what, sizeof p->err_what, "sceAudioOutOpenPort(BGM)");
      fvita_log("audioplayers", "%s: %s 0x%08X", p->id, p->err_what, (unsigned)p->port);
      av_close_player(p);
      p->state = kPrepared;
      return;
    }
    p->gain_dirty = 1;
  }
  if (p->gain_dirty) apply_gain(p);
  sceAudioOutOutput(p->port, f.pData);
  p->av_pos_ms = (uint32_t)f.timeStamp;
}

static void do_cmd(Player* p) {
  const int cmd = p->cmd;
  const int arg = p->cmd_arg;
  switch (cmd) {
    case kCmdPlay:
      if (p->kind != kNone) {
        if (p->state == kCompleted) p->pos = 0;
        p->state = kPlaying;
        if (p->kind == kAv && p->av && p->state == kPlaying) sceAvPlayerResume(p->av);
      }
      break;
    case kCmdPause:
      if (p->state == kPlaying) {
        p->state = kPaused;
        if (p->kind == kAv && p->av) sceAvPlayerPause(p->av);
        else close_port(p);
      }
      break;
    case kCmdStop:
      if (p->kind == kAv) av_close_player(p);
      else close_port(p);
      p->pos = 0;
      p->av_pos_ms = 0;
      if (p->kind != kNone) p->state = kPrepared;
      break;
    case kCmdSeek:
      if (p->kind == kPcm) {
        const uint32_t f = (uint32_t)((uint64_t)(arg < 0 ? 0 : arg) * kRate / 1000);
        p->pos = f < p->frames ? f : p->frames;
      } else if (p->kind == kAv) {
        p->av_pos_ms = (uint32_t)(arg < 0 ? 0 : arg);
        if (p->av) sceAvPlayerJumpToTime(p->av, p->av_pos_ms);
      }
      p->ev_seek++;
      break;
    case kCmdRelease:
    case kCmdQuit:
      if (p->kind == kAv) av_close_player(p);
      else close_port(p);
      free(p->pcm);
      p->pcm = NULL;
      p->frames = 0;
      p->pos = 0;
      p->av_pos_ms = 0;
      p->kind = kNone;
      p->state = kIdle;
      if (cmd == kCmdQuit) p->alive = 0;
      break;
    default:
      break;
  }
  p->cmd = kCmdNone;
}

static int player_thread(SceSize args, void* argp) {
  (void)args;
  Player* p = *(Player**)argp;
  while (p->alive) {
    if (p->cmd != kCmdNone) do_cmd(p);
    if (p->state == kPlaying) {
      if (p->kind == kPcm) pcm_grain(p);
      else if (p->kind == kAv) av_grain(p);
      else p->state = kIdle;
    } else {
      sceKernelDelayThread(4000);
    }
  }
  return 0;
}

// Hands a command to the thread and waits for it to be taken, up to 2 s.
static void command(Player* p, int cmd, int arg) {
  for (int i = 0; i < 200 && p->cmd != kCmdNone; i++) sceKernelDelayThread(10 * 1000);
  p->cmd_arg = arg;
  __sync_synchronize();
  p->cmd = cmd;
  for (int i = 0; i < 200 && p->cmd != kCmdNone; i++) sceKernelDelayThread(10 * 1000);
}

// ---- sources ---------------------------------------------------------------------

static int is_wav(const char* path, const char* mime, const uint8_t* head, size_t n) {
  if (head != NULL && n >= 12 && memcmp(head, "RIFF", 4) == 0 && memcmp(head + 8, "WAVE", 4) == 0) return 1;
  if (mime && (strstr(mime, "wav") || strstr(mime, "wave"))) return 1;
  const size_t l = path ? strlen(path) : 0;
  return l > 4 && strcasecmp(path + l - 4, ".wav") == 0;
}

// `url` as audioplayers' AudioCache and sources send it: a device path
// (`app0:/...`, `ux0:...`), one behind `file://`, or the `./ux0:...`
// Dart's Uri makes of a relative path with a colon in it.
static void url_to_path(const char* url, char* out, size_t cap) {
  if (strncmp(url, "file://", 7) == 0) url += 7;
  if (url[0] == '/' && strstr(url, ":") != NULL && url[1] != '/') url++;  // "/ux0:..."
  if (strncmp(url, "./", 2) == 0) url += 2;
  snprintf(out, cap, "%s", url);
}

static int set_source(Player* p, const char* path, const uint8_t* bytes, size_t n, const char* mime, char* out,
                      size_t cap) {
  command(p, kCmdRelease, 0);
  uint8_t* owned = NULL;
  size_t len = n;
  const uint8_t* data = bytes;
  int wav = is_wav(path, mime, bytes, n);
  if (data == NULL && wav) {
    const int r = read_file(path, &owned, &len);
    if (r < 0) return fvita_reply_err(out, cap, "source", path, r);
    data = owned;
  }
  if (data != NULL && !wav && is_wav(NULL, NULL, data, len)) wav = 1;
  if (wav) {
    const char* why = "";
    const int frames = load_wav(p, data, len, &why);
    free(owned);
    if (frames < 0) return fvita_reply_err(out, cap, "source", why, 0);
    p->kind = kPcm;
    p->state = kPrepared;
    p->ev_prepared++;
    return fvita_reply_ok(out, cap, "{\"kind\":\"pcm\",\"duration_ms\":%llu}",
                          (unsigned long long)p->frames * 1000ULL / kRate);
  }
  if (data != NULL) {
    // Bytes the system's player has to see as a file: written under the
    // app's own tmp directory, the one path_provider_vita hands out.
    char title[16] = "FLUTTER";
    sceAppMgrAppParamGetString(0, 12, title, sizeof title);
    char dir[64];
    snprintf(dir, sizeof dir, "ux0:data/%s", title);
    sceIoMkdir(dir, 0777);
    snprintf(dir, sizeof dir, "ux0:data/%s/tmp", title);
    sceIoMkdir(dir, 0777);
    snprintf(p->path, sizeof p->path, "%s/audioplayers-%s.bin", dir, p->id);
    const SceUID fd = sceIoOpen(p->path, SCE_O_WRONLY | SCE_O_CREAT | SCE_O_TRUNC, 0777);
    const int wrote = fd < 0 ? fd : sceIoWrite(fd, data, (SceSize)len);
    if (fd >= 0) sceIoClose(fd);
    if (wrote != (int)len) return fvita_reply_err(out, cap, "source", "write bytes", wrote < 0 ? wrote : -1);
  } else {
    snprintf(p->path, sizeof p->path, "%s", path);
    const SceUID fd = sceIoOpen(p->path, SCE_O_RDONLY, 0);
    if (fd < 0) return fvita_reply_err(out, cap, "source", p->path, fd);
    sceIoClose(fd);
  }
  p->kind = kAv;
  p->av_dur = 0;
  p->av_pos_ms = 0;
  p->state = kPrepared;
  p->ev_prepared++;
  return fvita_reply_ok(out, cap, "{\"kind\":\"av\",\"duration_ms\":null}");
}

// ---- the channel -------------------------------------------------------------------

static int handle(const char* method, const char* body, size_t len, char* out, size_t cap) {
  char id[40];
  if (fvita_json_str(body, len, "id", id, sizeof id) <= 0) return fvita_reply_err(out, cap, "args", "no id", 0);
  lock();
  int n;
  Player* p = find(id);
  if (strcmp(method, "create") == 0) {
    if (p == NULL) {
      for (int i = 0; i < kPlayers && p == NULL; i++) {
        if (g_players[i].id[0] == 0) p = &g_players[i];
      }
      if (p == NULL) {
        n = fvita_reply_err(out, cap, "failed", "eight players already", 0);
        unlock();
        return n;
      }
      memset(p, 0, sizeof *p);
      snprintf(p->id, sizeof p->id, "%s", id);
      p->port = -1;
      p->av_fd = -1;
      p->volume = 1;
      p->alive = 1;
      p->thread = sceKernelCreateThread("fvita-audioplayer", player_thread, 0x10000100, 0x8000, 0, 0, NULL);
      if (p->thread < 0) {
        n = fvita_reply_err(out, cap, "failed", "sceKernelCreateThread", p->thread);
        p->id[0] = 0;
        unlock();
        return n;
      }
      sceKernelStartThread(p->thread, sizeof p, &p);
    }
    n = fvita_reply_ok(out, cap, "null");
  } else if (p == NULL) {
    n = strcmp(method, "dispose") == 0 ? fvita_reply_ok(out, cap, "null")
                                       : fvita_reply_err(out, cap, "state", "no such player; create first", 0);
  } else if (strcmp(method, "dispose") == 0) {
    command(p, kCmdQuit, 0);
    SceUInt timeout = 2000 * 1000;
    sceKernelWaitThreadEnd(p->thread, NULL, &timeout);
    sceKernelDeleteThread(p->thread);
    p->id[0] = 0;
    n = fvita_reply_ok(out, cap, "null");
  } else if (strcmp(method, "setSource") == 0) {
    char mime[48] = "";
    fvita_json_str(body, len, "mime", mime, sizeof mime);
    char url[256] = "";
    if (fvita_json_str(body, len, "url", url, sizeof url) > 0) {
      char path[256];
      url_to_path(url, path, sizeof path);
      n = set_source(p, path, NULL, 0, mime, out, cap);
    } else {
      // base64 bytes; decoded in place of the body copy, which is ours.
      const char* key = "\"bytes\":\"";
      const char* v = NULL;
      for (size_t i = 0; i + strlen(key) < len; i++) {
        if (memcmp(body + i, key, strlen(key)) == 0) {
          v = body + i + strlen(key);
          break;
        }
      }
      if (v == NULL) {
        n = fvita_reply_err(out, cap, "args", "no url and no bytes", 0);
      } else {
        const char* end = memchr(v, '"', (size_t)(body + len - v));
        const size_t b64 = end ? (size_t)(end - v) : 0;
        unsigned char* raw = malloc(b64 / 4 * 3 + 4);
        const int got = raw ? fvita_base64_decode(v, b64, raw, b64 / 4 * 3 + 4) : -1;
        if (got < 0) n = fvita_reply_err(out, cap, "args", "bytes are not base64", 0);
        else n = set_source(p, NULL, raw, (size_t)got, mime, out, cap);
        free(raw);
      }
    }
  } else if (strcmp(method, "resume") == 0) {
    p->err = 0;
    command(p, kCmdPlay, 0);
    n = p->err ? fvita_reply_err(out, cap, "play", p->err_what, p->err) : fvita_reply_ok(out, cap, "null");
  } else if (strcmp(method, "pause") == 0) {
    command(p, kCmdPause, 0);
    n = fvita_reply_ok(out, cap, "null");
  } else if (strcmp(method, "stop") == 0) {
    command(p, kCmdStop, 0);
    n = fvita_reply_ok(out, cap, "null");
  } else if (strcmp(method, "release") == 0) {
    command(p, kCmdRelease, 0);
    n = fvita_reply_ok(out, cap, "null");
  } else if (strcmp(method, "seek") == 0) {
    command(p, kCmdSeek, fvita_json_int(body, len, "ms", 0));
    n = fvita_reply_ok(out, cap, "null");
  } else if (strcmp(method, "setVolume") == 0) {
    p->volume = (float)fvita_json_num(body, len, "volume", 1.0);
    p->gain_dirty = 1;
    n = fvita_reply_ok(out, cap, "null");
  } else if (strcmp(method, "setBalance") == 0) {
    p->balance = (float)fvita_json_num(body, len, "balance", 0.0);
    p->gain_dirty = 1;
    n = fvita_reply_ok(out, cap, "null");
  } else if (strcmp(method, "setReleaseMode") == 0) {
    p->release_mode = fvita_json_int(body, len, "mode", kRelease);
    if (p->av) sceAvPlayerSetLooping(p->av, p->release_mode == kLoop);
    n = fvita_reply_ok(out, cap, "null");
  } else if (strcmp(method, "poll") == 0) {
    const unsigned long long pos = p->kind == kPcm ? (unsigned long long)p->pos * 1000ULL / kRate : p->av_pos_ms;
    const unsigned long long dur = p->kind == kPcm ? (unsigned long long)p->frames * 1000ULL / kRate : p->av_dur;
    char durs[24];
    if (p->kind == kNone || (p->kind == kAv && dur == 0)) snprintf(durs, sizeof durs, "null");
    else snprintf(durs, sizeof durs, "%llu", dur);
    n = fvita_reply_ok(out, cap,
                       "{\"state\":%d,\"pos\":%llu,\"dur\":%s,\"prepared\":%u,\"complete\":%u,\"seek\":%u,"
                       "\"err\":%d,\"err_what\":\"%s\"}",
                       p->state, pos, durs, p->ev_prepared, p->ev_complete, p->ev_seek, p->err, p->err_what);
  } else {
    n = fvita_reply_err(out, cap, "unknown", method, 0);
  }
  unlock();
  return n;
}

__attribute__((constructor)) static void reg(void) {
  g_lock = sceKernelCreateMutex("fvita-audioplayers", 0, 0, NULL);
  fvita_channel_register("vita/audioplayers", handle);
}
