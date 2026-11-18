cmake_minimum_required(VERSION 3.15)
project(sim6502 C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
if(NOT CMAKE_BUILD_TYPE)
    set(CMAKE_BUILD_TYPE Release)
endif()

add_subdirectory(libs/vrEmu6502)
add_subdirectory(libs/vrEmu6522)

file(GLOB ST7920_SOURCES CONFIGURE_DEPENDS libs/ST7920Emulator/src/*.cpp)

find_package(SDL2 REQUIRED)

# ---- main simulator ----
add_executable(sim
    main.cpp
    ${ST7920_SOURCES}
)
target_compile_options(sim PRIVATE -Wall -Wextra)
target_include_directories(sim PRIVATE
    libs/ST7920Emulator/include
    libs/vrEmu6502/src
    libs/vrEmu6522/src
    ${SDL2_INCLUDE_DIRS}
)
target_link_libraries(sim PRIVATE
    vrEmu6502
    vrEmu6522
    ${SDL2_LIBRARIES}
)

# ---- LCD-only test ----
add_executable(lcdtest
    lcdtest.cpp
    ${ST7920_SOURCES}
)
target_include_directories(lcdtest PRIVATE
    libs/ST7920Emulator/include
    ${SDL2_INCLUDE_DIRS}
)
target_link_libraries(lcdtest PRIVATE ${SDL2_LIBRARIES})
