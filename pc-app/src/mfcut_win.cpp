// Cutting clips with Windows' own video engine (Media Foundation), so nothing has to be installed: no ffmpeg.
// Reads the recording (MP4, or MKV on Windows 10 and newer), seeks, re-encodes the piece to H.264 + AAC in an MP4 at up to
// 720p, and saves a JPEG still for the thumbnail (Windows Imaging Component).
#ifndef UNICODE
#define UNICODE
#endif
#include <windows.h>
#include <mfapi.h>
#include <mferror.h>
#include <mfidl.h>
#include <mfreadwrite.h>
#include <propvarutil.h>
#include <wincodec.h>
#include <d3d11.h>
#include <dxgi1_2.h>
#include <audioclient.h>
#include <mmdeviceapi.h>
#include <ksmedia.h>
#include <tlhelp32.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <cstdio>
#include <filesystem>
#include <memory>
#include <mutex>
#include <thread>
#include <string>
#include <vector>

#include "platform.hpp"
#include "recorder.hpp"

namespace plat {

namespace {

template <class T> struct Com {
  T* p = nullptr;
  ~Com() { if (p) p->Release(); }
  T** operator&() { return &p; }
  T* operator->() const { return p; }
  operator T*() const { return p; }
};

// Media Foundation is looked up at run time: Windows "N" editions ship without it, and a direct link would stop the
// whole program from starting there. Without it only cutting clips is unavailable.
struct MfApi {
  HRESULT(WINAPI* startup)(ULONG, DWORD) = nullptr;
  HRESULT(WINAPI* shutdown)() = nullptr;
  HRESULT(WINAPI* createAttributes)(IMFAttributes**, UINT32) = nullptr;
  HRESULT(WINAPI* createMediaType)(IMFMediaType**) = nullptr;
  HRESULT(WINAPI* createReader)(LPCWSTR, IMFAttributes*, IMFSourceReader**) = nullptr;
  HRESULT(WINAPI* createWriter)(LPCWSTR, IMFByteStream*, IMFAttributes*, IMFSinkWriter**) = nullptr;
  HRESULT(WINAPI* createSample)(IMFSample**) = nullptr;
  HRESULT(WINAPI* createMemoryBuffer)(DWORD, IMFMediaBuffer**) = nullptr;
  bool ok() const { return startup && shutdown && createAttributes && createMediaType && createReader && createWriter && createSample && createMemoryBuffer; }
};
const MfApi& mf_api() {
  static MfApi a = [] {
    MfApi x;
    HMODULE plat = LoadLibraryW(L"mfplat.dll"), rw = LoadLibraryW(L"mfreadwrite.dll");
    if (plat) {
      x.startup = (decltype(x.startup))(void*)GetProcAddress(plat, "MFStartup");
      x.shutdown = (decltype(x.shutdown))(void*)GetProcAddress(plat, "MFShutdown");
      x.createAttributes = (decltype(x.createAttributes))(void*)GetProcAddress(plat, "MFCreateAttributes");
      x.createMediaType = (decltype(x.createMediaType))(void*)GetProcAddress(plat, "MFCreateMediaType");
      x.createSample = (decltype(x.createSample))(void*)GetProcAddress(plat, "MFCreateSample");
      x.createMemoryBuffer = (decltype(x.createMemoryBuffer))(void*)GetProcAddress(plat, "MFCreateMemoryBuffer");
    }
    if (rw) {
      x.createReader = (decltype(x.createReader))(void*)GetProcAddress(rw, "MFCreateSourceReaderFromURL");
      x.createWriter = (decltype(x.createWriter))(void*)GetProcAddress(rw, "MFCreateSinkWriterFromURL");
    }
    return x;
  }();
  return a;
}
#define MFStartup ::plat::mf_api().startup
#define MFShutdown ::plat::mf_api().shutdown
#define MFCreateAttributes ::plat::mf_api().createAttributes
#define MFCreateMediaType ::plat::mf_api().createMediaType
#define MFCreateSourceReaderFromURL ::plat::mf_api().createReader
#define MFCreateSinkWriterFromURL ::plat::mf_api().createWriter
#define MFCreateSample ::plat::mf_api().createSample
#define MFCreateMemoryBuffer ::plat::mf_api().createMemoryBuffer

struct MfSession {
  bool com = false, mf = false;
  MfSession() {
    com = SUCCEEDED(CoInitializeEx(nullptr, COINIT_MULTITHREADED));
    mf = mf_api().ok() && SUCCEEDED(MFStartup(MF_VERSION, MFSTARTUP_LITE));
  }
  ~MfSession() {
    if (mf) MFShutdown();
    if (com) CoUninitialize();
  }
};

std::string hr_text(const char* what, HRESULT hr) {
  char b[96];
  wsprintfA(b, "%s failed (0x%08lX)", what, (unsigned long)hr);
  return b;
}

#define TRY(call, what) do { HRESULT hr_ = (call); if (FAILED(hr_)) { err = hr_text(what, hr_); return false; } } while (0)

bool open_reader(const std::wstring& in, IMFSourceReader** reader, std::string& err) {
  Com<IMFAttributes> attrs;
  TRY(MFCreateAttributes(&attrs, 2), "MFCreateAttributes");
  attrs->SetUINT32(MF_SOURCE_READER_ENABLE_ADVANCED_VIDEO_PROCESSING, TRUE);   // colour conversion and resizing
  HRESULT hr = MFCreateSourceReaderFromURL(in.c_str(), attrs, reader);
  if (FAILED(hr)) {
    err = hr == MF_E_UNSUPPORTED_BYTESTREAM_TYPE ? "Windows cannot read this recording's format. (If it came from OBS: Settings > Output > Recording Format: MP4 or Hybrid MP4.)"
                                                  : hr_text("opening the recording", hr);
    return false;
  }
  return true;
}

// The source's frame size, and the size to output: at most `max_h` tall, even numbers, same shape.
bool frame_size(IMFSourceReader* r, UINT32& w, UINT32& h, UINT32& outW, UINT32& outH, int max_h, UINT32& num, UINT32& den, std::string& err) {
  Com<IMFMediaType> native;
  TRY(r->GetNativeMediaType((DWORD)MF_SOURCE_READER_FIRST_VIDEO_STREAM, 0, &native), "reading the video format");
  TRY(MFGetAttributeSize(native, MF_MT_FRAME_SIZE, &w, &h), "reading the frame size");
  if (FAILED(MFGetAttributeRatio(native, MF_MT_FRAME_RATE, &num, &den)) || !num || !den) { num = 30; den = 1; }
  outH = std::min<UINT32>(h, (UINT32)max_h) & ~1u;
  outW = (UINT32)((double)w * outH / h + 0.5) & ~1u;
  return outW > 0 && outH > 0;
}

bool seek(IMFSourceReader* r, double seconds, std::string& err) {
  PROPVARIANT pv;
  PropVariantInit(&pv);
  pv.vt = VT_I8;
  pv.hVal.QuadPart = (LONGLONG)(seconds * 1e7);
  HRESULT hr = r->SetCurrentPosition(GUID_NULL, pv);
  PropVariantClear(&pv);
  if (FAILED(hr)) { err = hr_text("seeking in the recording", hr); return false; }
  return true;
}

}  // namespace

namespace {
// Asks a reader for NV12 frames at w x h and 16-bit PCM sound. Returns whether sound is coming.
bool reader_types(IMFSourceReader* reader, UINT32 ow, UINT32 oh, UINT32 num, UINT32 den, UINT32& channels, UINT32& rate, bool fixAudio, std::string& err) {
  reader->SetStreamSelection((DWORD)MF_SOURCE_READER_ALL_STREAMS, FALSE);
  reader->SetStreamSelection((DWORD)MF_SOURCE_READER_FIRST_VIDEO_STREAM, TRUE);
  Com<IMFMediaType> vIn;
  if (FAILED(MFCreateMediaType(&vIn))) { err = "MFCreateMediaType failed"; return false; }
  vIn->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
  vIn->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_NV12);
  MFSetAttributeSize(vIn, MF_MT_FRAME_SIZE, ow, oh);
  MFSetAttributeRatio(vIn, MF_MT_FRAME_RATE, num, den);
  MFSetAttributeRatio(vIn, MF_MT_PIXEL_ASPECT_RATIO, 1, 1);
  vIn->SetUINT32(MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive);
  HRESULT hr = reader->SetCurrentMediaType((DWORD)MF_SOURCE_READER_FIRST_VIDEO_STREAM, nullptr, vIn);
  if (FAILED(hr)) { err = hr_text("decoding the video", hr); return false; }
  if (FAILED(reader->SetStreamSelection((DWORD)MF_SOURCE_READER_FIRST_AUDIO_STREAM, TRUE))) return false;
  if (!fixAudio) {
    Com<IMFMediaType> aNative;
    if (SUCCEEDED(reader->GetNativeMediaType((DWORD)MF_SOURCE_READER_FIRST_AUDIO_STREAM, 0, &aNative))) {
      channels = std::min<UINT32>(2, MFGetAttributeUINT32(aNative, MF_MT_AUDIO_NUM_CHANNELS, 2));
      rate = MFGetAttributeUINT32(aNative, MF_MT_AUDIO_SAMPLES_PER_SECOND, 48000);
    }
    if (rate != 44100 && rate != 48000) rate = 48000;   // what Windows' AAC encoder accepts
  }
  Com<IMFMediaType> aIn;
  MFCreateMediaType(&aIn);
  aIn->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Audio);
  aIn->SetGUID(MF_MT_SUBTYPE, MFAudioFormat_PCM);
  aIn->SetUINT32(MF_MT_AUDIO_NUM_CHANNELS, channels);
  aIn->SetUINT32(MF_MT_AUDIO_SAMPLES_PER_SECOND, rate);
  aIn->SetUINT32(MF_MT_AUDIO_BITS_PER_SAMPLE, 16);
  aIn->SetUINT32(MF_MT_AUDIO_BLOCK_ALIGNMENT, channels * 2);
  aIn->SetUINT32(MF_MT_AUDIO_AVG_BYTES_PER_SECOND, rate * channels * 2);
  if (FAILED(reader->SetCurrentMediaType((DWORD)MF_SOURCE_READER_FIRST_AUDIO_STREAM, nullptr, aIn))) {
    reader->SetStreamSelection((DWORD)MF_SOURCE_READER_FIRST_AUDIO_STREAM, FALSE);   // a silent clip beats no clip
    return false;
  }
  return true;
}
}  // namespace

