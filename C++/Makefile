# Build with w64devkit (open its terminal in this folder and run: make)
# For Windows XP .. Windows 11 you MUST use the w64devkit "x86" (32-bit) kit.
# Check with:  gcc -dumpmachine     ->  i686-w64-mingw32   (32-bit, good)
#                                       x86_64-w64-mingw32 (64-bit, will NOT run on XP)
#
# main.cpp + mdview/ (the small built-in Markdown viewer for F1: layout.cpp, mdview.cpp and the
# cmark-gfm C parser in mdview/cmark-gfm/) + the resources.

CC       = gcc
CXX      = g++
WINDRES  = windres
CXXFLAGS = -std=c++11 -Os -Wall -Wextra -ffunction-sections -fdata-sections -Imdview -Imdview/cmark-gfm
CFLAGS   = -std=gnu99 -Os -w -ffunction-sections -fdata-sections -Imdview/cmark-gfm
LDFLAGS  = -mwindows -static -static-libgcc -static-libstdc++ -s -Wl,--gc-sections
LIBS     = -luser32 -lgdi32 -lkernel32 -lcomctl32 -lole32 -lcomdlg32 -lshell32 -ladvapi32

OBJDIR     = build
CMARK_SRCS = $(wildcard mdview/cmark-gfm/*.c)
CMARK_OBJS = $(patsubst mdview/cmark-gfm/%.c,$(OBJDIR)/cmark/%.o,$(CMARK_SRCS))
OBJS       = $(OBJDIR)/main.o $(OBJDIR)/layout.o $(OBJDIR)/mdview.o $(CMARK_OBJS) ArcManager_res.o

ArcManager.exe: $(OBJS)
	$(CXX) $(OBJS) -o $@ $(LDFLAGS) $(LIBS)

$(OBJDIR)/main.o: main.cpp resource.h mdview/mdview.h | $(OBJDIR)
	$(CXX) $(CXXFLAGS) -c main.cpp -o $@

$(OBJDIR)/layout.o: mdview/layout.cpp mdview/layout.h | $(OBJDIR)
	$(CXX) $(CXXFLAGS) -c mdview/layout.cpp -o $@

$(OBJDIR)/mdview.o: mdview/mdview.cpp mdview/mdview.h mdview/layout.h | $(OBJDIR)
	$(CXX) $(CXXFLAGS) -c mdview/mdview.cpp -o $@

$(OBJDIR)/cmark/%.o: mdview/cmark-gfm/%.c | $(OBJDIR)/cmark
	$(CC) $(CFLAGS) -c $< -o $@

$(OBJDIR) $(OBJDIR)/cmark:
	mkdir -p $@

ArcManager_res.o: ArcManager.rc ArcManager.manifest resource.h README.md res/ArcManager.ico res/default_background.png
	$(WINDRES) ArcManager.rc -O coff -o $@

clean:
	rm -rf $(OBJDIR) ArcManager.exe ArcManager_res.o
