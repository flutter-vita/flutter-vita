# Build any Flutter app into a Vita .vpk.
#
# The counterpart to spikes/m3-vpk, with the spike taken out: no hardcoded app,
# no hardcoded asset path, and the engine comes from a packaged artifact rather
# than a local object tree. Driven by tools/build-vita-app.sh, which passes
# everything in as cache variables.
#
# Required:
#   APP_NAME        display name on the LiveArea
#   TITLE_ID        nine characters, e.g. FVTA00002
#   SUPERVISOR_TITLE_ID  nine characters, distinct from TITLE_ID, for eboot2.bin
#   SNAPSHOT_S      gen_snapshot output for the app's kernel
#   FLUTTER_ASSETS  the app's `flutter build bundle` output
#   ENGINE_DIR      unpacked flutter-engine-vita-<version>/
cmake_minimum_required(VERSION 3.16)

if(NOT DEFINED CMAKE_TOOLCHAIN_FILE)
  if(DEFINED ENV{VITASDK})
    set(CMAKE_TOOLCHAIN_FILE "$ENV{VITASDK}/share/vita.toolchain.cmake" CACHE PATH "toolchain file")
  else()
    message(FATAL_ERROR "Define VITASDK. See docs/dev-environment.md")
  endif()
endif()

project(flutter_vita_app C CXX ASM)
include("${VITASDK}/share/vita.cmake" REQUIRED)

foreach(required APP_NAME TITLE_ID SUPERVISOR_TITLE_ID SNAPSHOT_S FLUTTER_ASSETS
                 ENGINE_DIR)
  if(NOT ${required})
    message(FATAL_ERROR "${required} is required. Use tools/build-vita-app.sh.")
  endif()
endforeach()

set(VITA_APP_NAME "${APP_NAME}")
set(VITA_TITLEID  "${TITLE_ID}")
set(VITA_VERSION  "01.00")

set(ENGINE_LIB "${ENGINE_DIR}/lib/libflutter_engine_vita.a")
if(NOT EXISTS "${ENGINE_LIB}")
  message(FATAL_ERROR
    "No engine archive at ${ENGINE_LIB}.\n"
    "Download flutter-engine-vita-<version>.tar.gz and unpack it, or build one\n"
    "with tools/package-engine.sh.")
endif()

# -g so vita-parse-core can symbolicate the app's own frames. The engine's are
# already gone: the packaged archive is stripped of debug info, which is what
# takes it from 1.1 GB to 63 MB.
set(CMAKE_C_FLAGS   "${CMAKE_C_FLAGS} -std=gnu11 -Wall -O2 -g")
set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -std=gnu++20 -Wall -O2 -g")

# The embedder, with main(), is inside the archive. What is not is the dev
# server it calls into — three undefined symbols the app has to satisfy. It
# ships as source in the artifact so it can be replaced: a shipping app wants
# no listening socket, and can link a stub with the same three entry points.
add_executable(${PROJECT_NAME}
  ${SNAPSHOT_S}
  ${ENGINE_DIR}/src/devserver.c
)
target_include_directories(${PROJECT_NAME} PRIVATE ${ENGINE_DIR}/src)

# Link as C++: Skia, ICU and the engine are C++, and ICU is built *with*
# exceptions while Dart is -fno-exceptions, so its objects carry exception
# tables referencing __gxx_personality_v0 that only the C++ driver supplies.
set_target_properties(${PROJECT_NAME} PROPERTIES LINKER_LANGUAGE CXX)

target_link_options(${PROJECT_NAME} PRIVATE
  # vita-elf-create appends ~32 KB of SCE metadata after the first LOAD segment
  # and fails if the next segment starts too soon. At 4 KiB pages the gap came
  # to 2148 bytes; 64 KiB leaves a whole page of slack.
  "-Wl,-z,max-page-size=0x10000"
  "-Wl,-z,common-page-size=0x10000"

  # Nothing calls pthread_cancel. Do not remove this.
  #
  # gcc decides whether a program is threaded by taking the address of a proxy
  # symbol, and outside glibc that proxy is pthread_cancel — a weak reference,
  # which does not pull a member out of an archive. Without this it links with
  # no address, __gthread_active_p() returns 0, and libstdc++ compiles every
  # std::mutex::lock() in the engine down to `return 0` without touching the
  # handle. The mutexes are then never initialised, and
  # std::condition_variable::wait — which is not gated on that check — hands an
  # uninitialised handle to a real pthread_cond_wait.
  "-Wl,-u,pthread_cancel"
)

target_link_libraries(${PROJECT_NAME}
  # --whole-archive, and this is load-bearing rather than cautious. The engine
  # relies on static initialisers in translation units nothing references by
  # symbol; ordinary archive semantics pull in only members that resolve an
  # undefined reference, so a plain link succeeds and then fails at runtime.
  -Wl,--whole-archive "${ENGINE_LIB}" -Wl,--no-whole-archive

  SceDisplay_stub SceCtrl_stub SceTouch_stub SceIofilemgr_stub
  SceNet_stub SceNetCtl_stub SceSysmodule_stub SceAppMgr_stub SceBgAppUtil_stub
  SceSysmem_stub SceLibKernel_stub SceKernelThreadMgr_stub
  ScePower_stub SceGxm_stub SceCommonDialog_stub
  pthread m
)

