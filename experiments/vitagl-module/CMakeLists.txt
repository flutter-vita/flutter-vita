cmake_minimum_required(VERSION 3.16)

if(NOT DEFINED CMAKE_TOOLCHAIN_FILE)
  if(DEFINED ENV{VITASDK})
    set(CMAKE_TOOLCHAIN_FILE "$ENV{VITASDK}/share/vita.toolchain.cmake" CACHE PATH "toolchain file")
  else()
    message(FATAL_ERROR "Define VITASDK. See docs/dev-environment.md")
  endif()
endif()

project(flutter_vita_spike_module C)
include("${VITASDK}/share/vita.cmake" REQUIRED)

set(VITA_APP_NAME "Flutter Vita Module Spike")
# FVTA00002 is the app slot and is already registered, so this needs no
# promote and costs no new bubble.
set(VITA_TITLEID  "FVTA00002")
set(VITA_VERSION  "01.00")
set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} -std=gnu11 -Wall -Wextra -O2")

# ------------------------------------------------------------------ the module
#
# Built as an ordinary executable and then turned into a .suprx by
# vita_create_self with a CONFIG. The config is what makes the difference: it
# names the entry points and the exported functions.
add_executable(spike_module module/src/module.c)
target_link_libraries(spike_module SceLibKernel_stub SceProcessmgr_stub)
# -nostartfiles because a module has no main: crt0 pulls one in and the link
# fails on it. -e module_start because without an entry symbol the linker warns
# and defaults to the load address.
set_target_properties(spike_module PROPERTIES LINK_FLAGS "-nostartfiles -Wl,-e,module_start")

vita_create_self(spike.suprx spike_module
  CONFIG ${CMAKE_CURRENT_SOURCE_DIR}/module/exports.yml
  UNSAFE)

# The stub library the host links instead of the code. This is the whole point:
# the application carries an import, not a copy.
vita_create_stubs(stubs spike_module
  ${CMAKE_CURRENT_SOURCE_DIR}/module/exports.yml)

# -------------------------------------------------------------- the host app
add_executable(spike_app app/src/main.c)
add_dependencies(spike_app stubs)
target_link_libraries(spike_app
  ${CMAKE_CURRENT_BINARY_DIR}/stubs/libFlutterVitaSpike_stub.a
  SceLibKernel_stub
  SceIofilemgr_stub
  SceAppMgr_stub
  SceKernelModulemgr_stub
)

# Reset before the application's self, and this is load-bearing.
# vita_create_self is a macro rather than a function, and its CONFIG branch
# appends `-e <exports.yml>` to VITA_ELF_CREATE_FLAGS in the caller's scope. So
# the module's export config leaks into every later call, and the application
# was rejected with "Could not find symbol 'module_start'" -- it was being built
# as a module.
set(VITA_ELF_CREATE_FLAGS "")
vita_create_self(spike_app.self spike_app UNSAFE)
vita_create_vpk(spike_app.vpk ${VITA_TITLEID} spike_app.self
  VERSION ${VITA_VERSION}
  NAME ${VITA_APP_NAME}
)
