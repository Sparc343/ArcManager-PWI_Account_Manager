@echo off
rem Run from the w64devkit terminal, or with w64devkit\bin on PATH.
rem Builds main.cpp + the small built-in Markdown viewer (mdview\) + the resources.
rem The cmark-gfm parser objects are only compiled once (delete the build folder to force a rebuild).
if not exist build mkdir build
if not exist build\cmark mkdir build\cmark
if not exist bin mkdir bin
windres ArcManager.rc -O coff -o build\ArcManager_res.o || goto :err
for %%f in (mdview\cmark-gfm\*.c) do (
  if not exist build\cmark\%%~nf.o (
    gcc -std=gnu99 -Os -w -ffunction-sections -fdata-sections -Imdview\cmark-gfm -c %%f -o build\cmark\%%~nf.o || goto :err
  )
)
set FLAGS=-std=c++11 -Os -Wall -Wextra -ffunction-sections -fdata-sections -Imdview -Imdview\cmark-gfm
g++ %FLAGS% -c mdview\layout.cpp -o build\layout.o || goto :err
g++ %FLAGS% -c mdview\mdview.cpp -o build\mdview.o || goto :err
g++ %FLAGS% -c main.cpp -o build\main.o || goto :err
g++ build\main.o build\layout.o build\mdview.o build\cmark\*.o build\ArcManager_res.o -o .\bin\ArcManager.exe -mwindows -static -static-libgcc -static-libstdc++ -s -Wl,--gc-sections -luser32 -lgdi32 -lkernel32 -lcomctl32 -lole32 -lcomdlg32 -lshell32 -ladvapi32 || goto :err
echo Built bin\ArcManager.exe
goto :eof
:err
echo BUILD FAILED
pause