// Cuts one clip out of one or more pieces of video, joined in order: (file, offset, length) each.
bool cut_parts(const std::vector<std::wstring>& files, const std::vector<double>& offsets, const std::vector<double>& lengths, const std::wstring& out, int max_height, std::string& err) {
  MfSession mf;
  if (!mf.mf) { err = "Windows' video engine is not available (Media Foundation is missing, as on Windows N editions without the Media Feature Pack)"; return false; }
  if (files.empty()) { err = "nothing to cut"; return false; }
  UINT32 w = 0, h = 0, ow = 0, oh = 0, num = 30, den = 1, channels = 2, rate = 48000;
  Com<IMFSinkWriter> writer;
  DWORD vs = 0, as = 0;
  bool audio = false;
  LONGLONG base = 0;   // where this piece starts in the clip
  int frames = 0;
  for (size_t i = 0; i < files.size(); i++) {
    Com<IMFSourceReader> reader;
    if (!open_reader(files[i], &reader, err)) return false;
    if (i == 0) {
      if (!frame_size(reader, w, h, ow, oh, max_height, num, den, err)) return false;
      audio = reader_types(reader, ow, oh, num, den, channels, rate, false, err);
      if (!err.empty()) return false;
      // The writer: H.264 video, AAC sound, MP4 file.
      Com<IMFAttributes> wattrs;
      MFCreateAttributes(&wattrs, 2);
      wattrs->SetUINT32(MF_READWRITE_ENABLE_HARDWARE_TRANSFORMS, TRUE);
      DeleteFileW(out.c_str());
      TRY(MFCreateSinkWriterFromURL(out.c_str(), nullptr, wattrs, &writer), "creating the clip file");
      Com<IMFMediaType> vOut, vIn;
      MFCreateMediaType(&vOut);
      vOut->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
      vOut->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_H264);
      vOut->SetUINT32(MF_MT_AVG_BITRATE, oh >= 720 ? 6000000 : 4000000);
      vOut->SetUINT32(MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive);
      vOut->SetUINT32(MF_MT_MPEG2_PROFILE, 77);   // H.264 Main profile (eAVEncH264VProfile_Main): plays on every phone
      MFSetAttributeSize(vOut, MF_MT_FRAME_SIZE, ow, oh);
      MFSetAttributeRatio(vOut, MF_MT_FRAME_RATE, num, den);
      MFSetAttributeRatio(vOut, MF_MT_PIXEL_ASPECT_RATIO, 1, 1);
      TRY(writer->AddStream(vOut, &vs), "setting up the H.264 encoder");
      reader->GetCurrentMediaType((DWORD)MF_SOURCE_READER_FIRST_VIDEO_STREAM, &vIn);
      TRY(writer->SetInputMediaType(vs, vIn, nullptr), "connecting the H.264 encoder");
      if (audio) {
        Com<IMFMediaType> aOut, aIn;
        MFCreateMediaType(&aOut);
        aOut->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Audio);
        aOut->SetGUID(MF_MT_SUBTYPE, MFAudioFormat_AAC);
        aOut->SetUINT32(MF_MT_AUDIO_NUM_CHANNELS, channels);
        aOut->SetUINT32(MF_MT_AUDIO_SAMPLES_PER_SECOND, rate);
        aOut->SetUINT32(MF_MT_AUDIO_BITS_PER_SAMPLE, 16);
        aOut->SetUINT32(MF_MT_AUDIO_AVG_BYTES_PER_SECOND, 16000);   // 128 kbit/s
        reader->GetCurrentMediaType((DWORD)MF_SOURCE_READER_FIRST_AUDIO_STREAM, &aIn);
        if (FAILED(writer->AddStream(aOut, &as)) || FAILED(writer->SetInputMediaType(as, aIn, nullptr))) { err = "setting up the AAC encoder failed"; return false; }
      }
      TRY(writer->BeginWriting(), "starting the clip file");
    } else {
      UINT32 c2 = channels, r2 = rate;
      std::string e2;
      const bool a2 = reader_types(reader, ow, oh, num, den, c2, r2, true, e2);
      if (!e2.empty()) { err = e2; return false; }
      if (audio && !a2) { err = "a later piece of the recording has no sound"; return false; }
    }
    if (!seek(reader, offsets[i], err)) return false;
    // Copy samples from offset to offset + length, moving their times to follow the pieces before.
    const LONGLONG t0 = (LONGLONG)(offsets[i] * 1e7), t1 = (LONGLONG)((offsets[i] + lengths[i]) * 1e7);
    bool vDone = false, aDone = !audio;
    while (!vDone || !aDone) {
      const DWORD stream = !vDone ? (DWORD)MF_SOURCE_READER_FIRST_VIDEO_STREAM : (DWORD)MF_SOURCE_READER_FIRST_AUDIO_STREAM;
      DWORD flags = 0;
      LONGLONG ts = 0;
      Com<IMFSample> sample;
      TRY(reader->ReadSample(stream, 0, nullptr, &flags, &ts, &sample), "reading the recording");
      bool& done = stream == (DWORD)MF_SOURCE_READER_FIRST_VIDEO_STREAM ? vDone : aDone;
      if ((flags & MF_SOURCE_READERF_ENDOFSTREAM) || ts >= t1) { done = true; continue; }
      if (!sample || ts < t0) continue;   // decoded on the way from the key frame before the offset: not part of the clip
      sample->SetSampleTime(ts - t0 + base);
      TRY(writer->WriteSample(stream == (DWORD)MF_SOURCE_READER_FIRST_VIDEO_STREAM ? vs : as, sample), "encoding the clip");
      if (stream == (DWORD)MF_SOURCE_READER_FIRST_VIDEO_STREAM) frames++;
    }
    base += t1 - t0;
  }
  TRY(writer->Finalize(), "finishing the clip file");
  if (frames == 0) { err = "the recording has no video at that time (is it shorter than the marks say?)"; DeleteFileW(out.c_str()); return false; }
  return true;
}

