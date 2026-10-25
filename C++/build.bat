@echo off
rem Run from the w64devkit terminal, or with w64devkit\bin on PATH.
windres ArcManager.rc -O coff -o ArcManager_res.o || goto :err
g++ -std=c++11 -Os -Wall -Wextra -ffunction-sections -fdata-sections main.cpp ArcManager_res.o -o ArcManager.exe -mwindows -static -static-libgcc -static-libstdc++ -s -Wl,--gc-sections -luser32 -lgdi32 -lkernel32 -lcomctl32 -lole32 -lcomdlg32 -lshell32 -ladvapi32 || goto :err
echo Built ArcManager.exe
goto :eof
:err
echo BUILD FAILED
pause
