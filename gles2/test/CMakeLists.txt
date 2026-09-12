# The on-console tests for fvita_gles2, one milestone at a time. Installs into
# the app slot FVTA00002 so tools/deploy.sh --vpk reaches it like any app.
cmake_minimum_required(VERSION 3.16)

if(NOT DEFINED CMAKE_TOOLCHAIN_FILE)
  if(DEFINED ENV{VITASDK})
    set(CMAKE_TOOLCHAIN_FILE "$ENV{VITASDK}/share/vita.toolchain.cmake" CACHE PATH "toolchain file")
  else()
    message(FATAL_ERROR "Define VITASDK. See docs/dev-environment.md")
  endif()
endif()

project(fvita_gles2_test C)
include("${VITASDK}/share/vita.cmake" REQUIRED)

set(VITA_APP_NAME "fvita_gles2 test")
set(VITA_TITLEID  "FVTA00002")
set(VITA_VERSION  "01.00")

add_subdirectory(.. fvita_gles2)

add_executable(${PROJECT_NAME} main.c)
target_compile_options(${PROJECT_NAME} PRIVATE -std=gnu11 -Wall -Wextra -O2 -g)
target_link_libraries(${PROJECT_NAME}
  fvita_gles2
  ${FVITA_GLES2_LIBS}
  SceAppMgr_stub SceProcessmgr_stub SceLibKernel_stub SceKernelThreadMgr_stub
  SceIofilemgr_stub
)

# The shader corpus rides along, one FILE entry per shader, for M2.
file(GLOB CORPUS "${CMAKE_SOURCE_DIR}/../corpus/*.glsl")
set(CORPUS_FILES)
foreach(f ${CORPUS})
  get_filename_component(n "${f}" NAME)
  list(APPEND CORPUS_FILES FILE "${f}" "corpus/${n}")
endforeach()

vita_create_self(${PROJECT_NAME}.self ${PROJECT_NAME} UNSAFE)
vita_create_vpk(${PROJECT_NAME}.vpk ${VITA_TITLEID} ${PROJECT_NAME}.self
  VERSION ${VITA_VERSION}
  NAME ${VITA_APP_NAME}
  ${CORPUS_FILES}
  FILE ${CMAKE_SOURCE_DIR}/../../templates/vita-app/livearea/icon0.png sce_sys/icon0.png
  FILE ${CMAKE_SOURCE_DIR}/../../templates/vita-app/livearea/template.xml sce_sys/livearea/contents/template.xml
  FILE ${CMAKE_SOURCE_DIR}/../../templates/vita-app/livearea/bg0.png sce_sys/livearea/contents/bg0.png
  FILE ${CMAKE_SOURCE_DIR}/../../templates/vita-app/livearea/startup.png sce_sys/livearea/contents/startup.png
)