bool cut_video(const std::wstring& in, double start, double duration, const std::wstring& out, int max_height, std::string& err) {
  return cut_parts({in}, {start}, {duration}, out, max_height, err);
}

bool video_duration(const std::wstring& in, double& seconds, std::string& err) {
  MfSession mf;
  if (!mf.mf) { err = "Media Foundation is not available"; return false; }
  Com<IMFSourceReader> reader;
  if (!open_reader(in, &reader, err)) return false;
  PROPVARIANT pv;
  PropVariantInit(&pv);
  HRESULT hr = reader->GetPresentationAttribute((DWORD)MF_SOURCE_READER_MEDIASOURCE, MF_PD_DURATION, &pv);
  if (FAILED(hr) || pv.vt != VT_UI8) { PropVariantClear(&pv); err = hr_text("reading the video's length", hr); return false; }
  seconds = (double)pv.uhVal.QuadPart / 1e7;
  PropVariantClear(&pv);
  return true;
}

bool grab_frame_jpeg(const std::wstring& in, double at, const std::wstring& out, int height, std::string& err) {
  MfSession mf;
  if (!mf.mf) { err = "Media Foundation is not available"; return false; }
  Com<IMFSourceReader> reader;
  if (!open_reader(in, &reader, err)) return false;
  UINT32 w = 0, h = 0, ow = 0, oh = 0, num = 30, den = 1;
  if (!frame_size(reader, w, h, ow, oh, height, num, den, err)) return false;
  reader->SetStreamSelection((DWORD)MF_SOURCE_READER_ALL_STREAMS, FALSE);
  reader->SetStreamSelection((DWORD)MF_SOURCE_READER_FIRST_VIDEO_STREAM, TRUE);
  Com<IMFMediaType> t;
  MFCreateMediaType(&t);
  t->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
  t->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_RGB32);
  MFSetAttributeSize(t, MF_MT_FRAME_SIZE, ow, oh);
  TRY(reader->SetCurrentMediaType((DWORD)MF_SOURCE_READER_FIRST_VIDEO_STREAM, nullptr, t), "decoding a still");
  if (!seek(reader, at, err)) return false;
  const LONGLONG target = (LONGLONG)(at * 1e7);
  Com<IMFSample> sample;
  for (;;) {
    DWORD flags = 0;
    LONGLONG ts = 0;
    if (sample.p) { sample.p->Release(); sample.p = nullptr; }
    TRY(reader->ReadSample((DWORD)MF_SOURCE_READER_FIRST_VIDEO_STREAM, 0, nullptr, &flags, &ts, &sample), "reading a still");
    if (flags & MF_SOURCE_READERF_ENDOFSTREAM) { err = "the recording ends before that moment"; return false; }
    if (sample.p && ts >= target) break;
  }
  Com<IMFMediaBuffer> buf;
  TRY(sample->ConvertToContiguousBuffer(&buf), "reading a still");
  // Lock2D gives the first row and the pitch, which is negative for a bottom-up picture; copy into top-down rows.
  std::vector<BYTE> pixels((size_t)ow * oh * 4);
  Com<IMF2DBuffer> b2;
  if (SUCCEEDED(buf->QueryInterface(IID_PPV_ARGS(&b2)))) {
    BYTE* row0 = nullptr;
    LONG pitch = 0;
    TRY(b2->Lock2D(&row0, &pitch), "reading a still");
    for (UINT32 y = 0; y < oh; y++) memcpy(&pixels[(size_t)y * ow * 4], row0 + (LONG)y * pitch, (size_t)ow * 4);
    b2->Unlock2D();
  } else {
    BYTE* p = nullptr;
    DWORD len = 0;
    TRY(buf->Lock(&p, nullptr, &len), "reading a still");
    memcpy(pixels.data(), p, std::min<size_t>(len, pixels.size()));
    buf->Unlock();
  }

  Com<IWICImagingFactory> wic;
  TRY(CoCreateInstance(CLSID_WICImagingFactory, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&wic)), "starting the picture encoder");
  Com<IWICBitmap> bmp;
  TRY(wic->CreateBitmapFromMemory(ow, oh, GUID_WICPixelFormat32bppBGR, ow * 4, (UINT)pixels.size(), pixels.data(), &bmp), "making the still");
  Com<IWICStream> stream;
  TRY(wic->CreateStream(&stream), "making the still");
  TRY(stream->InitializeFromFilename(out.c_str(), GENERIC_WRITE), "creating the still file");
  Com<IWICBitmapEncoder> enc;
  TRY(wic->CreateEncoder(GUID_ContainerFormatJpeg, nullptr, &enc), "making the still");
  TRY(enc->Initialize(stream, WICBitmapEncoderNoCache), "making the still");
  Com<IWICBitmapFrameEncode> frame;
  Com<IPropertyBag2> props;
  TRY(enc->CreateNewFrame(&frame, &props), "making the still");
  TRY(frame->Initialize(props), "making the still");
  TRY(frame->SetSize(ow, oh), "making the still");
  WICPixelFormatGUID fmt = GUID_WICPixelFormat24bppBGR;
  TRY(frame->SetPixelFormat(&fmt), "making the still");
  TRY(frame->WriteSource(bmp, nullptr), "making the still");
  TRY(frame->Commit(), "making the still");
  TRY(enc->Commit(), "saving the still");
  return true;
}

