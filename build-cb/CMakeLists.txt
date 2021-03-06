# CMake project file for tropho-abm

cmake_minimum_required (VERSION 2.6)
project (tropho2D-abm)

enable_language (Fortran)
#enable_language (C)

set (CMAKE_Fortran_COMPILER "C:/Program Files (x86)/mingw-w64/mingw32/bin/gfortran.exe")
#set (CMAKE_Fortran_COMPILER "ifort")
#set (CMAKE_C_COMPILER "icc")
#set (CMAKE_CXX_COMPILER "icpc")
message ("CMAKE_Fortran_COMPILER full path: " ${CMAKE_Fortran_COMPILER})

# make sure that the default is a RELEASE
if (NOT CMAKE_BUILD_TYPE)
  set (CMAKE_BUILD_TYPE RELEASE CACHE STRING
      "Choose the type of build, options are: None Debug Release."
      FORCE)
endif (NOT CMAKE_BUILD_TYPE)

# default installation
get_filename_component (default_prefix ".." ABSOLUTE)
set (CMAKE_INSTALL_PREFIX ${default_prefix} CACHE STRING
      "Choose the installation directory; by default it installs in the NORMA directory."
      FORCE)

# FFLAGS depend on the compiler
get_filename_component (Fortran_COMPILER_NAME ${CMAKE_Fortran_COMPILER} NAME)

message ("Fortran compiler: " ${Fortran_COMPILER_NAME})

#if (Fortran_COMPILER_NAME STREQUAL "gfortran")
#  # gfortran
#  set (CMAKE_Fortran_FLAGS_RELEASE "-funroll-all-loops -fno-f2c -O3")
#  set (CMAKE_Fortran_FLAGS_DEBUG   "-fno-f2c -O0 -g")
if (Fortran_COMPILER_NAME STREQUAL "ifort")
  # ifort (untested)
  set (CMAKE_Fortran_FLAGS_RELEASE "-O2 -fpp -fopenmp")
  #set (CMAKE_Fortran_FLAGS_DEBUG   "-f77rtl -O0 -g")
elseif (Fortran_COMPILER_NAME STREQUAL "g77")
  # g77
  set (CMAKE_Fortran_FLAGS_RELEASE "-funroll-all-loops -fno-f2c -O3 -m32")
  set (CMAKE_Fortran_FLAGS_DEBUG   "-fno-f2c -O0 -g -m32")
else (Fortran_COMPILER_NAME STREQUAL "gfortran")
  message ("CMAKE_Fortran_COMPILER full path: " ${CMAKE_Fortran_COMPILER})
  message ("Fortran compiler: " ${Fortran_COMPILER_NAME})
#  message ("No optimized Fortran compiler flags are known, we just try -O2...")
  set (CMAKE_Fortran_FLAGS_RELEASE "-O2 -cpp -ffree-line-length-none -fopenmp")
  set (CMAKE_Fortran_FLAGS_DEBUG   "-O0 -g -cpp -ffree-line-length-none -fopenmp")
  set (CMAKE_SHARED_LINKER_FLAGS "-Wl,--output-def,libtropho2D-abm.def")
endif (Fortran_COMPILER_NAME STREQUAL "ifort")

set (SOURCES 
  "../src/chemokine.f90" 
  "../src/behaviour.f90"
  "../src/global.f90"
  "../src/motility.f90"
  "../src/par_zig_mod.f90"
  "../src/tropho.f90" 
  "../src/Winsock_c.f90" 
  "../src/clientc.c"
  "../src/tcpc.c"
)

# build executables
#set (NMPROGRAMS "diagstd" "diagrtb" "proj_modes_bin" "pdbmat")
#set (EXECUTABLES "NORMA.exe" ${NMPROGRAMS})
#set (SCRIPTS "gen_pert.sh" "pert_multi_mode.sh")

add_library (tropho2D-abm SHARED ${SOURCES})
target_link_libraries(tropho2D-abm libws2_32.a libgomp.a)
#add_executable (tropho_main ../src/tropho_main.f90)
#target_link_libraries(tropho_main tropho-abm)
#set_target_properties(tropho_main PROPERTIES LINKER_LANGUAGE Fortran)

#foreach (p ${NMPROGRAMS})
#  add_executable (${p} "${p}.f")
#endforeach (p)

# install executables and scripts
#install (TARGETS ${EXECUTABLES} 
#         RUNTIME DESTINATION "bin")
#install (PROGRAMS ${SCRIPTS}
#         DESTINATION "bin") 
