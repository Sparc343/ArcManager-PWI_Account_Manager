# Build with w64devkit (open its terminal in this folder and run: make)
# For Windows XP .. Windows 11 you MUST use the w64devkit "x86" (32-bit) kit.
# Check with:  gcc -dumpmachine     ->  i686-w64-mingw32   (32-bit, good)
#                                       x86_64-w64-mingw32 (64-bit, will NOT run on XP)

CXX      = g++
WINDRES  = windres
CXXFLAGS = -std=c++11 -Os -Wall -Wextra -ffunction-sections -fdata-sections
LDFLAGS  = -mwindows -static -static-libgcc -static-libstdc++ -s -Wl,--gc-sections
LIBS     = -luser32 -lgdi32 -lkernel32 -lcomctl32 -lole32 -lcomdlg32 -lshell32 -ladvapi32

ArcManager.exe: main.cpp ArcManager_res.o
	$(CXX) $(CXXFLAGS) main.cpp ArcManager_res.o -o $@ $(LDFLAGS) $(LIBS)

ArcManager_res.o: ArcManager.rc ArcManager.manifest resource.h res/ArcManager.ico res/default_background.png
	$(WINDRES) ArcManager.rc -O coff -o $@

clean:
	del /Q ArcManager.exe ArcManager_res.o 2>nul || rm -f ArcManager.exe ArcManager_res.o
