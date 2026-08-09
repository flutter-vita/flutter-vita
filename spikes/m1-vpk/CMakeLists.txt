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

set(VITA_APP_NAME "Flutter Vita M1")
set(VITA_TITLEID  "FVTA00002")
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
    "  spikes/m1-snapshot/build.sh")
endif()

# ADR-0005 option A: the snapshot is assembled and linked in, rather than loaded
# at runtime. This is what gives .text read-execute and .bss read-write -- the
# split the VM domain cannot express, and the reason option B failed.
add_executable(${PROJECT_NAME}
  src/main.c
  src/devserver.c
  ${SNAPSHOT_S}
  ${VITA_SAMPLES_COMMON}/debugScreen.c
)

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
  SceSysmem_stub
  SceLibKernel_stub
  SceKernelThreadMgr_stub
  ScePower_stub
  pthread
  m
)

# UNSAFE so this app can write ux0:app too, which is what lets it install a new
# loader. Without it only the loader could update M1, and updating the loader
# itself would still need an FTP server.
# -u pthread_cancel is load-bearing, not housekeeping.
#
# VitaSDK has no ELF TLS, so every thread_local compiles to
# __emutls_get_address. That function asks __gthread_active_p() whether threads
# exist, and __gthread_active_p is literally "is the address of pthread_cancel
# non-null?" -- a *weak* reference. Weak undefined references do not pull a
# member out of a static archive, so pthread_cancel stayed null, emutls decided
# the program was single-threaded, and every thread_local became ONE SHARED
# GLOBAL across all threads.
#
# That is what made Thread::Current() return null: Dart_RunLoop moves the
# isolate to a worker thread, the worker writes the shared global, and the main
# thread then reads what the worker left. Forcing the symbol in flips emutls to
# the real pthread_getspecific path and fixes every thread_local at once.
target_link_options(${PROJECT_NAME} PRIVATE -u pthread_cancel)

vita_create_self(${PROJECT_NAME}.self ${PROJECT_NAME} UNSAFE)

# The four blobs ship as data files next to eboot.bin; main() reads them from
# app0:. Splitting them on the host avoids an ELF parser on the device --
# see spikes/m1-snapshot/extract-blobs.sh.
vita_create_vpk(${PROJECT_NAME}.vpk ${VITA_TITLEID} ${PROJECT_NAME}.self
  VERSION ${VITA_VERSION}
  NAME ${VITA_APP_NAME}
)