bool start_obs(std::string& error) {
  // OBS's installer records where it is: HKLM\SOFTWARE\OBS Studio (default value).
  wchar_t dir[MAX_PATH] = {};
  DWORD size = sizeof dir;
  if (RegGetValueW(HKEY_LOCAL_MACHINE, L"SOFTWARE\\OBS Studio", nullptr, RRF_RT_REG_SZ, nullptr, dir, &size) != ERROR_SUCCESS) {
    error = "OBS Studio is not installed (obsproject.com), or not where its installer puts it. Start OBS yourself.";
    return false;
  }
  const std::wstring bin = std::wstring(dir) + L"\\bin\\64bit";
  std::wstring cmd = L"\"" + bin + L"\\obs64.exe\" --minimize-to-tray --startreplaybuffer --disable-shutdown-check";
  STARTUPINFOW si{};
  si.cb = sizeof si;
  PROCESS_INFORMATION pi{};
  if (!CreateProcessW(nullptr, cmd.data(), nullptr, nullptr, FALSE, 0, nullptr, bin.c_str(), &si, &pi)) {   // OBS needs its own folder as the working directory
    error = "OBS could not be started (error " + std::to_string(GetLastError()) + "). Start OBS yourself.";
    return false;
  }
  CloseHandle(pi.hThread);
  CloseHandle(pi.hProcess);
  return true;
}

bool process_running(const std::vector<std::wstring>& names) {
  HANDLE snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
  if (snap == INVALID_HANDLE_VALUE) return false;
  PROCESSENTRY32W e{};
  e.dwSize = sizeof e;
  bool found = false;
  for (BOOL ok = Process32FirstW(snap, &e); ok && !found; ok = Process32NextW(snap, &e))
    for (const auto& n : names) found |= _wcsicmp(e.szExeFile, n.c_str()) == 0;
  CloseHandle(snap);
  return found;
}


// ================================================================ the built-in recorder
}  // namespace plat

namespace rec {
using plat::Com;

namespace {

// KSDATAFORMAT_SUBTYPE_IEEE_FLOAT, spelled out so no extra library is needed.
const GUID kFloatAudio = {0x00000003, 0x0000, 0x0010, {0x80, 0x00, 0x00, 0xaa, 0x00, 0x38, 0x9b, 0x71}};

double wall_now() { return std::chrono::duration<double>(std::chrono::system_clock::now().time_since_epoch()).count(); }

// One clock for picture and sound: the performance counter in 100 ns units, which is also what the sound card reports.
LONGLONG qpc100() {
  static LARGE_INTEGER f = [] { LARGE_INTEGER x; QueryPerformanceFrequency(&x); return x; }();
  LARGE_INTEGER c;
  QueryPerformanceCounter(&c);
  return (LONGLONG)((c.QuadPart / f.QuadPart) * 10000000LL + (c.QuadPart % f.QuadPart) * 10000000LL / f.QuadPart);
}

struct Piece {   // one MP4 being written
  Com<IMFSinkWriter> w;
  DWORD vs = 0, as = 0;
  bool audio = false;
  std::string path;
  LONGLONG t0 = 0;        // qpc100 at its start
  double wall0 = 0;       // the same moment on the wall clock
  LONGLONG lastVideo = 0, lastAudioEnd = 0;   // qpc100
};

// BT.709 limited-range RGB -> NV12 on the processor, with scaling by nearest pixel. The fallback when the graphics
// card's video processor cannot be used.
void bgra_to_nv12(const BYTE* src, int pitch, int sw, int sh, BYTE* dst, int dw, int dh) {
  BYTE* uv = dst + dw * dh;
  for (int y = 0; y < dh; y++) {
    const BYTE* row = src + (size_t)(y * sh / dh) * pitch;
    for (int x = 0; x < dw; x++) {
      const BYTE* p = row + (size_t)(x * sw / dw) * 4;
      const int b = p[0], g = p[1], r = p[2];
      dst[y * dw + x] = (BYTE)std::min(235, std::max(16, (47 * r + 157 * g + 16 * b + 4096) >> 8));
      if (!(y & 1) && !(x & 1)) {
        uv[(y / 2) * dw + x] = (BYTE)std::min(240, std::max(16, ((-26 * r - 87 * g + 112 * b) >> 8) + 128));
        uv[(y / 2) * dw + x + 1] = (BYTE)std::min(240, std::max(16, ((112 * r - 102 * g - 10 * b) >> 8) + 128));
      }
    }
  }
}

class WinRecorder : public Recorder {
 public:
  ~WinRecorder() override { stop(); }

  bool start(const Options& o, std::string& error) override {
    if (run_) return true;
    o_ = o;
    std::error_code ec;
    std::filesystem::create_directories(o_.dir, ec);
    for (const auto& e : std::filesystem::directory_iterator(o_.dir, ec))   // pieces from an earlier run are stale
      if (e.path().extension() == L".mp4") std::filesystem::remove(e.path(), ec);
    {
      std::lock_guard<std::mutex> g(mu_);
      segments_.clear();
      status_ = "Starting the recorder...";
      failed_.clear();
    }
    run_ = true;
    ready_ = false;
    video_ = std::thread([this] { video_main(); });
    // Wait until the picture side is set up (or failed), so the caller hears about problems at once.
    for (int i = 0; i < 100 && run_ && !ready_; i++) std::this_thread::sleep_for(std::chrono::milliseconds(50));
    std::lock_guard<std::mutex> g(mu_);
    if (!failed_.empty()) { error = failed_; return false; }
    audio_ = std::thread([this] { audio_main(); });
    return true;
  }

