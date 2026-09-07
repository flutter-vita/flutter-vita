cmake_minimum_required(VERSION 3.16)

if(NOT DEFINED CMAKE_TOOLCHAIN_FILE)
  if(DEFINED ENV{VITASDK})
    set(CMAKE_TOOLCHAIN_FILE "$ENV{VITASDK}/share/vita.toolchain.cmake" CACHE PATH "toolchain file")
  else()
    message(FATAL_ERROR "Define VITASDK")
  endif()
endif()

project(vitantp C)
include("${VITASDK}/share/vita.cmake" REQUIRED)

set(VITA_APP_NAME "Vita NTP")
set(VITA_TITLEID  "FVTA00004")
set(VITA_VERSION  "01.00")
set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} -std=gnu11 -Wall -Wextra -O2 -g")

# The kernel module is a separate project under kernel/ -- see the comment
# there for why it cannot live in this file.
# The *weak* stub, deliberately. The non-weak one bakes a hard import of
# VitaNtpKernel into the app, which the receiver tries to resolve when the app
# starts -- long before the module is loaded on demand. vitacompanion can use
# the strong stub only because its kernel module is loaded at boot from
# config.txt; ours is not, by design.
set(KSTUB "${CMAKE_SOURCE_DIR}/kernel/build/libvitantp_kernel_stub_weak.a")
if(NOT EXISTS "${KSTUB}")
  message(FATAL_ERROR "Build the kernel module first:\n"
    "  cmake -S kernel -B kernel/build && cmake --build kernel/build")
endif()

# ---- user app: DNS, NTP, and driving the kernel module ----
set(VITA_SAMPLES_COMMON "$ENV{VITASDK}/share/gcc-arm-vita-eabi/samples/common")
include_directories(${VITA_SAMPLES_COMMON})

add_executable(vitantp
  src/main.c
  ${VITA_SAMPLES_COMMON}/debugScreen.c
)

target_link_libraries(vitantp
  ${KSTUB}
  taihen_stub
  SceDisplay_stub
  SceCtrl_stub
  SceIofilemgr_stub
  SceRtc_stub
  SceNet_stub
  SceNetCtl_stub
  SceSysmodule_stub
  SceLibKernel_stub
  SceKernelThreadMgr_stub
  SceSysmem_stub
)

# UNSAFE: taiLoadStartKernelModuleForUser is not available to a safe self.
vita_create_self(vitantp.self vitantp UNSAFE)
vita_create_vpk(vitantp.vpk ${VITA_TITLEID} vitantp.self
  VERSION ${VITA_VERSION}
  NAME ${VITA_APP_NAME}
)
