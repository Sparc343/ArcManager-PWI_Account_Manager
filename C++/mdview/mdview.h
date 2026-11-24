// mdview.h - tiny built-in Markdown viewer (read-only) used for the F1 help.
// Parser: cmark-gfm (BSD-2). Layout engine + design: GhostReader (layout.cpp).
#pragma once
#include <windows.h>
#include <stddef.h>

#define MDVIEW_CLASS L"ArcMdView"

// Register the window class once at start-up.
bool MdViewRegister(HINSTANCE hInst);
// Show Markdown text (UTF-8) in a view created from MDVIEW_CLASS
// (create it with WS_CHILD | WS_VISIBLE | WS_TABSTOP | WS_VSCROLL | WS_HSCROLL).
void MdViewSetMarkdown(HWND view, const char* utf8, size_t len);
// Select all text / copy the selection (also bound to Ctrl+A / Ctrl+C inside the view).
void MdViewSelectAll(HWND view);
void MdViewCopy(HWND view);
