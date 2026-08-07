cmake_minimum_required(VERSION 3.16)

if(NOT DEFINED CMAKE_TOOLCHAIN_FILE)
  if(DEFINED ENV{VITASDK})
    set(CMAKE_TOOLCHAIN_FILE "$ENV{VITASDK}/share/vita.toolchain.cmake" CACHE PATH "toolchain file")
  else()
    message(FATAL_ERROR "Define VITASDK. See docs/dev-environment.md")
  endif()
endif()

project(flutter_vita_m1 C CXX)
include("${VITASDK}/share/vita.cmake" REQUIRED)

set(VITA_APP_NAME "Flutter Vita M1")
set(VITA_TITLEID  "FVTA00002")
set(VITA_VERSION  "01.00")

set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} -std=gnu11 -Wall -Wextra -O2")

set(DART_SDK   "${CMAKE_SOURCE_DIR}/../../third_party/sdk")
set(DART_OUT   "${DART_SDK}/out/vita")
set(SNAP_BLOBS "${CMAKE_SOURCE_DIR}/../m1-snapshot/out/blobs")
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

add_executable(${PROJECT_NAME}
  src/main.c
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
  SceSysmem_stub
  SceLibKernel_stub
  SceKernelThreadMgr_stub
  ScePower_stub
  pthread
  m
)

vita_create_self(${PROJECT_NAME}.self ${PROJECT_NAME})

# The four blobs ship as data files next to eboot.bin; main() reads them from
# app0:. Splitting them on the host avoids an ELF parser on the device --
# see spikes/m1-snapshot/extract-blobs.sh.
vita_create_vpk(${PROJECT_NAME}.vpk ${VITA_TITLEID} ${PROJECT_NAME}.self
  VERSION ${VITA_VERSION}
  NAME ${VITA_APP_NAME}
  FILE ${SNAP_BLOBS}/vm_snapshot_data.bin vm_snapshot_data.bin
  FILE ${SNAP_BLOBS}/isolate_snapshot_data.bin isolate_snapshot_data.bin
  FILE ${SNAP_BLOBS}/vm_snapshot_instructions.bin vm_snapshot_instructions.bin
  FILE ${SNAP_BLOBS}/isolate_snapshot_instructions.bin isolate_snapshot_instructions.bin
)
