# Build any Flutter app into a Vita .vpk. Driven by tools/build-vita-app.sh,
# which passes everything in as cache variables.
#
# Required:
#   APP_NAME        display name on the LiveArea
#   TITLE_ID        nine characters, e.g. FVTA00002
#   SUPERVISOR_TITLE_ID  nine characters, distinct from TITLE_ID, for eboot2.bin
#   SNAPSHOT_S      gen_snapshot output for the app's kernel
#   FLUTTER_ASSETS  the app's `flutter build bundle` output
#   ENGINE_DIR      unpacked flutter-engine-vita-<version>/
#
# Optional:
#   EXTRA_SOURCES   ;-list of extra C/C++ files to compile into the app
#   NO_SUPERVISOR   ON to leave out eboot2.bin and param2.sfo
#   EXTRA_DEFINES   ;-list of K=V preprocessor defines
#   EXTRA_LINK_OPTIONS  ;-list of extra linker flags
#   RELEASE         ON to link release.c instead of the dev loop
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
set(LIVEAREA_DIR "${CMAKE_CURRENT_SOURCE_DIR}/livearea" CACHE PATH
    "Directory holding icon0.png, template.xml, bg0.png and startup.png")
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

# The embedder, with main(), is inside the archive. The dev server it calls into
# is not: five undefined symbols the app must satisfy, shipped as source so a
# shipping app can link a stub instead. bailout.c is the other half and drops
# with it; it overrides abort() and __assert_func(), which works only because
# both are undefined in the engine archive.
#
# The debug HUD lives inside the archive, so it is switched off by *adding* a
# strong definition rather than leaving a file out:
#
#   echo 'int flutter_vita_debug_overlay = 0;' > shipping.c
#
# RELEASE=ON is that build: release.c is the five stubs plus that zero. Nothing
# else here changes, so a release app is the same link with two files swapped
# for one. `overlay off` on the dev server toggles the HUD at runtime.
if(RELEASE)
  set(DEV_LOOP_SOURCES ${CMAKE_CURRENT_SOURCE_DIR}/release.c)
else()
  set(DEV_LOOP_SOURCES
    ${ENGINE_DIR}/src/devserver.c
    ${CMAKE_CURRENT_SOURCE_DIR}/bailout.c)
endif()

add_executable(${PROJECT_NAME}
  ${SNAPSHOT_S}
  ${DEV_LOOP_SOURCES}
  ${CMAKE_CURRENT_SOURCE_DIR}/heap.c
  # Product-specific C, compiled beside the dev server. The receiver (ADR-0016)
  # registers its own commands and port from a constructor, which is what lets
  # it be an ordinary app built from this template.
  ${EXTRA_SOURCES}
)
target_include_directories(${PROJECT_NAME} PRIVATE ${ENGINE_DIR}/src)
# For EXTRA_SOURCES to be configured from the outside -- the receiver builds
# twice, once into its real slot and once into a scratch one on a different
# port, and the difference is two defines rather than two source trees.
target_compile_definitions(${PROJECT_NAME} PRIVATE ${EXTRA_DEFINES})

# Link as C++: Skia, ICU and the engine are C++, and ICU is built *with*
# exceptions while Dart is -fno-exceptions, so its objects carry exception
# tables referencing __gxx_personality_v0 that only the C++ driver supplies.
set_target_properties(${PROJECT_NAME} PROPERTIES LINKER_LANGUAGE CXX)

target_link_options(${PROJECT_NAME} PRIVATE
  # Set from the outside for measurement builds. experiments/gl-usage passes
  # -Wl,--wrap=vglGetProcAddress here, which is the only way to see what an app
  # asks of vitaGL: Skia binds by name, so no link map can tell you.
  ${EXTRA_LINK_OPTIONS}

  # vita-elf-create appends ~32 KB of SCE metadata after the first LOAD segment
  # and fails if the next segment starts too soon. At 4 KiB pages the gap came
  # to 2148 bytes; 64 KiB leaves a whole page of slack.
  "-Wl,-z,max-page-size=0x10000"
  "-Wl,-z,common-page-size=0x10000"

  # Nothing calls pthread_cancel. Do not remove this.
  #
  # gcc decides a program is threaded by taking the address of a proxy symbol,
  # and outside glibc that proxy is pthread_cancel, a weak reference that pulls
  # nothing out of an archive. Without this, __gthread_active_p() returns 0 and
  # libstdc++ compiles every std::mutex::lock() in the engine to `return 0`.
  # The mutexes are never initialised, and std::condition_variable::wait, which
  # is not gated on that check, hands an uninitialised handle to pthread_cond_wait.
  "-Wl,-u,pthread_cancel"
)

