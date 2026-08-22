cmake_minimum_required(VERSION 3.16)

if(NOT DEFINED CMAKE_TOOLCHAIN_FILE)
  if(DEFINED ENV{VITASDK})
    set(CMAKE_TOOLCHAIN_FILE "$ENV{VITASDK}/share/vita.toolchain.cmake" CACHE PATH "toolchain file")
  else()
    message(FATAL_ERROR "Define VITASDK. See docs/dev-environment.md")
  endif()
endif()

project(flutter_vita_g2 CXX)
include("${VITASDK}/share/vita.cmake" REQUIRED)

set(VITA_APP_NAME "FV Ganesh Spike")
set(VITA_TITLEID  "FVTA00002")   # the dev slot, same as every other spike
set(VITA_VERSION  "01.00")

set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -std=c++17 -Wall -O2 -fno-exceptions -fno-rtti")

# Skia's own build sets these; a consumer has to match or the headers describe
# a different library than the one in the archive. SKIA_IMPLEMENTATION is
# deliberately absent -- that one is for building Skia, not calling it.
add_compile_definitions(SK_GANESH SK_GL SK_ASSUME_GL_ES=1 NDEBUG)

# The engine source tree, not the packaged artifact: the artifact ships only
# embedder.h, and this spike calls Skia directly. That makes it a maintainer
# spike by construction, which is fine -- criterion 2 is a question about the
# engine, not about what a toolchain user can do.
set(ENGINE_SRC "${CMAKE_CURRENT_SOURCE_DIR}/../../third_party/flutter/engine/src")
if(NOT EXISTS "${ENGINE_SRC}/flutter/third_party/skia/include/core/SkSurface.h")
  message(FATAL_ERROR "No engine checkout at ${ENGINE_SRC}")
endif()
include_directories(
  "${ENGINE_SRC}"
  "${ENGINE_SRC}/flutter/third_party/skia"
)

# Default to the build tree so an engine rebuild is picked up without
# repackaging; FLUTTER_VITA_ENGINE overrides, matching the CLI.
set(ENGINE_LIB "$ENV{FLUTTER_VITA_ENGINE}")
if(ENGINE_LIB AND EXISTS "${ENGINE_LIB}/lib/libflutter_engine_vita.a")
  set(ENGINE_ARCHIVE "${ENGINE_LIB}/lib/libflutter_engine_vita.a")
else()
  # The ship target is a phony that collects objects; the archive only exists
  # once package-engine.sh has run, so this falls back to the packaged one.
  set(ENGINE_ARCHIVE "${CMAKE_CURRENT_SOURCE_DIR}/../../out/artifacts/flutter-engine-vita-3.44.8/lib/libflutter_engine_vita.a")
endif()
message(STATUS "engine archive: ${ENGINE_ARCHIVE}")

# Same local-vitaGL preference as g1: the packaged archive is built with
# HAVE_SHADER_CACHE=0, and a GPU backend that recompiles every shader on every
# launch is not one worth measuring.
set(VGL_LOCAL "${CMAKE_CURRENT_SOURCE_DIR}/../../third_party/vitaGL")
if(EXISTS "${VGL_LOCAL}/libvitaGL.a")
  message(STATUS "vitaGL: local build with shader cache")
  include_directories(BEFORE "${VGL_LOCAL}/source")
  set(VGL_LIB "${VGL_LOCAL}/libvitaGL.a")
else()
  message(STATUS "vitaGL: VitaSDK package (no shader cache)")
  set(VGL_LIB vitaGL)
endif()

add_executable(${PROJECT_NAME} src/main.cpp)

# NOT --whole-archive, and the reason is worth recording since the engine's
# MANIFEST.txt tells apps to use it.
#
# Tried, because the manifest warns that plain -l semantics drop static
# initialisers in translation units nothing references and "fails at runtime
# rather than at link time", which described this fault well. It does not link:
# whole-archive pulls in vita_embedder.cc, whose own main() collides with this
# spike's and whose dev_server and SceAppUtil dependencies are absent here.
#
# It also cannot be the explanation. The fault is *inside* the
# TextBlobRedrawCoordinator constructor, so its translation unit is demonstrably
# linked already, and the SkMessageBus Get() it calls is defined in that same
# file.
target_link_libraries(${PROJECT_NAME}
  "${ENGINE_ARCHIVE}"
  ${VGL_LIB}
  vitashark
  SceShaccCg_stub
  SceShaccCgExt
  taihen_stub
  mathneon
  SceGxm_stub
  SceDisplay_stub
  SceCommonDialog_stub
  SceAppMgr_stub
  SceCtrl_stub
  ScePower_stub
  SceKernelDmacMgr_stub
  SceIofilemgr_stub
  SceSysmodule_stub
  SceNet_stub
  SceNetCtl_stub
  stdc++
  pthread
  m
)

# Without this every std::mutex in libstdc++ is a silent no-op -- gcc decides a
# program is threaded by taking the address of pthread_cancel, a weak reference
# that pulls no archive member. Skia locks. See docs/phase-2-workplan.md.
target_link_options(${PROJECT_NAME} PRIVATE -Wl,-u,pthread_cancel)

vita_create_self(${PROJECT_NAME}.self ${PROJECT_NAME} UNSAFE)
vita_create_vpk(${PROJECT_NAME}.vpk ${VITA_TITLEID} ${PROJECT_NAME}.self
  VERSION ${VITA_VERSION}
  NAME ${VITA_APP_NAME}
)
