cmake_minimum_required(VERSION 3.16)

if(NOT DEFINED CMAKE_TOOLCHAIN_FILE)
  if(DEFINED ENV{VITASDK})
    set(CMAKE_TOOLCHAIN_FILE "$ENV{VITASDK}/share/vita.toolchain.cmake"
        CACHE PATH "toolchain file")
  else()
    message(FATAL_ERROR "Define VITASDK. See docs/dev-environment.md")
  endif()
endif()

project(flutter_vita_updater C)
include("${VITASDK}/share/vita.cmake" REQUIRED)

set(VITA_APP_NAME "Flutter Bridge Updater")
set(VITA_TITLEID  "FVTA00009")
set(VITA_VERSION  "01.00")

set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} -std=gnu11 -Wall -Wextra -O2")

# debugScreen ships with the SDK samples rather than as a library, so it is
# referenced in place rather than vendored. It is the whole UI: this app has no
# engine and the only thing it has to say is which file it is on.
set(VITA_SAMPLES_COMMON "$ENV{VITASDK}/share/gcc-arm-vita-eabi/samples/common")
include_directories(${VITA_SAMPLES_COMMON})

add_executable(${PROJECT_NAME}
  src/main.c
  ${VITA_SAMPLES_COMMON}/debugScreen.c
)

target_link_libraries(${PROJECT_NAME}
  SceAppMgr_stub
  SceCtrl_stub
  SceDisplay_stub
  SceIofilemgr_stub
)

# UNSAFE, and that is the whole point of this app. A safe self may write its
# own ux0:data and nothing else, so the first build of this copied zero bytes
# into ux0:app/FVTA00001 and reported success at every step it could see.
vita_create_self(${PROJECT_NAME}.self ${PROJECT_NAME} UNSAFE)
vita_create_vpk(${PROJECT_NAME}.vpk ${VITA_TITLEID} ${PROJECT_NAME}.self
  VERSION ${VITA_VERSION}
  NAME ${VITA_APP_NAME}
  FILE "${CMAKE_CURRENT_SOURCE_DIR}/../../templates/vita-app/livearea/icon0.png"
       sce_sys/icon0.png
  FILE "${CMAKE_CURRENT_SOURCE_DIR}/../../templates/vita-app/livearea/template.xml"
       sce_sys/livearea/contents/template.xml
  FILE "${CMAKE_CURRENT_SOURCE_DIR}/../../templates/vita-app/livearea/bg0.png"
       sce_sys/livearea/contents/bg0.png
  FILE "${CMAKE_CURRENT_SOURCE_DIR}/../../templates/vita-app/livearea/startup.png"
       sce_sys/livearea/contents/startup.png
)
