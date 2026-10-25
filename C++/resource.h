// Resource IDs and program version information, shared by ArcManager.rc and main.cpp
#ifndef ARCMANAGER_RESOURCE_H
#define ARCMANAGER_RESOURCE_H

#define IDI_APPICON       1     // program icon (taskbar, title bar, Explorer)
#define IDR_DEFAULT_BG    101   // built-in default background image (PNG)

// =====================================================================================================
//  VERSION INFORMATION  (shown in Windows Explorer: right-click ArcManager.exe -> Properties -> Details)
//  >>> To release a new version, change the values below and rebuild (build.bat, or make). <<<
//  APP_VERSION_TEXT is also shown in the log and in the settings window.
// =====================================================================================================
#define APP_FILE_DESCRIPTION  "PWI Account Manager"   // "File description"
#define APP_PRODUCT_NAME      "ArcManager"            // "Product name"
#define APP_VERSION_TEXT      "v25.OCT.2026"          // "File version" AND "Product version" (any text)
#define APP_VERSION_NUMERIC   2026,10,25,0            // the same version as four numbers: year,month,day,0
#define APP_COPYRIGHT         "\251 2026 Sparc343"    // "Copyright" (\251 is the (c) sign; keep it as it is)
// Language: English (United States) - set in ArcManager.rc ("040904B0" / 0x0409,0x04B0)

#endif
