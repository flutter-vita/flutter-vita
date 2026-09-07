cmake_minimum_required(VERSION 3.16)

if(NOT DEFINED CMAKE_TOOLCHAIN_FILE)
  if(DEFINED ENV{VITASDK})
    set(CMAKE_TOOLCHAIN_FILE "$ENV{VITASDK}/share/vita.toolchain.cmake" CACHE PATH "toolchain file")
  else()
    message(FATAL_ERROR "Define VITASDK. See docs/dev-environment.md")
  endif()
endif()

project(flutter_vita_m3 C CXX ASM)
include("${VITASDK}/share/vita.cmake" REQUIRED)

set(VITA_APP_NAME "Flutter Vita")

# FVTA00002 -- M1's slot, deliberately reused rather than taking a new one.
#
# The whole dev loop is built around this title id: the receiver hard-codes
# TARGET_TITLEID "FVTA00002" (receiver/src/main.c:51) and dev.sh
# drives that. Giving M3 its own id would mean changing the receiver, rebuilding
# it, and installing it -- and installing a receiver is the one operation that
# needs the old receiver working, so a mistake there costs a manual recovery.
#
# M1 has served its purpose: Phase 1's exit criteria are all met and recorded.
# Its .vpk can be rebuilt from spikes/m1-vpk at any time if a known-good
# pure-Dart reference is ever needed again.
set(VITA_TITLEID  "FVTA00002")
set(VITA_VERSION  "01.00")

# Same reasoning as m1-vpk: -g in Release because the debug info never reaches
# the device (eboot.bin is a stripped SELF) but vita-parse-core needs it here to
# symbolicate crash dumps, which have been this port's most effective tool.
set(CMAKE_C_FLAGS   "${CMAKE_C_FLAGS} -std=gnu11 -Wall -O2 -g")
set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -std=gnu++20 -Wall -O2 -g")

set(ENGINE_SRC "${CMAKE_SOURCE_DIR}/../../third_party/flutter/engine/src")
set(ENGINE_OUT "${ENGINE_SRC}/out/vita_release")
set(SNAPSHOT_S "${CMAKE_SOURCE_DIR}/out/snapshot.S")

if(NOT EXISTS "${ENGINE_OUT}/obj")
  message(FATAL_ERROR
    "No engine build at ${ENGINE_OUT}. Build it first:\n"
    "  cd third_party/flutter/engine/src\n"
    "  ./flutter/tools/gn --target-os vita --runtime-mode release --no-lto --no-rbe --embedder-for-target\n"
    "  ninja -C out/vita_release flutter/shell/platform/embedder:vita_embedder")
endif()

if(NOT EXISTS "${SNAPSHOT_S}")
  message(FATAL_ERROR
    "No snapshot at ${SNAPSHOT_S}. Generate it with build.sh, which runs\n"
    "  out/vita_release/clang_arm64/gen_snapshot_armv7 --snapshot_kind=app-aot-assembly")
endif()

# ADR-0005 option A: the snapshot is assembled and linked in rather than loaded.
# The four _kDart* symbols vita_embedder.cc declares extern come from here.
# M1's on-device dev server, reused rather than reimplemented.
#
# Without it m3 is invisible while it runs: it opens no port, so `cycle` always
# reported "CRASHED (never opened 1339)" even on a healthy run, and reading the
# log meant asking a human to exit the app and tap the receiver. On 2026-08-11
# that cost several round trips on the one question the log would have answered
# in a second. The server gives back `ping`, `log`, `get` and `handoff` while
# the engine is up, which is what makes the loop autonomous.
add_executable(${PROJECT_NAME}
  ${SNAPSHOT_S}
  ${CMAKE_CURRENT_SOURCE_DIR}/../m1-vpk/src/devserver.c
)
target_include_directories(${PROJECT_NAME} PRIVATE
  ${CMAKE_CURRENT_SOURCE_DIR}/../m1-vpk/src
)