  void stop() override {
    run_ = false;
    if (video_.joinable()) video_.join();
    if (audio_.joinable()) audio_.join();
    // Nothing is kept once recording stops: the clips were cut while it ran.
    std::vector<Segment> all;
    {
      std::lock_guard<std::mutex> g(mu_);
      all.swap(segments_);
    }
    std::error_code ec;
    for (const auto& sg : all) std::filesystem::remove(plat::from_utf8(sg.path), ec);
  }

  bool running() const override { return run_; }

  bool flush(std::string& error) override {
    if (!run_) return true;
    std::unique_lock<std::mutex> lk(mu_);
    const unsigned want = ++flushWanted_;
    flushCv_.wait_for(lk, std::chrono::seconds(10), [&] { return flushDone_ >= want || !run_; });
    if (flushDone_ < want && run_) { error = "the recorder did not finish its current minute in time"; return false; }
    return true;
  }

  std::vector<Segment> segments() override {
    std::lock_guard<std::mutex> g(mu_);
    return segments_;
  }

  std::string status() override {
    std::lock_guard<std::mutex> g(mu_);
    return status_;
  }

 private:
  Options o_;
  std::atomic<bool> run_{false}, ready_{false};
  std::thread video_, audio_;
  std::mutex mu_;                    // segments_, status_, flush counters, the current piece
  std::condition_variable flushCv_;
  unsigned flushWanted_ = 0, flushDone_ = 0;
  std::vector<Segment> segments_;
  std::string status_, failed_;
  std::unique_ptr<Piece> cur_;
  UINT32 w_ = 0, h_ = 0;             // the recorded picture size
  UINT32 rate_ = 48000, channels_ = 2;
  bool audioOn_ = false;             // sound is captured and goes into the pieces
  LONGLONG wallBaseQpc_ = 0;
  double wallBase_ = 0;

  double wall_of(LONGLONG q) const { return wallBase_ + (double)(q - wallBaseQpc_) / 1e7; }

  void set_status(const std::string& s) {
    std::lock_guard<std::mutex> g(mu_);
    status_ = s;
  }

