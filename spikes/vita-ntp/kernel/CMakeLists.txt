cmake_minimum_required(VERSION 3.16)

if(NOT DEFINED CMAKE_TOOLCHAIN_FILE)
  if(DEFINED ENV{VITASDK})
    set(CMAKE_TOOLCHAIN_FILE "$ENV{VITASDK}/share/vita.toolchain.cmake" CACHE PATH "toolchain file")
  else()
    message(FATAL_ERROR "Define VITASDK")
  endif()
endif()

# Built as its own project, in its own directory. vita_create_self's CONFIG
# leaks to later targets in the same CMakeLists, so a kernel module and a user
# app cannot share one: the app ends up built against the module's export yml
# and fails looking for module_start.
project(vitantp_kernel C)
include("${VITASDK}/share/vita.cmake" REQUIRED)

set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} -std=gnu11 -Wall -Wextra -O2")

add_executable(vitantp_kernel main.c)
target_compile_definitions(vitantp_kernel PRIVATE __VITA_KERNEL__)
target_link_libraries(vitantp_kernel
  taihenForKernel_stub
  SceRtcForDriver_stub
  SceSysmemForDriver_stub
  gcc
)
set_target_properties(vitantp_kernel PROPERTIES LINK_FLAGS "-nostdlib")
vita_create_self(vitantp_kernel.skprx vitantp_kernel
  CONFIG ${CMAKE_SOURCE_DIR}/vitantp_kernel.yml
  UNSAFE
)
vita_create_stubs(vitantp_kernel_stubs vitantp_kernel
  ${CMAKE_SOURCE_DIR}/vitantp_kernel.yml KERNEL
)
