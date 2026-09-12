# fvita_gles2: OpenGL ES 2.0 over sceGxm. ADR-0019.
#
# Built on its own for the test app, and added with add_subdirectory by the
# app template once --gl gles2 exists there.
cmake_minimum_required(VERSION 3.16)

if(NOT DEFINED CMAKE_TOOLCHAIN_FILE)
  if(DEFINED ENV{VITASDK})
    set(CMAKE_TOOLCHAIN_FILE "$ENV{VITASDK}/share/vita.toolchain.cmake" CACHE PATH "toolchain file")
  else()
    message(FATAL_ERROR "Define VITASDK. See docs/dev-environment.md")
  endif()
endif()

project(fvita_gles2 C)

add_library(fvita_gles2 STATIC
  src/buffers.c
  src/context.c
  src/draw.c
  src/memory.c
  src/procs.c
  src/programs.c
  src/shacc.c
  src/state.c
  src/stubs.c
  src/translate.c
)
target_include_directories(fvita_gles2 PUBLIC include)
target_compile_options(fvita_gles2 PRIVATE -std=gnu11 -Wall -Wextra -O2 -g)

# What a user of the archive has to link as well. SceShaccCg is weak so an app
# still loads on a console without the compiler and fvgl_init can say why.
set(FVITA_GLES2_LIBS
  SceGxm_stub SceDisplay_stub SceKernelModulemgr_stub SceSysmem_stub
  ${VITASDK}/arm-vita-eabi/lib/libSceShaccCg_stub_weak.a
  CACHE INTERNAL "system libraries fvita_gles2 needs")
