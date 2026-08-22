cmake_minimum_required(VERSION 3.16)

if(NOT DEFINED CMAKE_TOOLCHAIN_FILE)
  if(DEFINED ENV{VITASDK})
    set(CMAKE_TOOLCHAIN_FILE "$ENV{VITASDK}/share/vita.toolchain.cmake" CACHE PATH "toolchain file")
  else()
    message(FATAL_ERROR "Define VITASDK. See docs/dev-environment.md")
  endif()
endif()

project(flutter_vita_g1 C)
include("${VITASDK}/share/vita.cmake" REQUIRED)

set(VITA_APP_NAME "Flutter Vita GL Spike")
# FVTA00002 is the slot the dev loader installs into, so ./tools/deploy.sh
# reaches this the same way it reaches everything else.
set(VITA_TITLEID  "FVTA00002")
set(VITA_VERSION  "01.00")

set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} -std=gnu11 -Wall -Wextra -O2 -g")

include_directories(${CMAKE_SOURCE_DIR}/../../templates/vita-app)

add_executable(${PROJECT_NAME}
  src/main.c
)

# vitaGL is a static archive, which is the whole reason ADR-0004 survives this
# -- there is no shared object and no dlopen anywhere in the GPU path.
#
# Link order matters and is not obvious: vitaGL pulls SceShaccCg for the
# runtime GLSL compiler, and that in turn is what needs libshacccg.suprx
# present on the device at run time. A build that links fine here can still
# fail at vglSetupRuntimeShaderCompiler on a console without the module, which
# is exactly what this spike is for.
# mathneon and vitashark are NOT in base VitaSDK -- `vdpm mathneon vitashark`
# installs them, and a fresh machine following docs/dev-environment.md will not
# have them. That is a real, if small, cost of the GPU path: two more SDK
# packages on the critical path. vitaGL's matrices.o and splashscreen.o
# reference matmul4_neon and tanf_neon_hfp unconditionally, so this is not
# optional even though this spike never calls gluPerspective.
# Prefer a locally built vitaGL when one exists.
#
# The VitaSDK-packaged archive is built with HAVE_SHADER_CACHE=0: its
# vglSetShaderCachePath is a two-byte `bx lr` and the archive imports only
# sceIoMkdir, so it cannot write a .gxp no matter what path it is given. That
# is why an identical shader cost the same 193 ms on every link. Building
# vitaGL from source with the flag on is the only way to measure what the cache
# is worth -- see ADR-0014.
set(VGL_LOCAL "${CMAKE_CURRENT_SOURCE_DIR}/../../third_party/vitaGL")
if(EXISTS "${VGL_LOCAL}/libvitaGL.a")
  message(STATUS "vitaGL: local build with shader cache")
  include_directories(BEFORE "${VGL_LOCAL}/source")
  set(VGL_LIB "${VGL_LOCAL}/libvitaGL.a")
else()
  message(STATUS "vitaGL: VitaSDK package (no shader cache)")
  set(VGL_LIB vitaGL)
endif()

target_link_libraries(${PROJECT_NAME}
  ${VGL_LIB}
  # vitaGL's gxm.o calls shark_init/shark_end from vglInit itself, and ffp.o
  # compiles the fixed-function shaders at run time, so the runtime shader
  # compiler is not optional in the VitaSDK build of vitaGL -- it is reached
  # before any Ganesh code exists. The chain below is what that costs:
  #   libvitaGL.a        -> shark_*, sceShaccCg*
  #   libvitashark.a     -> sceShaccCgExt*
  #   libSceShaccCgExt.a -> taiHookFunctionOffsetForUser, taiInjectDataForUser
  # The taiHEN edge is the *ForUser* family, which takes no pid and so patches
  # SceShaccCg inside this process only. See ADR-0014.
  vitashark
  SceShaccCg_stub
  SceShaccCgExt
  taihen_stub
  mathneon
  SceGxm_stub
  SceDisplay_stub
  SceCommonDialog_stub
  SceAppMgr_stub
  SceCtrl_stub
  ScePower_stub
  SceKernelDmacMgr_stub
  SceIofilemgr_stub
  SceSysmodule_stub
  SceNet_stub
  SceNetCtl_stub
  stdc++
  pthread
  m
)

# vitaGL ships C++ objects (expression.o wants __gxx_personality_v0), so
# libstdc++ comes along whether this spike writes C++ or not -- and the moment
# it does, this project's standing rule applies: gcc decides a program is
# threaded by taking the address of pthread_cancel, which is a weak reference
# that pulls no archive member, and without forcing it every std::mutex in
# libstdc++ compiles to a silent no-op. See docs/phase-2-workplan.md.
target_link_options(${PROJECT_NAME} PRIVATE -Wl,-u,pthread_cancel)

# UNSAFE, and this was the bug that cost three runs.
#
# vita_create_self builds a *safe* self by default, and a safe self is confined
# no matter what the HENkaku "unsafe homebrew" setting says: ur0: is not
# readable and taiHEN's user hooks do not resolve. Both are things vglInit
# needs -- it calls shark_init, which loads ur0:data/libshacccg.suprx through
# a taiHEN-patched SceShaccCg. So vglInit returned GL_FALSE on a console with
# 182 MB free and the module correctly installed, and the failure looked like
# a platform limitation rather than a missing keyword.
#
# The loader and the Flutter app template have always built UNSAFE. Only this
# spike did not.
vita_create_self(${PROJECT_NAME}.self ${PROJECT_NAME} UNSAFE)
vita_create_vpk(${PROJECT_NAME}.vpk ${VITA_TITLEID} ${PROJECT_NAME}.self
  VERSION ${VITA_VERSION}
  NAME ${VITA_APP_NAME}
)