# Link as C++. Skia, ICU and the engine are all C++, and ICU in particular is
# built *with* exceptions while Dart is -fno-exceptions -- its objects carry
# exception tables referencing __gxx_personality_v0, which only the C++ driver
# supplies. This bit M1 and the reason is unchanged.
set_target_properties(${PROJECT_NAME} PROPERTIES LINKER_LANGUAGE CXX)

# vita-elf-create appends ~32 KB of SCE metadata after the first LOAD segment,
# and fails outright if the next segment starts before there is room:
#
#   Cannot allocate 32400 bytes for SCE data at end of segment 0;
#   segment 1 overlaps
#
# At the default 4 KiB page size the gap between segments came to 2148 bytes.
# Aligning to 64 KiB leaves a whole page of slack. This did not arise for M1
# because its text segment was ~2.5 MiB; at 12 MiB the alignment padding
# happened to land badly.
target_link_options(${PROJECT_NAME} PRIVATE
  "-Wl,-z,max-page-size=0x10000"
  "-Wl,-z,common-page-size=0x10000"
  # Force pthread_cancel out of libpthread.a, and read the next paragraph
  # before deleting this line -- nothing in this program calls it.
  #
  # GCC's gthr-default.h decides whether the program is threaded by taking the
  # address of a proxy symbol. On glibc that is __pthread_key_create; here it
  # falls through to `pthread_cancel`, declared as a **weak** reference. A weak
  # reference does not pull a member out of an archive, so the symbol links as
  # `w pthread_cancel` with no address, __gthread_active_p() returns 0, and
  # libstdc++ quietly compiles the whole engine down to its single-threaded
  # path: every std::mutex::lock() becomes `return 0` without touching the
  # handle.
  #
  # That is not merely slow, it is wrong in a way that hides. The mutex is
  # never initialised, so it keeps whatever the stack slot held before -- and
  # std::condition_variable::wait is *not* gated on __gthread_active_p, so it
  # hands that uninitialised handle to a real pthread_cond_wait. The first
  # crash of this port was that exact path: an atomic exchange against a string
  # literal in .rodata, deterministic because it is a string literal.
  #
  # -u makes the reference strong enough to pull the member in. It costs one
  # object nobody calls, and it is the difference between the engine's mutexes
  # existing and not.
  "-Wl,-u,pthread_cancel"
)

# GN emits source_sets whose objects link directly; there is no single archive
# to point at. M1 globbed ~500 objects, this globs ~2700.
#
# Note what is deliberately NOT excluded: the host-toolchain objects under
# obj/... built for macOS. They live in a separate subtree (clang_arm64/) which
# this glob does not reach, because ninja writes host output there rather than
# under obj/. If that ever changes, this glob starts feeding Mach-O objects to
# an ARM linker and the error will be spectacular rather than subtle.
# ENGINE_ARCHIVE points at a prebuilt libflutter_engine_vita.a from
# tools/package-engine.sh, for anyone who has not built the engine themselves.
# Unset, the build globs the local object tree as before.
#
# --whole-archive is not optional here. The engine relies on static
# initialisers in translation units that nothing references by symbol, and
# ordinary archive semantics pull in only members that resolve an undefined
# reference -- so a plain link drops them, succeeds, and fails at runtime.
# Linking loose objects has whole-archive semantics already, which is why this
# only needs saying on the archive path.
if(ENGINE_ARCHIVE)
  message(STATUS "Linking prebuilt engine: ${ENGINE_ARCHIVE}")
  set(ENGINE_OBJECTS
    "-Wl,--whole-archive" "${ENGINE_ARCHIVE}" "-Wl,--no-whole-archive")
else()
file(GLOB_RECURSE ENGINE_OBJECTS "${ENGINE_OUT}/obj/*.o")
# vita_link_check has its own main(). Both it and vita_embedder.o are in the
# tree, and globbing both gives a duplicate-symbol link error that names
# `main` -- which reads as a mistake in our code rather than as two objects that
# were never meant to meet.
list(FILTER ENGINE_OBJECTS EXCLUDE REGEX "vita_link_check")

