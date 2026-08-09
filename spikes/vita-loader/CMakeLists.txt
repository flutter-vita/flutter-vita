cmake_minimum_required(VERSION 3.16)

if(NOT DEFINED CMAKE_TOOLCHAIN_FILE)
  if(DEFINED ENV{VITASDK})
    set(CMAKE_TOOLCHAIN_FILE "$ENV{VITASDK}/share/vita.toolchain.cmake" CACHE PATH "toolchain file")
  else()
    message(FATAL_ERROR "Define VITASDK. See docs/dev-environment.md")
  endif()
endif()

project(flutter_vita_loader C)
include("${VITASDK}/share/vita.cmake" REQUIRED)

# Deliberately a separate title from FVTA00002. The whole point is to be a
# *different process* from the app whose eboot.bin we replace.
set(VITA_APP_NAME "Flutter Vita Loader")
set(VITA_TITLEID  "FVTA00003")
set(VITA_VERSION  "01.00")

set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} -std=gnu11 -Wall -Wextra -O2 -g")

set(VITA_SAMPLES_COMMON "$ENV{VITASDK}/share/gcc-arm-vita-eabi/samples/common")
include_directories(${VITA_SAMPLES_COMMON})

add_executable(${PROJECT_NAME}
  src/main.c
  ${VITA_SAMPLES_COMMON}/debugScreen.c
)

target_link_libraries(${PROJECT_NAME}
  SceDisplay_stub
  SceCtrl_stub
  SceIofilemgr_stub
  SceSysmem_stub
  SceLibKernel_stub
  SceKernelThreadMgr_stub
  SceNet_stub
  SceNetCtl_stub
  SceSysmodule_stub
  ScePower_stub
  SceAppMgr_stub
  ScePromoterUtil_stub
  SceBgAppUtil_stub
  taihen_stub
)

# UNSAFE, deliberately. vita_create_self builds a *safe* self by default, and a
# safe self is confined regardless of the "Enable unsafe homebrew" setting --
# ux0:app is not merely unwritable but invisible, and ScePromoterUtil's library
# is refused with MODULEMGR_NO_LIB. That confinement, not any HENkaku option,
# is what forced BGFTP into the deploy loop.
# No -u pthread_cancel here, unlike m1-vpk. This app does not link libpthread,
# so the flag would resolve to nothing, and it has no thread_local of its own.
# See spikes/m1-vpk/CMakeLists.txt for what that flag is for.
vita_create_self(${PROJECT_NAME}.self ${PROJECT_NAME} UNSAFE)
# The supervisor ships inside the same vpk as eboot2.bin, which is the file
# sceBgAppUtilStartBgApp(1) starts as a background application. It survives the
# foreground app crashing, which is the entire point.
add_executable(fvita_supervisor src/supervisor.c)
target_link_libraries(fvita_supervisor
  SceIofilemgr_stub
  SceSysmem_stub
  SceLibKernel_stub
  SceKernelThreadMgr_stub
  SceNet_stub
  SceNetCtl_stub
  SceSysmodule_stub
  SceAppMgr_stub
)
vita_create_self(fvita_supervisor.self fvita_supervisor UNSAFE)

vita_create_vpk(${PROJECT_NAME}.vpk ${VITA_TITLEID} ${PROJECT_NAME}.self
  FILE ${CMAKE_CURRENT_BINARY_DIR}/fvita_supervisor.self eboot2.bin
  VERSION ${VITA_VERSION}
  NAME ${VITA_APP_NAME}
)
