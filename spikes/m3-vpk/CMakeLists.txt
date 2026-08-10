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
set(VITA_TITLEID  "FVTA00004")
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
add_executable(${PROJECT_NAME}
  ${SNAPSHOT_S}
)

# Link as C++. Skia, ICU and the engine are all C++, and ICU in particular is
# built *with* exceptions while Dart is -fno-exceptions -- its objects carry
# exception tables referencing __gxx_personality_v0, which only the C++ driver
# supplies. This bit M1 and the reason is unchanged.
set_target_properties(${PROJECT_NAME} PROPERTIES LINKER_LANGUAGE CXX)

# GN emits source_sets whose objects link directly; there is no single archive
# to point at. M1 globbed ~500 objects, this globs ~2700.
#
# Note what is deliberately NOT excluded: the host-toolchain objects under
# obj/... built for macOS. They live in a separate subtree (clang_arm64/) which
# this glob does not reach, because ninja writes host output there rather than
# under obj/. If that ever changes, this glob starts feeding Mach-O objects to
# an ARM linker and the error will be spectacular rather than subtle.
file(GLOB_RECURSE ENGINE_OBJECTS "${ENGINE_OUT}/obj/*.o")
# vita_link_check has its own main(). Both it and vita_embedder.o are in the
# tree, and globbing both gives a duplicate-symbol link error that names
# `main` -- which reads as a mistake in our code rather than as two objects that
# were never meant to meet.
list(FILTER ENGINE_OBJECTS EXCLUDE REGEX "vita_link_check")

list(LENGTH ENGINE_OBJECTS ENGINE_OBJECT_COUNT)
message(STATUS "Linking ${ENGINE_OBJECT_COUNT} engine objects")

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

# icudtl.dat and flutter_assets ship as data files; vita_embedder.cc reads them
# from app0:. ICU's data is ~10 MB, which is most of the .vpk -- slimming it is
# on the Phase 2 list and has not been done.
vita_create_vpk(${PROJECT_NAME}.vpk ${VITA_TITLEID} ${PROJECT_NAME}.self
  VERSION ${VITA_VERSION}
  NAME ${VITA_APP_NAME}
  FILE ${ENGINE_OUT}/flutter_patched_sdk/platform_strong.dill platform_strong.dill
)