list(LENGTH ENGINE_OBJECTS ENGINE_OBJECT_COUNT)
message(STATUS "Linking ${ENGINE_OBJECT_COUNT} engine objects")
endif()

target_link_libraries(${PROJECT_NAME}
  ${ENGINE_OBJECTS}
  SceDisplay_stub
  SceCtrl_stub
  SceTouch_stub
  SceIofilemgr_stub
  SceNet_stub
  SceNetCtl_stub
  SceSysmodule_stub
  SceAppMgr_stub
  SceSysmem_stub
  SceLibKernel_stub
  SceKernelThreadMgr_stub
  ScePower_stub
  SceGxm_stub
  SceCommonDialog_stub
  pthread
  m
)

# UNSAFE for the same reason M1 needs it: a safe self cannot see ux0:app at all,
# which is what the dev loop uses to install and relaunch. See
# spikes/vita-tooling/README.md -- this was six closed routes' worth of work and
# should not be reverted casually.
vita_create_self(${PROJECT_NAME}.self ${PROJECT_NAME} UNSAFE)

# icudtl.dat ships as a data file; vita_embedder.cc reads it from app0:.
#
# It is 862 KB, not the ~10 MB this project has been assuming: Flutter vendors
# an already-slimmed ICU dataset at third_party/icu/flutter/ rather than the
# full one. So "slim icudtl.dat" comes off the Phase 2 list -- upstream did it.
#
# flutter_assets comes from `flutter build bundle` against the B2 counter app,
# the same app whose kernel becomes the snapshot. The two must be generated
# from the same source tree: the asset manifest is looked up by keys the
# compiled code asks for, so a bundle from a different app fails at runtime in
# ways that look like asset-loading bugs rather than a mismatch.
#
# Only the files the engine actually reads are listed. kernel_blob.bin is
# deliberately absent -- it is the JIT path's copy of the program, and this
# build links its snapshot into eboot.bin instead (ADR-0005). Shipping it would
# add megabytes the engine never opens.
set(FLUTTER_ASSETS ${CMAKE_CURRENT_SOURCE_DIR}/../b2-flutter-snapshot/out/counter_app/build/flutter_assets)

vita_create_vpk(${PROJECT_NAME}.vpk ${VITA_TITLEID} ${PROJECT_NAME}.self
  VERSION ${VITA_VERSION}
  NAME ${VITA_APP_NAME}
  FILE ${ENGINE_SRC}/flutter/third_party/icu/flutter/icudtl.dat icudtl.dat
  # The system font, scanned from app0:/fonts by txt/src/txt/platform_vita.cc.
  # This is not part of the asset bundle on purpose -- see that file for why
  # icon fonts must not be offered as system families.
  FILE ${ENGINE_SRC}/flutter/txt/third_party/fonts/Roboto-Regular.ttf fonts/Roboto-Regular.ttf
  FILE ${FLUTTER_ASSETS}/AssetManifest.bin flutter_assets/AssetManifest.bin
  FILE ${FLUTTER_ASSETS}/FontManifest.json flutter_assets/FontManifest.json
  FILE ${FLUTTER_ASSETS}/NOTICES.Z flutter_assets/NOTICES.Z
  FILE ${FLUTTER_ASSETS}/NativeAssetsManifest.json flutter_assets/NativeAssetsManifest.json
  FILE ${FLUTTER_ASSETS}/fonts/MaterialIcons-Regular.otf flutter_assets/fonts/MaterialIcons-Regular.otf
  FILE ${FLUTTER_ASSETS}/packages/cupertino_icons/assets/CupertinoIcons.ttf flutter_assets/packages/cupertino_icons/assets/CupertinoIcons.ttf
)
