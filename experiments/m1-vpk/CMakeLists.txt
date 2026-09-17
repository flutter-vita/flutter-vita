cmake_minimum_required(VERSION 3.16)

if(NOT DEFINED CMAKE_TOOLCHAIN_FILE)
  if(DEFINED ENV{VITASDK})
    set(CMAKE_TOOLCHAIN_FILE "$ENV{VITASDK}/share/vita.toolchain.cmake" CACHE PATH "toolchain file")
  else()
    message(FATAL_ERROR "Define VITASDK. See docs/dev-environment.md")
  endif()
endif()

project(flutter_vita_m1 C CXX ASM)
include("${VITASDK}/share/vita.cmake" REQUIRED)

# Overridable, because the promoter work needs this same app built under a
# title id the console has never seen -- registering a fresh id is the one
# thing a file copy cannot do, and testing it needs a package to register.
set(VITA_APP_NAME "Flutter Vita M1" CACHE STRING "LiveArea display name")
set(VITA_TITLEID  "FVTA00002"       CACHE STRING "nine characters")
set(VITA_VERSION  "01.00")

# -g even in Release: the debug info never reaches the device (eboot.bin is a
# stripped SELF) but vita-parse-core needs it in build/flutter_vita_m1 to
# symbolicate crash dumps. See analyse-crash.sh.
set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} -std=gnu11 -Wall -Wextra -O2 -g")

set(DART_SDK   "${CMAKE_SOURCE_DIR}/../../third_party/sdk")
set(DART_OUT   "${DART_SDK}/out/vita")
set(SNAPSHOT_S "${CMAKE_SOURCE_DIR}/../m1-snapshot/out/snapshot.S")
set(VITA_SAMPLES_COMMON "$ENV{VITASDK}/share/gcc-arm-vita-eabi/samples/common")

if(NOT EXISTS "${DART_OUT}/obj")
  message(FATAL_ERROR
    "No Dart build at ${DART_OUT}. Build it first:\n"
    "  ninja -C third_party/sdk/out/vita obj/runtime/libdart_aotruntime_product.a")
endif()

include_directories(
  "${DART_SDK}/runtime/include"
  "${DART_SDK}/runtime"
  ${VITA_SAMPLES_COMMON}
)

if(NOT EXISTS "${SNAPSHOT_S}")
  message(FATAL_ERROR
    "No snapshot at ${SNAPSHOT_S}. Generate it first:\n"
    "  experiments/m1-snapshot/build.sh")
endif()

# ADR-0005 option A: the snapshot is assembled and linked in, rather than loaded
# at runtime. This is what gives .text read-execute and .bss read-write -- the
# split the VM domain cannot express, and the reason option B failed.
# The dev server was written here and moved to the embedder's repository
# (engine/embedder, a submodule) when every app started compiling it from
# there; this experiment builds it from the same place.
set(EMBEDDER_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../../engine/embedder")
add_executable(${PROJECT_NAME}
  src/main.c
  ${EMBEDDER_DIR}/src/devserver.c
  ${SNAPSHOT_S}
  ${VITA_SAMPLES_COMMON}/debugScreen.c
)
target_include_directories(${PROJECT_NAME} PRIVATE ${EMBEDDER_DIR}/include)

# Link as C++ even though our own sources are C. Dart is built -fno-exceptions,
# but ICU is not: its objects carry exception tables referencing
# __gxx_personality_v0 and __cxa_end_cleanup, which only the C++ runtime
# provides. Linking with the C driver leaves them undefined.
set_target_properties(${PROJECT_NAME} PROPERTIES LINKER_LANGUAGE CXX)

# The Dart runtime is not archived into a single .a -- GN emits source_sets whose
# objects are linked directly. Gather them all. See docs/phase-1-workplan.md.
file(GLOB_RECURSE DART_OBJECTS "${DART_OUT}/obj/*.o")
list(LENGTH DART_OBJECTS DART_OBJECT_COUNT)
message(STATUS "Linking ${DART_OBJECT_COUNT} Dart runtime objects")

target_link_libraries(${PROJECT_NAME}
  ${DART_OBJECTS}
  SceDisplay_stub
  SceCtrl_stub
  SceIofilemgr_stub
  SceNet_stub
  SceNetCtl_stub
  SceSysmodule_stub
  SceAppMgr_stub
  SceBgAppUtil_stub
  SceSysmem_stub
  SceLibKernel_stub
  SceKernelThreadMgr_stub
  ScePower_stub
  pthread
  m
)

# UNSAFE so this app can write ux0:app too, which is what lets it install a new
# receiver. Without it only the receiver could update M1, and updating the receiver
# itself would still need an FTP server.
# -u pthread_cancel is REMOVED, and must not be restored on its own.
#
# It does what it claims: __gthread_active_p() is literally "is pthread_cancel
# non-null?", and forcing the symbol in switches emulated TLS from its
# single-threaded path (one shared global per thread_local) to the real
# pthread_getspecific path. But emutls guards its table with a *statically*
# initialised mutex, and VitaSDK's pthread does not support static mutex
# initialisers -- so the mutex is never valid and pthread_mutex_unlock faults on
# first use:
#
#   8121a098 <pthread_mutex_unlock>:
#     ldr r3, [r0, #0]
#     ldr r1, [r3, #12]   <- data abort, r3 garbage
#
# So both states are broken: without the flag thread_local is a shared global,
# with it the app crashes at startup. The real fix is to provide our own
# __emutls_get_address and stop using libgcc's -- see docs/HANDOFF.md.
vita_create_self(${PROJECT_NAME}.self ${PROJECT_NAME} UNSAFE)

# The four blobs ship as data files next to eboot.bin; main() reads them from
# app0:. Splitting them on the host avoids an ELF parser on the device --
# see experiments/m1-snapshot/extract-blobs.sh.
vita_create_vpk(${PROJECT_NAME}.vpk ${VITA_TITLEID} ${PROJECT_NAME}.self
  VERSION ${VITA_VERSION}
  NAME ${VITA_APP_NAME}
)
