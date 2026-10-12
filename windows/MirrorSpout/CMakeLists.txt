# Builds MirrorSpout.dll from MirrorSpout.cpp and the parts of the Spout SDK that SpoutDX needs.
# SPOUT_DIR is a checkout of https://github.com/leadedge/Spout2 (the workflow fetches it).
cmake_minimum_required(VERSION 3.20)
project(MirrorSpout CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")
if(NOT SPOUT_DIR)
    message(FATAL_ERROR "Set SPOUT_DIR to a Spout2 checkout")
endif()

set(SPOUT_GL ${SPOUT_DIR}/SPOUTSDK/SpoutGL)
set(SPOUT_DX ${SPOUT_DIR}/SPOUTSDK/SpoutDirectX/SpoutDX)

add_library(MirrorSpout SHARED
    MirrorSpout.cpp
    ${SPOUT_DX}/SpoutDX.cpp
    ${SPOUT_GL}/SpoutCopy.cpp
    ${SPOUT_GL}/SpoutDirectX.cpp
    ${SPOUT_GL}/SpoutFrameCount.cpp
    ${SPOUT_GL}/SpoutSenderNames.cpp
    ${SPOUT_GL}/SpoutSharedMemory.cpp
    ${SPOUT_GL}/SpoutUtils.cpp
)
target_include_directories(MirrorSpout PRIVATE ${SPOUT_DX} ${SPOUT_GL})
target_compile_definitions(MirrorSpout PRIVATE _CRT_SECURE_NO_WARNINGS)
target_link_libraries(MirrorSpout PRIVATE d3d11 dxgi winmm shlwapi version)