vita_create_self(${PROJECT_NAME}.self ${PROJECT_NAME} UNSAFE)

# The crash supervisor, as eboot2.bin.
#
# A background application: a separate process, started by this app at startup
# and outliving it, so that when the app dies the console still has something
# listening that can bring the loader back. Without it every crash costs a
# human walking to the Vita and tapping a bubble, which is the real limit on
# how fast this port can be debugged -- not build time.
#
# ATTRIBUTE and MEMSIZE come from Sony's own background-app sample
# (Vita-Development-Suite/samples, notification-util/bootparam-bg.yml). The
# memory budget is not cosmetic: a background process cannot be handed the
# whole foreground app budget, and 2 MiB is far more than a socket and a 16 KiB
# net pool need.
add_executable(fvita_supervisor ${CMAKE_CURRENT_SOURCE_DIR}/supervisor.c)
target_link_libraries(fvita_supervisor
  SceIofilemgr_stub SceSysmem_stub SceLibKernel_stub SceKernelThreadMgr_stub
  SceNet_stub SceNetCtl_stub SceSysmodule_stub SceAppMgr_stub
)
vita_create_self(fvita_supervisor.self fvita_supervisor UNSAFE
  ATTRIBUTE 3
  MEMSIZE 0x800
)

# param2.sfo -- the manifest for eboot2.bin.
#
# sceBgAppUtilStartBgApp does not merely run eboot2.bin; the shell looks up a
# second SFO beside the first to learn what it is being asked to start, and
# without it the call cannot succeed whatever else is right. Same shape as
# Sony's sample: its own title id, CATEGORY gdd, and ATTRIBUTE 0x1000, the bit
# that means "background application".
#
# Only keys already in vita-mksfoex's template are set. Keys it does not know
# get appended after the sorted ones, and an SFO index table that is not sorted
# by key is not something any Sony parser is documented to accept.
add_custom_command(OUTPUT ${CMAKE_CURRENT_BINARY_DIR}/param2.sfo
  COMMAND ${VITA_MKSFOEX}
    -s TITLE_ID=${SUPERVISOR_TITLE_ID}
    -s CATEGORY=gdd
    -s APP_VER=${VITA_VERSION}
    -d ATTRIBUTE=4096
    -d ATTRIBUTE_MINOR=0
    "${APP_NAME} Supervisor"
    ${CMAKE_CURRENT_BINARY_DIR}/param2.sfo
  COMMENT "Generating param2.sfo for the supervisor"
  VERBATIM
)

# Everything the engine reads at runtime from app0:.
#
# flutter_assets is globbed rather than listed, because an app's bundle is
# whatever `flutter build bundle` produced — images, fonts, JSON, shaders. The
# glob is at configure time, so a newly added asset needs a reconfigure; the
# build script does that every run.
#
# kernel_blob.bin is filtered out on purpose. It is the JIT path's copy of the
# whole program, several megabytes, and this build links its AOT snapshot into
# eboot.bin instead (ADR-0005). Shipping it would be dead weight the engine
# never opens.
file(GLOB_RECURSE APP_ASSETS RELATIVE "${FLUTTER_ASSETS}" "${FLUTTER_ASSETS}/*")
list(FILTER APP_ASSETS EXCLUDE REGEX "kernel_blob.bin|\\.last_build_id")

set(VPK_FILES
  FILE "${CMAKE_CURRENT_BINARY_DIR}/fvita_supervisor.self" eboot2.bin
  FILE "${CMAKE_CURRENT_BINARY_DIR}/param2.sfo" sce_sys/param2.sfo
  FILE "${ENGINE_DIR}/data/icudtl.dat" icudtl.dat
  # The system font, scanned from app0:/fonts. Deliberately not inside
  # flutter_assets: that directory holds icon fonts meant to be looked up by
  # asset key, and offering MaterialIcons as a fallback for body text renders
  # paragraphs in icons.
  FILE "${ENGINE_DIR}/data/Roboto-Regular.ttf" fonts/Roboto-Regular.ttf
)
foreach(asset ${APP_ASSETS})
  list(APPEND VPK_FILES FILE "${FLUTTER_ASSETS}/${asset}" "flutter_assets/${asset}")
endforeach()

list(LENGTH APP_ASSETS ASSET_COUNT)
message(STATUS "${APP_NAME} [${TITLE_ID}] — ${ASSET_COUNT} asset files")

vita_create_vpk(${PROJECT_NAME}.vpk ${VITA_TITLEID} ${PROJECT_NAME}.self
  VERSION ${VITA_VERSION}
  NAME ${VITA_APP_NAME}
  ${VPK_FILES}
)