# Prefer a vitaGL built from source over the VitaSDK package.
#
# FLUTTER_VITA_VITAGL points at a checkout built with
# `make HAVE_SHADER_CACHE=1 TEXTURES_SPEEDHACK=1`; patches/vitagl/README.md says
# why. Without the cache, Ganesh recompiles every shader on every launch --
# ADR-0014 measured 205 ms against ~3 ms once cached.
if(DEFINED ENV{FLUTTER_VITA_VITAGL} AND EXISTS "$ENV{FLUTTER_VITA_VITAGL}/libvitaGL.a")
  message(STATUS "vitaGL: $ENV{FLUTTER_VITA_VITAGL} (built from source)")
  set(VITAGL_LIB "$ENV{FLUTTER_VITA_VITAGL}/libvitaGL.a")
else()
  message(WARNING "vitaGL: VitaSDK package -- no shader cache, every launch recompiles")
  set(VITAGL_LIB vitaGL)
endif()

target_link_libraries(${PROJECT_NAME}
  # --whole-archive, and this is load-bearing rather than cautious. The engine
  # relies on static initialisers in translation units nothing references by
  # symbol; ordinary archive semantics pull in only members that resolve an
  # undefined reference, so a plain link succeeds and then fails at runtime.
  -Wl,--whole-archive "${ENGINE_LIB}" -Wl,--no-whole-archive

  # vitaGL and the shader compiler under it, for the GL path (ADR-0014).
  #
  # Order matters: vitaGL calls into vitashark, vitashark into SceShaccCgExt,
  # and that into taiHEN's *ForUser* hooks, which patch SceShaccCg inside this
  # process and die with it. ADR-0011 declined kernel plugins and SceShell
  # modules, not this.
  #
  # Linked unconditionally, even for a software-path app: the branch is a
  # runtime one, and a binary that cannot take it is not a fallback.
  ${VITAGL_LIB}
  vitashark
  SceShaccCg_stub
  SceShaccCgExt
  taihen_stub
  mathneon

  SceDisplay_stub SceCtrl_stub SceTouch_stub SceIofilemgr_stub
  SceNet_stub SceNetCtl_stub SceSysmodule_stub SceAppMgr_stub SceBgAppUtil_stub
  SceSysmem_stub SceLibKernel_stub SceKernelThreadMgr_stub
  ScePower_stub SceGxm_stub SceCommonDialog_stub
  # vitaGL's vgl_memcpy goes through the DMAC for anything large.
  SceKernelDmacMgr_stub
  SceIme_stub SceAppUtil_stub
  # For the receiver's `promote`, the only route by which it can replace itself.
  # A stub archive costs nothing to an app that never calls into it.
  ScePromoterUtil_stub
  # For the receiver's timestamps. The clock is whatever the console was last
  # set to, so nothing sorts by it, but it still shows two lines an hour apart.
  SceRtc_stub
  pthread m
)

vita_create_self(${PROJECT_NAME}.self ${PROJECT_NAME} UNSAFE)

