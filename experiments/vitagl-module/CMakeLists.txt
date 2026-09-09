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
add_executable(spike_module module/src/module.c common/probe.c)
target_compile_definitions(spike_module PRIVATE PROBE_NAME=spike_shader_probe)
# The same order the applications use: vitaGL calls into vitashark, vitashark
# into SceShaccCgExt, and that into taiHEN's *ForUser hooks, which patch
# SceShaccCg inside this process. Here they are linked into the module rather
# than into the eboot, which is the whole question.
target_link_libraries(spike_module
  ${VITASDK}/arm-vita-eabi/lib/crt0.o
  # Weak, and first on the line so they win over the toolchain's strong stubs.
  #
  # sceKernelLoadStartModule refuses a module whose imported libraries are not
  # already in the process, with SCE_KERNEL_ERROR_MODULEMGR_NO_LIB (0x8002D003).
  # A main module is not held to this; a .suprx is. newlib's syscall layer
  # imports sceNetRecv, sceNetSend and sceNetSocketClose, and SceNet arrives
  # only when somebody calls sceSysmoduleLoadModule(SCE_SYSMODULE_NET), which
  # the host here never does. Weak imports are allowed to be absent.
  SceNet_stub_weak
  SceRtc_stub_weak
  vitashark
  # Weak for the same reason, and whole-archive because the symbols wanted are
  # vitashark's, not this file's, and -u for each of them is a list that goes
  # stale. SceShaccCg has ten exports, so the cost is 160 bytes.
  #
  # Weak matters twice over here. It lets the module load while libshacccg is
  # absent, which is the only order that works: vitashark's shark_init loads
  # libshacccg itself, and it returns MODULEMGR_OLD_LIB (0x8002D013) if the
  # host loaded it first.
  -Wl,--whole-archive
  ${VITASDK}/arm-vita-eabi/lib/libSceShaccCg_stub_weak.a
  -Wl,--no-whole-archive
  SceShaccCgExt
  taihen_stub
  SceLibKernel_stub
  SceProcessmgr_stub
  SceKernelModulemgr_stub
  SceSysmem_stub
)
# -nostartfiles because a module has no main: crt0 pulls one in and the link
# fails on it. -e module_start because without an entry symbol the linker warns
# and defaults to the load address.
#
# The -u flags make those four symbols undefined before the link starts, so the
# weak archives above are scanned for them and win. Without -u the weak archive
# is reached while nothing wants sceNetRecv yet, contributes nothing, and the
# toolchain's own strong SceNet_stub satisfies libc later.
set_target_properties(spike_module PROPERTIES LINK_FLAGS
  "-nostartfiles -Wl,-e,module_start \
   -Wl,-u,sceNetRecv -Wl,-u,sceNetSend -Wl,-u,sceNetSocketClose \
   -Wl,-u,sceRtcGetTime_t")

vita_create_self(spike.suprx spike_module
  CONFIG ${CMAKE_CURRENT_SOURCE_DIR}/module/exports.yml
  UNSAFE)

# The stub library the host links instead of the code. This is the whole point:
# the application carries an import, not a copy.
vita_create_stubs(stubs spike_module
  ${CMAKE_CURRENT_SOURCE_DIR}/module/exports.yml)

# -------------------------------------------------------------- the host app
# The application gets its own copy of the probe, from the same file. Running
# both in one process on one console is the only way to say whether the module
# boundary is what libshacccg objects to.
add_executable(spike_app app/src/main.c common/probe.c)
target_compile_definitions(spike_app PRIVATE PROBE_NAME=local_shader_probe)
add_dependencies(spike_app stubs)
target_link_libraries(spike_app
  ${CMAKE_CURRENT_BINARY_DIR}/stubs/libFlutterVitaSpike_stub.a
  vitashark
  SceShaccCg_stub
  SceShaccCgExt
  taihen_stub
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