  std::unique_ptr<Piece> open_piece(LONGLONG t, std::string& err) {
    auto p = std::make_unique<Piece>();
    p->t0 = t;
    p->wall0 = wall_of(t);
    char name[64];
    std::snprintf(name, sizeof name, "piece-%.0f.mp4", p->wall0 * 1000);
    p->path = plat::to_utf8((std::filesystem::path(o_.dir) / name).wstring());
    Com<IMFAttributes> a;
    if (FAILED(MFCreateAttributes(&a, 3))) { err = "MFCreateAttributes failed"; return nullptr; }
    a->SetUINT32(MF_READWRITE_ENABLE_HARDWARE_TRANSFORMS, TRUE);   // the graphics card's encoder when there is one
    a->SetUINT32(MF_SINK_WRITER_DISABLE_THROTTLING, TRUE);
    HRESULT hr = MFCreateSinkWriterFromURL(plat::from_utf8(p->path).c_str(), nullptr, a, &p->w);
    if (FAILED(hr)) { err = plat::hr_text("creating a recording file", hr); return nullptr; }
    Com<IMFMediaType> vOut, vIn;
    MFCreateMediaType(&vOut);
    vOut->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
    vOut->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_H264);
    vOut->SetUINT32(MF_MT_AVG_BITRATE, (UINT32)o_.bitrate);
    vOut->SetUINT32(MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive);
    vOut->SetUINT32(MF_MT_MPEG2_PROFILE, 77);
    MFSetAttributeSize(vOut, MF_MT_FRAME_SIZE, w_, h_);
    MFSetAttributeRatio(vOut, MF_MT_FRAME_RATE, (UINT32)o_.fps, 1);
    MFSetAttributeRatio(vOut, MF_MT_PIXEL_ASPECT_RATIO, 1, 1);
    hr = p->w->AddStream(vOut, &p->vs);
    if (FAILED(hr)) { err = plat::hr_text("setting up the H.264 encoder", hr); return nullptr; }
    MFCreateMediaType(&vIn);
    vIn->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
    vIn->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_NV12);
    vIn->SetUINT32(MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive);
    MFSetAttributeSize(vIn, MF_MT_FRAME_SIZE, w_, h_);
    MFSetAttributeRatio(vIn, MF_MT_FRAME_RATE, (UINT32)o_.fps, 1);
    MFSetAttributeRatio(vIn, MF_MT_PIXEL_ASPECT_RATIO, 1, 1);
    vIn->SetUINT32(MF_MT_DEFAULT_STRIDE, w_);
    hr = p->w->SetInputMediaType(p->vs, vIn, nullptr);
    if (FAILED(hr)) { err = plat::hr_text("connecting the H.264 encoder", hr); return nullptr; }
    if (audioOn_) {
      Com<IMFMediaType> aOut, aIn;
      MFCreateMediaType(&aOut);
      aOut->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Audio);
      aOut->SetGUID(MF_MT_SUBTYPE, MFAudioFormat_AAC);
      aOut->SetUINT32(MF_MT_AUDIO_NUM_CHANNELS, channels_);
      aOut->SetUINT32(MF_MT_AUDIO_SAMPLES_PER_SECOND, rate_);
      aOut->SetUINT32(MF_MT_AUDIO_BITS_PER_SAMPLE, 16);
      aOut->SetUINT32(MF_MT_AUDIO_AVG_BYTES_PER_SECOND, 20000);   // 160 kbit/s
      MFCreateMediaType(&aIn);
      aIn->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Audio);
      aIn->SetGUID(MF_MT_SUBTYPE, MFAudioFormat_PCM);
      aIn->SetUINT32(MF_MT_AUDIO_NUM_CHANNELS, channels_);
      aIn->SetUINT32(MF_MT_AUDIO_SAMPLES_PER_SECOND, rate_);
      aIn->SetUINT32(MF_MT_AUDIO_BITS_PER_SAMPLE, 16);
      aIn->SetUINT32(MF_MT_AUDIO_BLOCK_ALIGNMENT, channels_ * 2);
      aIn->SetUINT32(MF_MT_AUDIO_AVG_BYTES_PER_SECOND, rate_ * channels_ * 2);
      p->audio = SUCCEEDED(p->w->AddStream(aOut, &p->as)) && SUCCEEDED(p->w->SetInputMediaType(p->as, aIn, nullptr));
    }
    hr = p->w->BeginWriting();
    if (FAILED(hr)) { err = plat::hr_text("starting a recording file", hr); return nullptr; }
    p->lastAudioEnd = t;
    return p;
  }

  static bool write(IMFSinkWriter* w, DWORD stream, const BYTE* data, DWORD size, LONGLONG time, LONGLONG duration) {
    Com<IMFMediaBuffer> buf;
    if (FAILED(MFCreateMemoryBuffer(size, &buf))) return false;
    BYTE* dst = nullptr;
    if (FAILED(buf->Lock(&dst, nullptr, nullptr))) return false;
    if (data) memcpy(dst, data, size);
    else memset(dst, 0, size);   // silence
    buf->Unlock();
    buf->SetCurrentLength(size);
    Com<IMFSample> sm;
    if (FAILED(MFCreateSample(&sm))) return false;
    sm->AddBuffer(buf);
    sm->SetSampleTime(time);
    sm->SetSampleDuration(duration);
    return SUCCEEDED(w->WriteSample(stream, sm));
  }

  // Finishes the current piece and starts the next. Called on the picture thread.
  void rotate(LONGLONG now) {
    std::string err;
    auto next = open_piece(now, err);
    std::unique_ptr<Piece> old;
    {
      std::lock_guard<std::mutex> g(mu_);
      old = std::move(cur_);
      cur_ = std::move(next);
    }
    if (old) {
      const LONGLONG end = std::max(old->lastVideo + 10000000LL / o_.fps, old->t0);
      if (SUCCEEDED(old->w->Finalize()) && end > old->t0) {
        std::lock_guard<std::mutex> g(mu_);
        segments_.push_back({old->path, old->wall0, wall_of(end)});
      } else {
        std::error_code ec;
        std::filesystem::remove(plat::from_utf8(old->path), ec);
      }
    }
    if (!err.empty()) set_status("Recorder: " + err);
    prune();
  }

  // Keeps the recording within its time and its disk budget, oldest minutes first.
  void prune() {
    std::vector<std::string> gone;
    {
      std::lock_guard<std::mutex> g(mu_);
      std::vector<long long> sizes;
      std::error_code ec;
      for (const auto& sg : segments_) {
        const auto n = std::filesystem::file_size(plat::from_utf8(sg.path), ec);
        sizes.push_back(ec ? 0 : (long long)n);
      }
      const auto drop = to_delete(segments_, sizes, wall_now(), o_.keep_seconds, o_.max_bytes);
      std::vector<Segment> keep;
      for (size_t i = 0; i < segments_.size(); i++) {
        if (std::find(drop.begin(), drop.end(), i) != drop.end()) gone.push_back(segments_[i].path);
        else keep.push_back(segments_[i]);
      }
      segments_ = keep;
    }
    std::error_code ec;
    for (const auto& p : gone) std::filesystem::remove(plat::from_utf8(p), ec);
  }

  void video_main() {
    plat::MfSession mf;
    auto fail = [&](const std::string& m) {
      std::lock_guard<std::mutex> g(mu_);
      failed_ = m;
      status_ = "Recorder: " + m;
      run_ = false;
    };
    if (!mf.mf) return fail("Windows' video engine is not available (Media Foundation is missing)");
    SetThreadPriority(GetCurrentThread(), THREAD_PRIORITY_BELOW_NORMAL);   // the game comes first

    // The primary screen, on the graphics card that drives it.
    Com<IDXGIFactory1> factory;
    if (FAILED(CreateDXGIFactory1(IID_PPV_ARGS(&factory)))) return fail("DirectX is not available");
    Com<IDXGIAdapter1> adapter;
    Com<IDXGIOutput1> output;
    for (UINT a = 0; !output.p; a++) {
      Com<IDXGIAdapter1> ad;
      if (factory->EnumAdapters1(a, &ad) == DXGI_ERROR_NOT_FOUND) break;
      for (UINT o = 0;; o++) {
        Com<IDXGIOutput> out;
        if (ad->EnumOutputs(o, &out) == DXGI_ERROR_NOT_FOUND) break;
        DXGI_OUTPUT_DESC d;
        out->GetDesc(&d);
        if (d.AttachedToDesktop && d.DesktopCoordinates.left == 0 && d.DesktopCoordinates.top == 0) {
          out->QueryInterface(IID_PPV_ARGS(&output));
          ad->AddRef();
          adapter.p = ad.p;
          break;
        }
      }
    }
    if (!output.p) return fail("no screen found to record");
    Com<ID3D11Device> dev;
    Com<ID3D11DeviceContext> ctx;
    const D3D_FEATURE_LEVEL levels[] = {D3D_FEATURE_LEVEL_11_0, D3D_FEATURE_LEVEL_10_1, D3D_FEATURE_LEVEL_10_0};
    HRESULT hr = D3D11CreateDevice(adapter, D3D_DRIVER_TYPE_UNKNOWN, nullptr, D3D11_CREATE_DEVICE_BGRA_SUPPORT | D3D11_CREATE_DEVICE_VIDEO_SUPPORT, levels, 3, D3D11_SDK_VERSION, &dev, nullptr, &ctx);
    if (FAILED(hr)) hr = D3D11CreateDevice(adapter, D3D_DRIVER_TYPE_UNKNOWN, nullptr, D3D11_CREATE_DEVICE_BGRA_SUPPORT, levels, 3, D3D11_SDK_VERSION, &dev, nullptr, &ctx);
    if (FAILED(hr)) return fail(plat::hr_text("starting DirectX", hr));
    Com<IDXGIOutputDuplication> dup;
    auto duplicate = [&]() -> HRESULT {
      if (dup.p) { dup.p->Release(); dup.p = nullptr; }
      return output->DuplicateOutput(dev, &dup);
    };
    hr = duplicate();
    if (FAILED(hr)) return fail(hr == E_ACCESSDENIED ? "Windows did not allow screen capture right now (a secure screen is open)" :
                                hr == DXGI_ERROR_UNSUPPORTED ? "this graphics setup does not support screen capture (on a laptop, try running the uploader on the same graphics card as the screen)" :
                                plat::hr_text("starting screen capture", hr));
    DXGI_OUTDUPL_DESC dd;
    dup->GetDesc(&dd);
    const UINT sw = dd.ModeDesc.Width, sh = dd.ModeDesc.Height;
    h_ = std::min<UINT>(sh, (UINT)o_.height) & ~1u;
    w_ = (UINT)((double)sw * h_ / sh + 0.5) & ~1u;

    // The screen copy, and the graphics card's video processor to scale it and turn it into NV12 for the encoder.
    D3D11_TEXTURE2D_DESC td{};
    td.Width = sw; td.Height = sh; td.MipLevels = 1; td.ArraySize = 1; td.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
    td.SampleDesc.Count = 1; td.Usage = D3D11_USAGE_DEFAULT; td.BindFlags = D3D11_BIND_RENDER_TARGET | D3D11_BIND_SHADER_RESOURCE;
    Com<ID3D11Texture2D> screen;
    if (FAILED(dev->CreateTexture2D(&td, nullptr, &screen))) return fail("could not make a picture buffer");
    Com<ID3D11VideoDevice> vdev;
    Com<ID3D11VideoContext> vctx;
    Com<ID3D11VideoProcessorEnumerator> venum;
    Com<ID3D11VideoProcessor> vp;
    Com<ID3D11VideoProcessorInputView> vin;
    Com<ID3D11VideoProcessorOutputView> vout;
    Com<ID3D11Texture2D> nv12, stage;
    bool gpu = SUCCEEDED(dev->QueryInterface(IID_PPV_ARGS(&vdev))) && SUCCEEDED(ctx->QueryInterface(IID_PPV_ARGS(&vctx)));
    if (gpu) {
      D3D11_VIDEO_PROCESSOR_CONTENT_DESC cd{};
      cd.InputFrameFormat = D3D11_VIDEO_FRAME_FORMAT_PROGRESSIVE;
      cd.InputWidth = sw; cd.InputHeight = sh; cd.OutputWidth = w_; cd.OutputHeight = h_;
      cd.InputFrameRate = {(UINT)o_.fps, 1}; cd.OutputFrameRate = {(UINT)o_.fps, 1};
      cd.Usage = D3D11_VIDEO_USAGE_PLAYBACK_NORMAL;
      D3D11_TEXTURE2D_DESC nd{};
      nd.Width = w_; nd.Height = h_; nd.MipLevels = 1; nd.ArraySize = 1; nd.Format = DXGI_FORMAT_NV12; nd.SampleDesc.Count = 1;
      nd.Usage = D3D11_USAGE_DEFAULT; nd.BindFlags = D3D11_BIND_RENDER_TARGET;
      D3D11_TEXTURE2D_DESC sd = nd;
      sd.Usage = D3D11_USAGE_STAGING; sd.BindFlags = 0; sd.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
      D3D11_VIDEO_PROCESSOR_INPUT_VIEW_DESC ivd{};
      ivd.ViewDimension = D3D11_VPIV_DIMENSION_TEXTURE2D;
      D3D11_VIDEO_PROCESSOR_OUTPUT_VIEW_DESC ovd{};
      ovd.ViewDimension = D3D11_VPOV_DIMENSION_TEXTURE2D;
      gpu = SUCCEEDED(vdev->CreateVideoProcessorEnumerator(&cd, &venum)) && SUCCEEDED(vdev->CreateVideoProcessor(venum, 0, &vp)) &&
            SUCCEEDED(dev->CreateTexture2D(&nd, nullptr, &nv12)) && SUCCEEDED(dev->CreateTexture2D(&sd, nullptr, &stage)) &&
            SUCCEEDED(vdev->CreateVideoProcessorInputView(screen, venum, &ivd, &vin)) && SUCCEEDED(vdev->CreateVideoProcessorOutputView(nv12, venum, &ovd, &vout));
    }
    if (!gpu) {   // the processor does the conversion instead: read the whole screen back
      if (stage.p) { stage.p->Release(); stage.p = nullptr; }
      D3D11_TEXTURE2D_DESC sd = td;
      sd.Usage = D3D11_USAGE_STAGING; sd.BindFlags = 0; sd.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
      if (FAILED(dev->CreateTexture2D(&sd, nullptr, &stage))) return fail("could not make a picture buffer");
    }
    std::vector<BYTE> frame((size_t)w_ * h_ * 3 / 2, 0);
    for (size_t i = (size_t)w_ * h_; i < frame.size(); i++) frame[i] = 128;   // black until the first picture

    wallBaseQpc_ = qpc100();
    wallBase_ = wall_now();
    // Sound settings must be known before the first piece opens.
    probe_audio();
    std::string err;
    {
      auto first = open_piece(qpc100(), err);
      if (!first) return fail(err);
      std::lock_guard<std::mutex> g(mu_);
      cur_ = std::move(first);
      status_ = "Recorder: recording the screen at " + std::to_string(w_) + "x" + std::to_string(h_) + ", " + std::to_string(o_.fps) + " fps" +
                (gpu ? "" : " (picture converted on the processor)") + (audioOn_ ? ", with sound." : ", without sound.");
    }
    ready_ = true;

    const LONGLONG period = 10000000LL / o_.fps;
    LONGLONG next = qpc100();
    bool fresh = false;
    while (run_) {
      // Take the newest screen picture, if the screen changed.
      DXGI_OUTDUPL_FRAME_INFO fi;
      Com<IDXGIResource> res;
      hr = dup->AcquireNextFrame(0, &fi, &res);
      if (SUCCEEDED(hr)) {
        Com<ID3D11Texture2D> tex;
        if (SUCCEEDED(res->QueryInterface(IID_PPV_ARGS(&tex)))) ctx->CopyResource(screen, tex);
        dup->ReleaseFrame();
        fresh = true;
      } else if (hr == DXGI_ERROR_ACCESS_LOST) {   // the screen mode changed, or a full-screen game took over: start again
        std::this_thread::sleep_for(std::chrono::milliseconds(200));
        duplicate();
      }
      if (fresh) {
        fresh = false;
        D3D11_MAPPED_SUBRESOURCE m;
        if (gpu) {
          D3D11_VIDEO_PROCESSOR_STREAM st{};
          st.Enable = TRUE;
          st.pInputSurface = vin;
          if (SUCCEEDED(vctx->VideoProcessorBlt(vp, vout, 0, 1, &st))) {
            ctx->CopyResource(stage, nv12);
            if (SUCCEEDED(ctx->Map(stage, 0, D3D11_MAP_READ, 0, &m))) {
              const BYTE* src = (const BYTE*)m.pData;
              for (UINT y = 0; y < h_; y++) memcpy(&frame[(size_t)y * w_], src + (size_t)y * m.RowPitch, w_);
              const BYTE* uv = src + (size_t)m.RowPitch * h_;   // NV12: the colour plane follows the brightness plane
              for (UINT y = 0; y < h_ / 2; y++) memcpy(&frame[(size_t)w_ * h_ + (size_t)y * w_], uv + (size_t)y * m.RowPitch, w_);
              ctx->Unmap(stage, 0);
            }
          }
        } else {
          ctx->CopyResource(stage, screen);
          if (SUCCEEDED(ctx->Map(stage, 0, D3D11_MAP_READ, 0, &m))) {
            bgra_to_nv12((const BYTE*)m.pData, (int)m.RowPitch, (int)sw, (int)sh, frame.data(), (int)w_, (int)h_);
            ctx->Unmap(stage, 0);
          }
        }
      }
      // Write it at the frame's time, every 1/fps seconds (repeating the last picture when nothing changed).
      const LONGLONG now = qpc100();
      {
        std::lock_guard<std::mutex> g(mu_);
        if (cur_) {
          write(cur_->w, cur_->vs, frame.data(), (DWORD)frame.size(), now - cur_->t0, period);
          cur_->lastVideo = now;
        }
      }
      // A new piece every minute, or at once when someone needs the last seconds.
      bool wantFlush;
      double started;
      {
        std::lock_guard<std::mutex> g(mu_);
        wantFlush = flushWanted_ > flushDone_;
        started = cur_ ? cur_->wall0 : wall_of(now);
      }
      if (wantFlush || wall_of(now) - started >= o_.segment_seconds) {
        rotate(now);
        if (wantFlush) {
          std::lock_guard<std::mutex> g(mu_);
          flushDone_ = flushWanted_;
          flushCv_.notify_all();
        }
      }
      next += period;
      const LONGLONG wait = next - qpc100();
      if (wait > 0) std::this_thread::sleep_for(std::chrono::microseconds(wait / 10));
      else if (wait < -10 * period) next = qpc100();   // fell far behind (the PC was busy): do not try to catch up
    }
    // Stopping: finish the last piece.
    std::unique_ptr<Piece> last;
    {
      std::lock_guard<std::mutex> g(mu_);
      last = std::move(cur_);
    }
    if (last && SUCCEEDED(last->w->Finalize()) && last->lastVideo > last->t0) {
      std::lock_guard<std::mutex> g(mu_);
      segments_.push_back({last->path, last->wall0, wall_of(last->lastVideo + period)});
    }
    std::lock_guard<std::mutex> g(mu_);
    flushDone_ = flushWanted_;
    flushCv_.notify_all();
    status_ = "Recorder stopped.";
  }

  // What the sound card plays, captured ("loopback"): its format decides the pieces' sound settings.
  Com<IAudioClient> audioClient_;
  WAVEFORMATEX* mix_ = nullptr;
  bool mixFloat_ = false;
  UINT32 mixRate_ = 0, mixChannels_ = 0, decimate_ = 1;

  void probe_audio() {
    audioOn_ = false;
    Com<IMMDeviceEnumerator> en;
    Com<IMMDevice> devc;
    if (FAILED(CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL, IID_PPV_ARGS(&en))) || FAILED(en->GetDefaultAudioEndpoint(eRender, eConsole, &devc))) return;
    if (FAILED(devc->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr, (void**)&audioClient_))) return;
    if (FAILED(audioClient_->GetMixFormat(&mix_)) || !mix_) return;
    mixRate_ = mix_->nSamplesPerSec;
    mixChannels_ = mix_->nChannels;
    mixFloat_ = mix_->wFormatTag == WAVE_FORMAT_IEEE_FLOAT ||
                (mix_->wFormatTag == WAVE_FORMAT_EXTENSIBLE && IsEqualGUID(((WAVEFORMATEXTENSIBLE*)mix_)->SubFormat, kFloatAudio));
    if (!mixFloat_ && mix_->wBitsPerSample != 16) return;   // a format we do not convert: record without sound
    if (mixRate_ == 48000 || mixRate_ == 44100) decimate_ = 1;
    else if (mixRate_ == 96000 || mixRate_ == 88200) decimate_ = 2;
    else if (mixRate_ == 192000 || mixRate_ == 176400) decimate_ = 4;
    else return;
    rate_ = mixRate_ / decimate_;
    channels_ = 2;
    if (FAILED(audioClient_->Initialize(AUDCLNT_SHAREMODE_SHARED, AUDCLNT_STREAMFLAGS_LOOPBACK, 10000000, 0, mix_, nullptr))) return;
    audioOn_ = true;
  }

  void audio_main() {
    plat::MfSession mf;
    if (!audioOn_) return;
    Com<IAudioCaptureClient> cap;
    if (FAILED(audioClient_->GetService(IID_PPV_ARGS(&cap))) || FAILED(audioClient_->Start())) return;
    std::vector<int16_t> pcm;
    const UINT32 bytesPerFrameOut = channels_ * 2;
    while (run_) {
      std::this_thread::sleep_for(std::chrono::milliseconds(10));
      UINT32 packet = 0;
      bool got = false;
      while (SUCCEEDED(cap->GetNextPacketSize(&packet)) && packet > 0) {
        BYTE* data = nullptr;
        UINT32 frames = 0;
        DWORD flags = 0;
        UINT64 devPos = 0, qpcPos = 0;
        if (FAILED(cap->GetBuffer(&data, &frames, &flags, &devPos, &qpcPos))) break;
        // To 16-bit stereo at 44.1 or 48 kHz.
        const UINT32 outFrames = frames / decimate_;
        pcm.assign((size_t)outFrames * 2, 0);
        if (!(flags & AUDCLNT_BUFFERFLAGS_SILENT)) {
          for (UINT32 i = 0; i < outFrames; i++) {
            const UINT32 f = i * decimate_;
            for (UINT32 c = 0; c < 2; c++) {
              const UINT32 ch = std::min(c, mixChannels_ - 1);   // mono plays on both sides
              float v;
              if (mixFloat_) v = ((const float*)data)[(size_t)f * mixChannels_ + ch];
              else v = ((const int16_t*)data)[(size_t)f * mixChannels_ + ch] / 32768.0f;
              pcm[(size_t)i * 2 + c] = (int16_t)std::max(-32768.0f, std::min(32767.0f, v * 32767.0f));
            }
          }
        }
        cap->ReleaseBuffer(frames);
        const LONGLONG dur = (LONGLONG)outFrames * 10000000LL / rate_;
        std::lock_guard<std::mutex> g(mu_);
        if (cur_ && cur_->audio && (LONGLONG)qpcPos >= cur_->t0) {
          write(cur_->w, cur_->as, (const BYTE*)pcm.data(), outFrames * bytesPerFrameOut, (LONGLONG)qpcPos - cur_->t0, dur);
          cur_->lastAudioEnd = (LONGLONG)qpcPos + dur;
        }
        got = true;
      }
      // Nothing plays: the sound card sends nothing, so write silence to keep picture and sound in step.
      if (!got) {
        std::lock_guard<std::mutex> g(mu_);
        const LONGLONG now = qpc100();
        if (cur_ && cur_->audio && now - cur_->lastAudioEnd > 2000000) {   // 200 ms without sound
          const LONGLONG dur = now - cur_->lastAudioEnd;
          const UINT32 n = (UINT32)(dur * rate_ / 10000000LL);
          if (n) write(cur_->w, cur_->as, nullptr, n * bytesPerFrameOut, cur_->lastAudioEnd - cur_->t0, dur);
          cur_->lastAudioEnd = now;
        }
      }
    }
    audioClient_->Stop();
    if (mix_) { CoTaskMemFree(mix_); mix_ = nullptr; }
  }
};

}  // namespace

std::unique_ptr<Recorder> make_recorder() { return std::make_unique<WinRecorder>(); }

}  // namespace rec

namespace plat {

}  // namespace plat
