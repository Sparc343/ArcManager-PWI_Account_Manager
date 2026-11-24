// mdview.cpp - stripped-down, read-only Markdown view window for ArcManager's F1 help.
// Based on GhostReader (layout engine + GDI measurer/painting), trimmed to what a
// built-in README viewer needs: scrolling, text selection, copy, links, anchors.
#include "mdview.h"

#include <algorithm>
#include <cctype>
#include <cmath>
#include <cstdlib>
#include <cwchar>
#include <cstring>
#include <map>
#include <string>
#include <vector>
#include <shellapi.h>

#include "layout.h"
#include "cmark-gfm.h"
#include "cmark-gfm-core-extensions.h"

using namespace mdr;

namespace {

// ------------------------------------------------------------ GDI measurer --
class GdiMeasurer : public Measurer {
public:
    GdiMeasurer() : dc(NULL) {}
    ~GdiMeasurer() { clear(); if (dc) DeleteDC(dc); }
    void init() { dc = CreateCompatibleDC(NULL); }
    void setFaces(const std::wstring& body, const std::wstring& mono) { bodyFace = body; monoFace = mono; clear(); }

    HFONT font(const FontSpec& f) {
        std::map<FontSpec, HFONT>::iterator it = fonts.find(f);
        if (it != fonts.end()) return it->second;
        LOGFONTW lf;
        std::memset(&lf, 0, sizeof lf);
        lf.lfHeight = -f.px;
        lf.lfWeight = (f.flags & F_BOLD) ? FW_BOLD : FW_NORMAL;
        lf.lfItalic = (f.flags & F_ITALIC) ? TRUE : FALSE;
        lf.lfUnderline = (f.flags & F_UNDERLINE) ? TRUE : FALSE;
        lf.lfStrikeOut = (f.flags & F_STRIKE) ? TRUE : FALSE;
        lf.lfCharSet = DEFAULT_CHARSET;
        lf.lfOutPrecision = OUT_TT_PRECIS;
        lf.lfClipPrecision = CLIP_DEFAULT_PRECIS;
        lf.lfQuality = 5;  // CLEARTYPE_QUALITY (falls back to normal AA on old systems)
        lf.lfPitchAndFamily = (f.flags & F_MONO) ? (FIXED_PITCH | FF_MODERN) : (VARIABLE_PITCH | FF_ROMAN);
        const std::wstring& face = (f.flags & F_MONO) ? monoFace : bodyFace;
        wcsncpy(lf.lfFaceName, face.c_str(), LF_FACESIZE - 1);
        HFONT h = CreateFontIndirectW(&lf);
        fonts[f] = h;
        return h;
    }
    int textWidth(const FontSpec& f, const wchar_t* s, int n) {
        if (n <= 0) return 0;
        HGDIOBJ old = SelectObject(dc, font(f));
        SIZE sz = { 0, 0 };
        GetTextExtentPoint32W(dc, s, n, &sz);
        SelectObject(dc, old);
        return sz.cx;
    }
    FontMetrics metrics(const FontSpec& f) {
        std::map<FontSpec, FontMetrics>::iterator it = mets.find(f);
        if (it != mets.end()) return it->second;
        HGDIOBJ old = SelectObject(dc, font(f));
        TEXTMETRICW tm;
        GetTextMetricsW(dc, &tm);
        SelectObject(dc, old);
        FontMetrics m;
        m.ascent = tm.tmAscent;
        m.descent = tm.tmDescent;
        mets[f] = m;
        return m;
    }
private:
    void clear() {
        for (std::map<FontSpec, HFONT>::iterator it = fonts.begin(); it != fonts.end(); ++it) DeleteObject(it->second);
        fonts.clear();
        mets.clear();
    }
    HDC dc;
    std::wstring bodyFace, monoFace;
    std::map<FontSpec, HFONT> fonts;
    std::map<FontSpec, FontMetrics> mets;
};

// ----------------------------------------------------------------- state ----
struct View {
    HWND hwnd;
    cmark_node* doc;
    Layout layout;
    GdiMeasurer meas;
    Theme theme;
    Options opt;
    int dpi;
    int clientW, clientH;
    int scrollX, scrollY;
    TextPos selA, selB;
    bool hasSel, dragging, moved;
    POINT downPt;
    DWORD lastDblClick;
    View() : hwnd(NULL), doc(NULL), dpi(96), clientW(0), clientH(0), scrollX(0), scrollY(0),
             hasSel(false), dragging(false), moved(false), lastDblClick(0) {
        downPt.x = downPt.y = 0;
    }
};

const UINT_PTR TIMER_AUTOSCROLL = 1;

COLORREF rgb(Color c) { return RGB((c >> 16) & 255, (c >> 8) & 255, c & 255); }

int CALLBACK FaceProc(const LOGFONTW*, const TEXTMETRICW*, DWORD, LPARAM lp) {
    *(bool*)lp = true;
    return 0;
}
bool FaceExists(HDC dc, const wchar_t* face) {
    LOGFONTW lf;
    std::memset(&lf, 0, sizeof lf);
    lf.lfCharSet = DEFAULT_CHARSET;
    wcsncpy(lf.lfFaceName, face, LF_FACESIZE - 1);
    bool found = false;
    EnumFontFamiliesExW(dc, &lf, (FONTENUMPROCW)FaceProc, (LPARAM)&found, 0);
    return found;
}

View* GetView(HWND h) { return (View*)GetWindowLongPtrW(h, GWLP_USERDATA); }

int LineStep(View* v) { return std::max(16, v->opt.bodyPx * 2); }
int MaxScrollY(View* v) { return std::max(0, v->layout.contentH - v->clientH); }
int MaxScrollX(View* v) { return std::max(0, v->layout.contentW - v->clientW); }

void UpdateScrollBars(View* v) {
    SCROLLINFO si;
    si.cbSize = sizeof si;
    si.fMask = SIF_RANGE | SIF_PAGE | SIF_POS | SIF_DISABLENOSCROLL;
    si.nMin = 0;
    si.nMax = std::max(0, v->layout.contentH - 1);
    si.nPage = (UINT)std::max(0, v->clientH);
    si.nPos = v->scrollY;
    SetScrollInfo(v->hwnd, SB_VERT, &si, TRUE);
    si.nMax = std::max(0, v->layout.contentW - 1);
    si.nPage = (UINT)std::max(0, v->clientW);
    si.nPos = v->scrollX;
    SetScrollInfo(v->hwnd, SB_HORZ, &si, TRUE);
}

void SetScroll(View* v, int x, int y) {
    x = std::max(0, std::min(x, MaxScrollX(v)));
    y = std::max(0, std::min(y, MaxScrollY(v)));
    if (x == v->scrollX && y == v->scrollY) return;
    v->scrollX = x;
    v->scrollY = y;
    UpdateScrollBars(v);
    InvalidateRect(v->hwnd, NULL, FALSE);
}
void ScrollBy(View* v, int dx, int dy) { SetScroll(v, v->scrollX + dx, v->scrollY + dy); }

void ClearSelection(View* v) {
    v->hasSel = false;
    v->selA = v->selB = TextPos();
}

void Relayout(View* v) {
    if (!v->doc || v->clientW <= 0) return;
    double s = v->dpi / 96.0;
    v->opt.bodyPx = std::max(8, (int)std::floor(15 * s + 0.5));
    v->opt.codePx = std::max(8, (int)std::floor(14 * s + 0.5));
    v->opt.pageLeft = (int)std::floor(14 * s + 0.5);
    v->opt.pageRight = (int)std::floor(14 * s + 0.5);
    v->opt.pageTop = (int)std::floor(10 * s + 0.5);
    v->opt.pageBottom = (int)std::floor(24 * s + 0.5);
    v->opt.imageScale = s;
    v->opt.maxTextWidth = (int)std::floor(900 * s + 0.5);  // comfortable reading column
    buildLayout(v->layout, v->doc, v->meas, v->theme, v->opt, v->clientW);
    ClearSelection(v);
    v->scrollX = std::max(0, std::min(v->scrollX, MaxScrollX(v)));
    v->scrollY = std::max(0, std::min(v->scrollY, MaxScrollY(v)));
    UpdateScrollBars(v);
    InvalidateRect(v->hwnd, NULL, FALSE);
}

void Parse(View* v, const std::string& src) {
    if (v->doc) { cmark_node_free(v->doc); v->doc = NULL; }
    cmark_parser* p = cmark_parser_new(CMARK_OPT_DEFAULT | CMARK_OPT_VALIDATE_UTF8);
    static const char* names[] = { "table", "strikethrough", "autolink", "tasklist" };
    for (int i = 0; i < 4; i++) {
        cmark_syntax_extension* ext = cmark_find_syntax_extension(names[i]);
        if (ext) cmark_parser_attach_syntax_extension(p, ext);
    }
    cmark_parser_feed(p, src.data(), src.size());
    v->doc = cmark_parser_finish(p);
    cmark_parser_free(p);
}

// ------------------------------------------------------------------ links ---
std::string PercentDecode(const std::string& s) {
    std::string o;
    for (size_t i = 0; i < s.size(); i++) {
        if (s[i] == '%' && i + 2 < s.size() && isxdigit((unsigned char)s[i + 1]) && isxdigit((unsigned char)s[i + 2])) {
            o.push_back((char)strtol(s.substr(i + 1, 2).c_str(), NULL, 16));
            i += 2;
        } else o.push_back(s[i]);
    }
    return o;
}
bool StartsNoCase(const std::string& s, const char* p) {
    size_t n = strlen(p);
    if (s.size() < n) return false;
    for (size_t i = 0; i < n; i++)
        if (tolower((unsigned char)s[i]) != tolower((unsigned char)p[i])) return false;
    return true;
}
void ActivateLink(View* v, const std::string& url) {
    if (url.empty()) return;
    if (url[0] == '#') {
        std::string f = PercentDecode(url.substr(1));
        for (size_t i = 0; i < f.size(); i++) f[i] = (char)tolower((unsigned char)f[i]);
        std::map<std::string, int>::iterator it = v->layout.anchors.find(f);
        if (it != v->layout.anchors.end()) SetScroll(v, v->scrollX, it->second - v->opt.pageTop);
        return;
    }
    // Only web / mail links are opened (nothing local, for safety).
    if (StartsNoCase(url, "http://") || StartsNoCase(url, "https://") || StartsNoCase(url, "mailto:")) {
        std::wstring w = utf8ToWide(url.c_str(), url.size());
        ShellExecuteW(v->hwnd, L"open", w.c_str(), NULL, NULL, SW_SHOWNORMAL);
    }
}

// -------------------------------------------------------------- clipboard ---
void CopySel(View* v) {
    if (!v->hasSel) return;
    std::wstring t = selectedText(v->layout, v->selA, v->selB);
    if (t.empty()) return;
    std::wstring crlf;
    for (size_t i = 0; i < t.size(); i++) {
        if (t[i] == L'\n') crlf += L"\r\n"; else crlf.push_back(t[i]);
    }
    if (!OpenClipboard(v->hwnd)) return;
    EmptyClipboard();
    HGLOBAL mem = GlobalAlloc(GMEM_MOVEABLE, (crlf.size() + 1) * sizeof(wchar_t));
    if (mem) {
        wchar_t* p = (wchar_t*)GlobalLock(mem);
        if (p) {
            std::memcpy(p, crlf.c_str(), (crlf.size() + 1) * sizeof(wchar_t));
            GlobalUnlock(mem);
            SetClipboardData(CF_UNICODETEXT, mem);
        } else GlobalFree(mem);
    }
    CloseClipboard();
}
void SelAll(View* v) {
    TextPos a, b;
    if (startOfText(v->layout, a) && endOfText(v->layout, b)) {
        v->selA = a; v->selB = b; v->hasSel = true;
        InvalidateRect(v->hwnd, NULL, FALSE);
    }
}

// ----------------------------------------------------------------- paint ----
void FillRectColor(HDC dc, int x, int y, int w, int h, Color c) {
    if (w <= 0 || h <= 0) return;
    RECT r = { x, y, x + w, y + h };
    SetDCBrushColor(dc, rgb(c));
    FillRect(dc, &r, (HBRUSH)GetStockObject(DC_BRUSH));
}
void DrawCheck(HDC dc, int x, int y, int s, Color c, bool checked) {
    SetDCPenColor(dc, rgb(c));
    HGDIOBJ oldPen = SelectObject(dc, GetStockObject(DC_PEN));
    HGDIOBJ oldBr = SelectObject(dc, GetStockObject(NULL_BRUSH));
    Rectangle(dc, x, y, x + s, y + s);
    if (checked) {
        MoveToEx(dc, x + s / 5, y + s / 2, NULL);
        LineTo(dc, x + s * 2 / 5, y + s * 7 / 10);
        LineTo(dc, x + s * 4 / 5, y + s / 4);
    }
    SelectObject(dc, oldBr);
    SelectObject(dc, oldPen);
}

void PaintAll(View* v, HDC dc, int W, int H) {
    FillRectColor(dc, 0, 0, W, H, v->theme.background);
    SetBkMode(dc, TRANSPARENT);
    SetTextAlign(dc, TA_BASELINE | TA_LEFT | TA_NOUPDATECP);
    const int top = v->scrollY, bottom = v->scrollY + H;
    const int left = v->scrollX, right = v->scrollX + W;

    if (v->hasSel) {
        std::vector<Rect> rects;
        selectionRects(v->layout, v->meas, v->selA, v->selB, rects);
        for (size_t i = 0; i < rects.size(); i++) {
            const Rect& r = rects[i];
            if (r.y + r.h < top || r.y > bottom) continue;
            FillRectColor(dc, r.x - left, r.y - top, r.w, r.h, v->theme.selection);
        }
    }
    HGDIOBJ oldFont = GetCurrentObject(dc, OBJ_FONT);
    for (size_t i = 0; i < v->layout.items.size(); i++) {
        const Item& it = v->layout.items[i];
        if (it.y + it.h < top || it.y > bottom || it.x + it.w < left || it.x > right) continue;
        int x = it.x - left, y = it.y - top;
        switch (it.kind) {
        case IK_TEXT:
            SelectObject(dc, v->meas.font(it.font));
            SetTextColor(dc, rgb(it.color));
            ExtTextOutW(dc, x, y + it.asc, 0, NULL, it.text.c_str(), (UINT)it.text.size(), NULL);
            break;
        case IK_FILL:
            FillRectColor(dc, x, y, it.w, it.h, it.color);
            break;
        case IK_ROUND_FRAME: {
            SetDCPenColor(dc, rgb(it.color));
            HGDIOBJ op = SelectObject(dc, GetStockObject(DC_PEN));
            HGDIOBJ ob = SelectObject(dc, GetStockObject(NULL_BRUSH));
            RoundRect(dc, x, y, x + it.w, y + it.h, 6, 6);
            SelectObject(dc, ob);
            SelectObject(dc, op);
            break;
        }
        case IK_ELLIPSE_FILL:
        case IK_ELLIPSE_FRAME: {
            SetDCPenColor(dc, rgb(it.color));
            SetDCBrushColor(dc, rgb(it.color));
            HGDIOBJ op = SelectObject(dc, GetStockObject(DC_PEN));
            HGDIOBJ ob = SelectObject(dc, it.kind == IK_ELLIPSE_FILL ? GetStockObject(DC_BRUSH) : GetStockObject(NULL_BRUSH));
            Ellipse(dc, x, y, x + it.w + 1, y + it.h + 1);
            SelectObject(dc, ob);
            SelectObject(dc, op);
            break;
        }
        case IK_CHECK:
            DrawCheck(dc, x, y, it.w, it.color, it.aux != 0);
            break;
        default:
            break;  // pictures are not supported in the built-in viewer (alt text is shown)
        }
    }
    SelectObject(dc, oldFont);
}

void OnPaint(View* v) {
    PAINTSTRUCT ps;
    HDC wdc = BeginPaint(v->hwnd, &ps);
    int W = std::max(1, v->clientW), H = std::max(1, v->clientH);
    HDC mdc = CreateCompatibleDC(wdc);
    HBITMAP bmp = CreateCompatibleBitmap(wdc, W, H);
    HGDIOBJ old = SelectObject(mdc, bmp);
    PaintAll(v, mdc, W, H);
    BitBlt(wdc, 0, 0, W, H, mdc, 0, 0, SRCCOPY);
    SelectObject(mdc, old);
    DeleteObject(bmp);
    DeleteDC(mdc);
    EndPaint(v->hwnd, &ps);
}

// ------------------------------------------------------------------ mouse ---
void UpdateDragSelection(View* v, int cx, int cy) {
    TextPos p;
    if (hitText(v->layout, v->meas, cx + v->scrollX, cy + v->scrollY, p)) {
        v->selB = p;
        v->hasSel = true;
        InvalidateRect(v->hwnd, NULL, FALSE);
    }
}

void OnLButtonDown(View* v, int x, int y, bool dbl) {
    SetFocus(v->hwnd);
    TextPos p;
    if (!hitText(v->layout, v->meas, x + v->scrollX, y + v->scrollY, p)) {
        ClearSelection(v);
        InvalidateRect(v->hwnd, NULL, FALSE);
        return;
    }
    if (dbl) {
        TextPos a, b;
        wordAt(v->layout, p, a, b);
        v->lastDblClick = GetMessageTime();
        v->selA = a; v->selB = b; v->hasSel = !(a == b);
        InvalidateRect(v->hwnd, NULL, FALSE);
        return;
    }
    if (v->lastDblClick != 0 && (DWORD)GetMessageTime() - v->lastDblClick <= GetDoubleClickTime()) {
        TextPos a, b;
        blockAt(v->layout, p, a, b);
        v->lastDblClick = 0;
        v->selA = a; v->selB = b; v->hasSel = !(a == b);
        InvalidateRect(v->hwnd, NULL, FALSE);
        return;
    }
    v->selA = v->selB = p;
    v->hasSel = false;
    v->dragging = true;
    v->moved = false;
    v->downPt.x = x;
    v->downPt.y = y;
    SetCapture(v->hwnd);
    SetTimer(v->hwnd, TIMER_AUTOSCROLL, 40, NULL);
    InvalidateRect(v->hwnd, NULL, FALSE);
}
void OnMouseMove(View* v, int x, int y) {
    if (v->dragging) {
        if (std::abs(x - (int)v->downPt.x) > 3 || std::abs(y - (int)v->downPt.y) > 3) v->moved = true;
        if (v->moved) UpdateDragSelection(v, x, y);
    }
}
void OnLButtonUp(View* v, int x, int y) {
    bool wasDrag = v->dragging;
    if (v->dragging) ReleaseCapture();
    v->dragging = false;
    KillTimer(v->hwnd, TIMER_AUTOSCROLL);
    if (wasDrag && !v->moved) {
        int lk = linkAt(v->layout, x + v->scrollX, y + v->scrollY);
        ClearSelection(v);
        InvalidateRect(v->hwnd, NULL, FALSE);
        if (lk >= 0) ActivateLink(v, v->layout.links[lk]);
    }
}
LRESULT OnSetCursor(View* v, HWND hwnd, LPARAM lp) {
    if (LOWORD(lp) != HTCLIENT) return DefWindowProcW(hwnd, WM_SETCURSOR, (WPARAM)hwnd, lp);
    POINT pt;
    GetCursorPos(&pt);
    ScreenToClient(hwnd, &pt);
    int dx = pt.x + v->scrollX, dy = pt.y + v->scrollY;
    if (linkAt(v->layout, dx, dy) >= 0) { SetCursor(LoadCursorW(NULL, (LPCWSTR)IDC_HAND)); return TRUE; }
    for (size_t i = 0; i < v->layout.items.size(); i++) {
        const Item& it = v->layout.items[i];
        if (it.kind == IK_TEXT && it.selectable && dx >= it.x && dx < it.x + it.w && dy >= it.y && dy < it.y + it.h) {
            SetCursor(LoadCursorW(NULL, (LPCWSTR)IDC_IBEAM));
            return TRUE;
        }
    }
    SetCursor(LoadCursorW(NULL, (LPCWSTR)IDC_ARROW));
    return TRUE;
}

void OnScroll(View* v, int bar, WPARAM wp) {
    SCROLLINFO si;
    si.cbSize = sizeof si;
    si.fMask = SIF_ALL;
    GetScrollInfo(v->hwnd, bar, &si);
    int pos = si.nPos, page = (int)si.nPage, step = LineStep(v);
    switch (LOWORD(wp)) {
    case SB_LINEUP: pos -= step; break;
    case SB_LINEDOWN: pos += step; break;
    case SB_PAGEUP: pos -= std::max(step, page - step); break;
    case SB_PAGEDOWN: pos += std::max(step, page - step); break;
    case SB_TOP: pos = 0; break;
    case SB_BOTTOM: pos = 1 << 30; break;
    case SB_THUMBTRACK:
    case SB_THUMBPOSITION: pos = si.nTrackPos; break;
    default: return;
    }
    if (bar == SB_VERT) SetScroll(v, v->scrollX, pos); else SetScroll(v, pos, v->scrollY);
}

void OnKeyDown(View* v, WPARAM vk) {
    bool shift = (GetKeyState(VK_SHIFT) & 0x8000) != 0;
    bool ctrl = (GetKeyState(VK_CONTROL) & 0x8000) != 0;
    if (ctrl && (vk == 'C' || vk == VK_INSERT)) { CopySel(v); return; }
    if (ctrl && vk == 'A') { SelAll(v); return; }
    int page = std::max(LineStep(v), v->clientH - LineStep(v));
    switch (vk) {
    case VK_UP: ScrollBy(v, 0, -LineStep(v)); break;
    case VK_DOWN: ScrollBy(v, 0, LineStep(v)); break;
    case VK_LEFT: ScrollBy(v, -LineStep(v), 0); break;
    case VK_RIGHT: ScrollBy(v, LineStep(v), 0); break;
    case VK_PRIOR: ScrollBy(v, 0, -page); break;
    case VK_NEXT: ScrollBy(v, 0, page); break;
    case VK_SPACE: ScrollBy(v, 0, shift ? -page : page); break;
    case VK_HOME: SetScroll(v, v->scrollX, 0); break;
    case VK_END: SetScroll(v, v->scrollX, MaxScrollY(v)); break;
    }
}

// ------------------------------------------------------------ window proc ---
LRESULT CALLBACK ViewProc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
    View* v = GetView(hwnd);
    switch (msg) {
    case WM_NCCREATE: {
        View* nv = new View();
        nv->hwnd = hwnd;
        nv->theme = Theme::light();
        HDC sdc = GetDC(NULL);
        nv->dpi = GetDeviceCaps(sdc, LOGPIXELSY);
        if (nv->dpi < 48) nv->dpi = 96;
        nv->meas.init();
        nv->meas.setFaces(FaceExists(sdc, L"Segoe UI") ? L"Segoe UI" : L"Tahoma",
                          FaceExists(sdc, L"Consolas") ? L"Consolas" : L"Courier New");
        ReleaseDC(NULL, sdc);
        SetWindowLongPtrW(hwnd, GWLP_USERDATA, (LONG_PTR)nv);
        break;
    }
    case WM_NCDESTROY:
        if (v) {
            if (v->doc) cmark_node_free(v->doc);
            delete v;
            SetWindowLongPtrW(hwnd, GWLP_USERDATA, 0);
        }
        break;
    }
    if (!v) return DefWindowProcW(hwnd, msg, wp, lp);
    switch (msg) {
    case WM_GETDLGCODE: return DLGC_WANTARROWS | DLGC_WANTCHARS;
    case WM_ERASEBKGND: return 1;
    case WM_PAINT: OnPaint(v); return 0;
    case WM_SIZE:
        v->clientW = LOWORD(lp);
        v->clientH = HIWORD(lp);
        Relayout(v);
        return 0;
    case WM_VSCROLL: OnScroll(v, SB_VERT, wp); return 0;
    case WM_HSCROLL: OnScroll(v, SB_HORZ, wp); return 0;
    case WM_MOUSEWHEEL: {
        int delta = (short)HIWORD(wp);
        int lines = 3;
        SystemParametersInfoW(SPI_GETWHEELSCROLLLINES, 0, &lines, 0);
        if (lines <= 0) lines = 3;
        ScrollBy(v, 0, -delta * LineStep(v) * lines / 240);
        return 0;
    }
    case WM_SETCURSOR: return OnSetCursor(v, hwnd, lp);
    case WM_LBUTTONDOWN: OnLButtonDown(v, (short)LOWORD(lp), (short)HIWORD(lp), false); return 0;
    case WM_LBUTTONDBLCLK: OnLButtonDown(v, (short)LOWORD(lp), (short)HIWORD(lp), true); return 0;
    case WM_MOUSEMOVE: OnMouseMove(v, (short)LOWORD(lp), (short)HIWORD(lp)); return 0;
    case WM_LBUTTONUP: OnLButtonUp(v, (short)LOWORD(lp), (short)HIWORD(lp)); return 0;
    case WM_CAPTURECHANGED:
        if (v->dragging) { v->dragging = false; KillTimer(hwnd, TIMER_AUTOSCROLL); }
        return 0;
    case WM_TIMER:
        if (wp == TIMER_AUTOSCROLL && v->dragging) {
            POINT pt;
            GetCursorPos(&pt);
            ScreenToClient(hwnd, &pt);
            int dy = 0;
            if (pt.y < 0) dy = pt.y / 2 - 4;
            else if (pt.y > v->clientH) dy = (pt.y - v->clientH) / 2 + 4;
            if (dy) { ScrollBy(v, 0, dy); UpdateDragSelection(v, pt.x, pt.y); }
        }
        return 0;
    case WM_KEYDOWN: OnKeyDown(v, wp); return 0;
    case WM_SETFOCUS:
    case WM_KILLFOCUS: return 0;
    }
    return DefWindowProcW(hwnd, msg, wp, lp);
}

}  // namespace

// --------------------------------------------------------------- public API --
bool MdViewRegister(HINSTANCE hInst) {
    static bool done = false;
    if (done) return true;
    cmark_gfm_core_extensions_ensure_registered();
    WNDCLASSEXW wc;
    std::memset(&wc, 0, sizeof wc);
    wc.cbSize = sizeof wc;
    wc.style = CS_DBLCLKS;
    wc.lpfnWndProc = ViewProc;
    wc.hInstance = hInst;
    wc.hCursor = LoadCursorW(NULL, (LPCWSTR)IDC_ARROW);
    wc.lpszClassName = MDVIEW_CLASS;
    done = RegisterClassExW(&wc) != 0;
    return done;
}

void MdViewSetMarkdown(HWND h, const char* utf8, size_t len) {
    View* v = GetView(h);
    if (!v) return;
    Parse(v, std::string(utf8, len));
    v->scrollX = v->scrollY = 0;
    Relayout(v);
}
void MdViewSelectAll(HWND h) { View* v = GetView(h); if (v) SelAll(v); }
void MdViewCopy(HWND h) { View* v = GetView(h); if (v) CopySel(v); }
