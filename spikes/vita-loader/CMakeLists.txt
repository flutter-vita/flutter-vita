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
# The supervisor lives with the app template, because that is the only place it
# can be installed from -- see the comment at the top of the file. The loader
# still builds a copy: if a loader vpk is ever installed by hand through
# VitaShell, it arrives with a working supervisor rather than none.
add_executable(fvita_supervisor
  ${CMAKE_CURRENT_SOURCE_DIR}/../../templates/vita-app/supervisor.c)
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
#
# ATTRIBUTE and MEMSIZE are copied from Sony's own background-app sample
# (Vita-Development-Suite/samples, notification-util/bootparam-bg.yml, which
# carries `ATTRIBUTE: 0x3` and `APP_MEMSIZE: 0x800`). Neither is guessed and
# neither is understood: they are what a background eboot is known to be built
# with. The memory budget in particular is not cosmetic -- a background process
# cannot be handed the whole foreground app budget, and 2 MiB is far more than
# a socket and a 16 KiB net pool need.
vita_create_self(fvita_supervisor.self fvita_supervisor UNSAFE
  ATTRIBUTE 3
  MEMSIZE 0x800
)

# param2.sfo -- the manifest for eboot2.bin, and the piece that was missing.
#
# sceBgAppUtilStartBgApp does not just run eboot2.bin; the shell looks up a
# second SFO beside the first one to learn what it is starting. Without it the
# call cannot succeed no matter what mode is passed. Same shape as Sony's
# sample: its own title id, CATEGORY gdd, and ATTRIBUTE 0x1000, which is the
# bit that says "background application" (BGFTP's bg app sets it too).
#
# Only keys already in vita-mksfoex's template are set, deliberately: keys it
# does not know get appended after the sorted ones, and an SFO index table that
# is not sorted by key is a thing no Sony parser is documented to accept.
set(VITA_SUPERVISOR_TITLEID "FVTA00004")
add_custom_command(OUTPUT ${CMAKE_CURRENT_BINARY_DIR}/param2.sfo
  COMMAND ${VITA_MKSFOEX}
    -s TITLE_ID=${VITA_SUPERVISOR_TITLEID}
    -s CATEGORY=gdd
    -s APP_VER=${VITA_VERSION}
    -d ATTRIBUTE=4096
    -d ATTRIBUTE_MINOR=0
    "${VITA_APP_NAME} Supervisor"
    ${CMAKE_CURRENT_BINARY_DIR}/param2.sfo
  COMMENT "Generating param2.sfo for the supervisor"
  VERBATIM
)
vita_create_vpk(${PROJECT_NAME}.vpk ${VITA_TITLEID} ${PROJECT_NAME}.self
  FILE ${CMAKE_CURRENT_BINARY_DIR}/fvita_supervisor.self eboot2.bin
  FILE ${CMAKE_CURRENT_BINARY_DIR}/param2.sfo sce_sys/param2.sfo
  VERSION ${VITA_VERSION}
  NAME ${VITA_APP_NAME}
)
