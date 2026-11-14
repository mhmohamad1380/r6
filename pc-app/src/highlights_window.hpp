// The Highlights window (see highlights_window.cpp).
#pragma once
#include <windows.h>

#include "recorder.hpp"

void open_highlights_window(HINSTANCE inst, HWND owner, int dpi, rec::Recorder* recorder, const rec::Options& recorder_options);
HWND highlights_window();   // null when it is not open
