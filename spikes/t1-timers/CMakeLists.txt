cmake_minimum_required(VERSION 3.16)

if(NOT DEFINED CMAKE_TOOLCHAIN_FILE)
  if(DEFINED ENV{VITASDK})
    set(CMAKE_TOOLCHAIN_FILE "$ENV{VITASDK}/share/vita.toolchain.cmake" CACHE PATH "toolchain file")
  else()
    message(FATAL_ERROR "Define VITASDK. See docs/dev-environment.md")
  endif()
endif()

project(flutter_vita_t1 C)
include("${VITASDK}/share/vita.cmake" REQUIRED)

set(VITA_APP_NAME "Flutter Vita T1")
# The slot the loader installs into, so this deploys down the same path as any
# app and needs no separate install.
set(VITA_TITLEID  "FVTA00002")
set(VITA_VERSION  "01.00")

set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} -std=gnu11 -Wall -Wextra -O2 -g")

set(VITA_SAMPLES_COMMON "$ENV{VITASDK}/share/gcc-arm-vita-eabi/samples/common")
include_directories(${VITA_SAMPLES_COMMON})

add_executable(${PROJECT_NAME}
  src/main.c
  ${VITA_SAMPLES_COMMON}/debugScreen.c
)

# -Wl,-u,pthread_cancel for the same reason the engine needs it: gcc decides a
# program is threaded by taking pthread_cancel's address, which is a weak
# reference that pulls no archive member, and without it the pthread objects are
# never linked in. See docs/phase-2-workplan.md.
target_link_options(${PROJECT_NAME} PRIVATE -Wl,-u,pthread_cancel)

target_link_libraries(${PROJECT_NAME}
  pthread
  SceDisplay_stub
  SceCtrl_stub
  SceIofilemgr_stub
  SceNet_stub
  SceNetCtl_stub
  SceSysmodule_stub
  SceAppMgr_stub
  SceLibKernel_stub
  SceKernelThreadMgr_stub
  ScePower_stub
)

vita_create_self(${PROJECT_NAME}.self ${PROJECT_NAME} UNSAFE)
vita_create_vpk(${PROJECT_NAME}.vpk ${VITA_TITLEID} ${PROJECT_NAME}.self
  VERSION ${VITA_VERSION}
  NAME ${VITA_APP_NAME}
)