# The crash supervisor, as eboot2.bin.
#
# A background application: a separate process, started by this app and
# outliving it, so a crash still leaves something listening that can bring the
# receiver back. Otherwise every crash costs a walk to the Vita and a tap.
#
# ATTRIBUTE and MEMSIZE come from Sony's background-app sample
# (Vita-Development-Suite/samples, notification-util/bootparam-bg.yml). 2 MiB is
# far more than a socket and a 16 KiB net pool need.
#
# Left out under NO_SUPERVISOR: the receiver is what the supervisor recovers to,
# so one carrying its own would contend for the same background title id and
# never stop (ADR-0016 decision 8).
if(NOT NO_SUPERVISOR)
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
# sceBgAppUtilStartBgApp looks up a second SFO beside the first to learn what it
# is starting, and without it the call cannot succeed. Same shape as Sony's
# sample: its own title id, CATEGORY gdd, ATTRIBUTE 0x1000.
#
# Only keys already in vita-mksfoex's template are set. Keys it does not know
# get appended after the sorted ones, and no Sony parser is documented to accept
# an unsorted index table.
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
endif()

# Everything the engine reads at runtime from app0:.
#
# flutter_assets is globbed because a bundle is whatever `flutter build bundle`
# produced. The glob runs at configure time, so a new asset needs a reconfigure;
# the build script reconfigures every run.
#
# kernel_blob.bin is filtered out: it is the JIT path's copy of the whole
# program, and this build links the AOT snapshot into eboot.bin (ADR-0005).
file(GLOB_RECURSE APP_ASSETS RELATIVE "${FLUTTER_ASSETS}" "${FLUTTER_ASSETS}/*")
list(FILTER APP_ASSETS EXCLUDE REGEX "kernel_blob.bin|\\.last_build_id")

set(VPK_FILES
  # The engine's receipt, so the app can say which engine produced a number.
  # framework_rev cannot: it is a git revision, identical across rebuilds, so
  # two engines differing by a patch report the same value. MANIFEST.txt carries
  # `built at`, which moves. Added after 2026-08-22, when three published figures
  # turned out to come from an engine predating the switch they measured.
  FILE "${ENGINE_DIR}/MANIFEST.txt" engine.txt
  FILE "${ENGINE_DIR}/data/icudtl.dat" icudtl.dat
  # The system font, scanned from app0:/fonts. Deliberately not inside
  # flutter_assets: that holds icon fonts looked up by asset key, and offering
  # MaterialIcons as a body-text fallback renders paragraphs in icons.
  FILE "${ENGINE_DIR}/data/Roboto-Regular.ttf" fonts/Roboto-Regular.ttf
  # Emoji. Everything in app0:/fonts is a fallback candidate for every codepoint
  # (see platform_vita.cc). Monochrome, 1.9 MB; the colour font was tried and is
  # documented in assets/fonts/README.md.
  FILE "${ENGINE_DIR}/data/NotoEmoji-Regular.ttf" fonts/NotoEmoji-Regular.ttf
  # 109 KB, and it is what "monospace" resolves to. app0:/fonts is matched by
  # the family name inside each file, so the alias table in platform_vita.cc
  # needs this present or it points at nothing.
  FILE "${ENGINE_DIR}/data/RobotoMono-Regular.ttf" fonts/RobotoMono-Regular.ttf
  # Not optional and not decoration. The SIL OFL says the notice and the
  # licence go with every copy of the font, and all three fonts above are under
  # it. See NOTICE.
  FILE "${ENGINE_DIR}/data/OFL.txt" fonts/OFL.txt
  # LiveArea art. Without it the system draws a blank placeholder that looks
  # like a corrupt install. LIVEAREA_DIR lets an app ship its own set.
  FILE "${LIVEAREA_DIR}/icon0.png" sce_sys/icon0.png
  FILE "${LIVEAREA_DIR}/template.xml" sce_sys/livearea/contents/template.xml
  FILE "${LIVEAREA_DIR}/bg0.png" sce_sys/livearea/contents/bg0.png
  FILE "${LIVEAREA_DIR}/startup.png" sce_sys/livearea/contents/startup.png
)
if(NOT NO_SUPERVISOR)
  list(APPEND VPK_FILES
    FILE "${CMAKE_CURRENT_BINARY_DIR}/fvita_supervisor.self" eboot2.bin
    FILE "${CMAKE_CURRENT_BINARY_DIR}/param2.sfo" sce_sys/param2.sfo)
endif()

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
