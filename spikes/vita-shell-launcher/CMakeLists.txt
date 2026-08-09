cmake_minimum_required(VERSION 3.16)

if(NOT DEFINED CMAKE_TOOLCHAIN_FILE)
  if(DEFINED ENV{VITASDK})
    set(CMAKE_TOOLCHAIN_FILE "$ENV{VITASDK}/share/vita.toolchain.cmake" CACHE PATH "toolchain file")
  else()
    message(FATAL_ERROR "Define VITASDK")
  endif()
endif()

# Its own project, because vita_create_self's CONFIG leaks to later targets in
# the same CMakeLists -- see spikes/vita-ntp/README.md for what that cost.
project(fvita_launcher C)
include("${VITASDK}/share/vita.cmake" REQUIRED)

set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} -std=gnu11 -Wall -Wextra -O2 -fno-builtin")

add_executable(fvita_launcher src/main.c)

# Weak stubs and -nostdlib. This module is injected into SceShell, and it should
# add as little as possible to that process -- no libc, hence the hand-written
# string helpers in the source.
target_link_libraries(fvita_launcher
  SceNet_stub_weak
  SceNetCtl_stub_weak
  SceAppMgr_stub_weak
  SceKernelThreadMgr_stub_weak
  SceLibKernel_stub_weak
  gcc
)
set_target_properties(fvita_launcher PROPERTIES LINK_FLAGS "-nostdlib")

# A plain user module: no exports, just module_start/stop.
vita_create_self(fvita_launcher.suprx fvita_launcher
  CONFIG ${CMAKE_SOURCE_DIR}/fvita_launcher.yml
)
