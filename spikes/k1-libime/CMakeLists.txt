cmake_minimum_required(VERSION 3.16)

if(NOT DEFINED CMAKE_TOOLCHAIN_FILE)
  if(DEFINED ENV{VITASDK})
    set(CMAKE_TOOLCHAIN_FILE "$ENV{VITASDK}/share/vita.toolchain.cmake" CACHE PATH "toolchain file")
  else()
    message(FATAL_ERROR "Define VITASDK. See docs/dev-environment.md")
  endif()
endif()

project(flutter_vita_k1 C CXX)
include("${VITASDK}/share/vita.cmake" REQUIRED)

set(VITA_APP_NAME "Flutter Vita K1")
# The slot every app deploys into, so this goes down the same path.
set(VITA_TITLEID  "FVTA00002")
set(VITA_VERSION  "01.00")

set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} -std=gnu11 -Wall -Wextra -O2 -g")

# The same archive the apps link -- the VitaSDK package is a different build
# (see patches/vitagl/README.md), and this spike is about vitaGL's behaviour.
set(VITAGL_LIB "${CMAKE_SOURCE_DIR}/../../third_party/vitaGL/libvitaGL.a")
if(NOT EXISTS "${VITAGL_LIB}")
  message(FATAL_ERROR "No ${VITAGL_LIB} -- build it per patches/vitagl/README.md")
endif()
include_directories("${CMAKE_SOURCE_DIR}/../../third_party/vitaGL/source")

add_executable(${PROJECT_NAME} src/main.c)

# vitaGL's shader preprocessor is C++ (std::string, std::map), so the link
# needs the C++ driver even though this spike is C. Same reason as
# templates/vita-app and spikes/m1-vpk.
set_target_properties(${PROJECT_NAME} PROPERTIES LINKER_LANGUAGE CXX)

# Order matters, as in templates/vita-app: vitaGL -> vitashark -> SceShaccCgExt
# -> taiHEN's ForUser hooks.
target_link_libraries(${PROJECT_NAME}
  ${VITAGL_LIB}
  vitashark
  SceShaccCg_stub
  SceShaccCgExt
  taihen_stub
  mathneon
  SceDisplay_stub
  SceGxm_stub
  SceCommonDialog_stub
  SceIme_stub
  SceSysmodule_stub
  SceAppMgr_stub
  SceAppUtil_stub
  SceIofilemgr_stub
  SceSysmem_stub
  SceLibKernel_stub
  SceKernelThreadMgr_stub
  SceKernelDmacMgr_stub
  ScePower_stub
  SceCtrl_stub
  SceTouch_stub
  pthread
  m

  # Nothing calls pthread_cancel. gcc decides a program is threaded by taking
  # its address, and without this every std::mutex in libstdc++ compiles to a
  # no-op -- see templates/vita-app/CMakeLists.txt.
  "-Wl,-u,pthread_cancel"
)

vita_create_self(${PROJECT_NAME}.self ${PROJECT_NAME} UNSAFE)
vita_create_vpk(${PROJECT_NAME}.vpk ${VITA_TITLEID} ${PROJECT_NAME}.self
  VERSION ${VITA_VERSION}
  NAME ${VITA_APP_NAME}
)
