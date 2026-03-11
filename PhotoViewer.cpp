#pragma comment(linker,"\"/manifestdependency:type='win32' name='Microsoft.Windows.Common-Controls' version='6.0.0.0' processorArchitecture='*' publicKeyToken='6595b64144ccf1df' language='*'\"")

#pragma comment(lib, "gdiplus.lib")
#pragma comment(lib, "windowscodecs.lib")
#pragma comment(lib, "mfplay.lib")
#pragma comment(lib, "mfuuid.lib")
#pragma comment(lib, "mfplat.lib")
#pragma comment(lib, "mfreadwrite.lib")
#pragma comment(lib, "wininet.lib")
#pragma comment(lib, "shlwapi.lib")
#pragma comment(lib, "propsys.lib")
#pragma comment(lib, "comctl32.lib")

#include <windows.h>
#include <commctrl.h>
#include <gdiplus.h>
#include <wincodec.h>
#include <mfplay.h>
#include <mfapi.h>
#include <mfidl.h>
#include <mfreadwrite.h>
#include <wininet.h>
#include <shobjidl.h>
#include <propsys.h>
#include <propkey.h>
#include <string>
#include <vector>
#include <thread>
#include <atomic>
#include <algorithm>
#include <unordered_map>
#include <mutex>

using namespace Gdiplus;

#define WM_USER_SCAN_START   (WM_USER + 100)
#define WM_USER_SCAN_FOUND   (WM_USER + 101)
#define WM_USER_SCAN_ITEM    (WM_USER + 102)
#define WM_USER_SCAN_DONE    (WM_USER + 103)
#define WM_USER_IMAGE_LOADED (WM_USER + 104)

enum class MediaType { Unknown, Image, Video, Audio };

struct MediaFile {
    std::wstring filePath;
    std::wstring fileName;
    MediaType type;
};

struct ScanItemData {
    HBITMAP hBmp;
    int uiIndex;
    int totalCount;
    int sessionId;
};

// --- 全局状态与句柄 ---
HFONT g_hFont = NULL;
std::vector<MediaFile> g_mediaFiles;
int g_currentIndex = -1;
std::atomic<int> g_scanSessionId(0);
std::atomic<int> g_imageLoadSessionId(0);
std::atomic<int> g_gpsSessionId(0);

// GPS 缓存层
std::unordered_map<std::wstring, std::wstring> g_gpsCache;
std::mutex g_cacheMutex;
bool g_gpsAddressFetched = false;

HWND g_hMainWindow = NULL;
HWND g_hListView = NULL;
HWND g_hProgressText = NULL;
HWND g_hViewerWindow = NULL;
HWND g_hVideoHost = NULL;
HWND g_hImageHost = NULL;
HWND g_hInfoPanel = NULL;
HWND g_hInfoText = NULL;
HWND g_hGpsText = NULL;
HWND g_hBtnToggleInfo = NULL;

HWND g_hBtnPlayPause = NULL;
HWND g_hTrackProgress = NULL;
HWND g_hTrackVolume = NULL;
HWND g_hTimeLabel = NULL;
HWND g_hVolumeLabel = NULL;

bool g_infoVisible = true;
bool g_isPlaying = false;
double g_currentLat = 0.0, g_currentLon = 0.0;
bool g_hasGps = false;
MediaType g_currentMediaType = MediaType::Unknown;
std::wstring g_currentMediaInfo = L"";

IMFPMediaPlayer* g_pPlayer = NULL;
Bitmap* g_currentImage = NULL;

void ApplyGlobalFont(HWND hwnd) { SendMessageW(hwnd, WM_SETFONT, (WPARAM)g_hFont, TRUE); }

WNDPROC g_OldStaticProc;
LRESULT CALLBACK GpsLabelProc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
    if (msg == WM_LBUTTONDBLCLK && g_hasGps) {
        std::wstring url = L"https://www.google.com/maps/search/?api=1&query=" + std::to_wstring(g_currentLat) + L"," + std::to_wstring(g_currentLon);
        ShellExecuteW(NULL, L"open", url.c_str(), NULL, NULL, SW_SHOWNORMAL);
    }
    if (msg == WM_SETCURSOR && g_hasGps) { SetCursor(LoadCursor(NULL, IDC_HAND)); return TRUE; }
    return CallWindowProc(g_OldStaticProc, hwnd, msg, wp, lp);
}

MediaType IdentifyFile(const std::wstring& path) {
    HANDLE hFile = CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ, NULL, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
    if (hFile == INVALID_HANDLE_VALUE) return MediaType::Unknown;
    BYTE buf[16] = { 0 }; DWORD readBytes = 0;
    ReadFile(hFile, buf, 16, &readBytes, NULL);
    CloseHandle(hFile);

    if (readBytes >= 3 && buf[0] == 0xFF && buf[1] == 0xD8 && buf[2] == 0xFF) return MediaType::Image;
    if (readBytes >= 8 && buf[0] == 0x89 && buf[1] == 0x50 && buf[2] == 0x4E && buf[3] == 0x47) return MediaType::Image;
    if (readBytes >= 12 && memcmp(buf + 4, "ftyp", 4) == 0) {
        if (memcmp(buf + 8, "heic", 4) == 0 || memcmp(buf + 8, "heix", 4) == 0 || memcmp(buf + 8, "mif1", 4) == 0 || memcmp(buf + 8, "msf1", 4) == 0) return MediaType::Image;
        if (memcmp(buf + 8, "M4A ", 4) == 0 || memcmp(buf + 8, "M4B ", 4) == 0) return MediaType::Audio;
        return MediaType::Video;
    }
    return MediaType::Unknown;
}

HBITMAP CreateSolidPaddedThumbnail(Bitmap* srcBmp, int size) {
    if (!srcBmp || srcBmp->GetLastStatus() != Ok) return NULL;
    Bitmap dstBmp(size, size, PixelFormat32bppPARGB);
    Graphics g(&dstBmp);
    g.Clear(Color(255, 30, 30, 30));

    float ratio = min((float)size / srcBmp->GetWidth(), (float)size / srcBmp->GetHeight());
    int w = max(1, (int)(srcBmp->GetWidth() * ratio));
    int h = max(1, (int)(srcBmp->GetHeight() * ratio));

    g.SetInterpolationMode(InterpolationModeBilinear);
    g.DrawImage(srcBmp, (size - w) / 2, (size - h) / 2, w, h);

    HBITMAP hBmp = NULL;
    dstBmp.GetHBITMAP(Color(255, 30, 30, 30), &hBmp);
    return hBmp;
}

IWICBitmapDecoder* GetSafeDecoder(IWICImagingFactory* pFactory, const std::wstring& path) {
    IWICBitmapDecoder* pDecoder = NULL;
    HRESULT hr = pFactory->CreateDecoderFromFilename(path.c_str(), NULL, GENERIC_READ, WICDecodeMetadataCacheOnDemand, &pDecoder);
    if (FAILED(hr) || !pDecoder) {
        IWICStream* pStream = NULL;
        if (SUCCEEDED(pFactory->CreateStream(&pStream))) {
            if (SUCCEEDED(pStream->InitializeFromFilename(path.c_str(), GENERIC_READ))) {
                pFactory->CreateDecoderFromStream(pStream, NULL, WICDecodeMetadataCacheOnDemand, &pDecoder);
            }
            pStream->Release();
        }
    }
    return pDecoder;
}

Bitmap* LoadImageWithOrientation(const std::wstring& path, bool bThumbnail) {
    IWICImagingFactory* pFactory = NULL;
    if (FAILED(CoCreateInstance(CLSID_WICImagingFactory, NULL, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&pFactory)))) return NULL;

    Bitmap* bmp = NULL;
    IWICBitmapDecoder* pDecoder = GetSafeDecoder(pFactory, path);
    if (pDecoder) {
        IWICBitmapFrameDecode* pFrame = NULL;
        if (SUCCEEDED(pDecoder->GetFrame(0, &pFrame))) {
            UINT orientation = 1;
            IWICMetadataQueryReader* pReader = NULL;
            if (SUCCEEDED(pFrame->GetMetadataQueryReader(&pReader))) {
                PROPVARIANT var; PropVariantInit(&var);
                if (SUCCEEDED(pReader->GetMetadataByName(L"/app1/ifd/{ushort=274}", &var)) ||
                    SUCCEEDED(pReader->GetMetadataByName(L"/ifd/{ushort=274}", &var))) {
                    if (var.vt == VT_UI2) orientation = var.uiVal;
                    PropVariantClear(&var);
                }
                pReader->Release();
            }

            IWICFormatConverter* pConverter = NULL;
            if (SUCCEEDED(pFactory->CreateFormatConverter(&pConverter))) {
                if (SUCCEEDED(pConverter->Initialize(pFrame, GUID_WICPixelFormat32bppPBGRA, WICBitmapDitherTypeNone, NULL, 0.f, WICBitmapPaletteTypeCustom))) {
                    if (bThumbnail) {
                        UINT w, h; pConverter->GetSize(&w, &h);
                        float ratio = min(120.0f / w, 120.0f / h);
                        UINT nw = max(1, (UINT)(w * ratio)), nh = max(1, (UINT)(h * ratio));
                        IWICBitmapScaler* pScaler = NULL;
                        if (SUCCEEDED(pFactory->CreateBitmapScaler(&pScaler))) {
                            if (SUCCEEDED(pScaler->Initialize(pConverter, nw, nh, WICBitmapInterpolationModeFant))) {
                                bmp = new Bitmap(nw, nh, PixelFormat32bppPARGB);
                                BitmapData data; Rect rect(0, 0, nw, nh);
                                if (bmp->LockBits(&rect, ImageLockModeWrite, PixelFormat32bppPARGB, &data) == Ok) {
                                    pScaler->CopyPixels(NULL, data.Stride, data.Stride * nh, (BYTE*)data.Scan0);
                                    bmp->UnlockBits(&data);
                                }
                                else { delete bmp; bmp = NULL; }
                            }
                            pScaler->Release();
                        }
                    }
                    else {
                        UINT w, h; pConverter->GetSize(&w, &h);
                        bmp = new Bitmap(w, h, PixelFormat32bppPARGB);
                        BitmapData data; Rect rect(0, 0, w, h);
                        if (bmp->LockBits(&rect, ImageLockModeWrite, PixelFormat32bppPARGB, &data) == Ok) {
                            pConverter->CopyPixels(NULL, data.Stride, data.Stride * h, (BYTE*)data.Scan0);
                            bmp->UnlockBits(&data);
                        }
                        else { delete bmp; bmp = NULL; }
                    }

                    if (bmp) {
                        if (orientation == 3) bmp->RotateFlip(Rotate180FlipNone);
                        else if (orientation == 6) bmp->RotateFlip(Rotate90FlipNone);
                        else if (orientation == 8) bmp->RotateFlip(Rotate270FlipNone);
                    }
                }
                pConverter->Release();
            }
            pFrame->Release();
        }
        pDecoder->Release();
    }
    pFactory->Release();
    return bmp;
}

HBITMAP CreateThumbnailWIC(const std::wstring& path, int size) {
    Bitmap* bmp = LoadImageWithOrientation(path, true);
    HBITMAP hBmp = CreateSolidPaddedThumbnail(bmp, size);
    if (bmp) delete bmp;
    return hBmp;
}

HBITMAP CreateVideoThumbnail(const std::wstring& path, int size) {
    IMFByteStream* pByteStream = NULL;
    if (FAILED(MFCreateFile(MF_ACCESSMODE_READ, MF_OPENMODE_FAIL_IF_NOT_EXIST, MF_FILEFLAGS_NONE, path.c_str(), &pByteStream))) return NULL;

    IMFAttributes* pAttributes = NULL; HBITMAP hBmp = NULL;
    if (SUCCEEDED(MFCreateAttributes(&pAttributes, 1))) {
        pAttributes->SetUINT32(MF_SOURCE_READER_ENABLE_VIDEO_PROCESSING, TRUE);
        IMFSourceReader* pReader = NULL;
        if (SUCCEEDED(MFCreateSourceReaderFromByteStream(pByteStream, pAttributes, &pReader))) {
            pReader->SetStreamSelection(MF_SOURCE_READER_ALL_STREAMS, FALSE);
            if (SUCCEEDED(pReader->SetStreamSelection(MF_SOURCE_READER_FIRST_VIDEO_STREAM, TRUE))) {
                IMFMediaType* pType = NULL;
                if (SUCCEEDED(MFCreateMediaType(&pType))) {
                    pType->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
                    pType->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_RGB32);

                    if (SUCCEEDED(pReader->SetCurrentMediaType(MF_SOURCE_READER_FIRST_VIDEO_STREAM, NULL, pType))) {
                        PROPVARIANT varStart; PropVariantInit(&varStart);
                        varStart.vt = VT_I8; varStart.hVal.QuadPart = 10000000;
                        pReader->SetCurrentPosition(GUID_NULL, varStart);

                        for (int attempt = 0; attempt < 15; ++attempt) {
                            IMFSample* pSample = NULL; DWORD flags = 0;
                            if (FAILED(pReader->ReadSample(MF_SOURCE_READER_FIRST_VIDEO_STREAM, 0, NULL, &flags, NULL, &pSample))) break;
                            if (flags & MF_SOURCE_READERF_ENDOFSTREAM) break;

                            if (pSample) {
                                IMFMediaBuffer* pBuffer = NULL;
                                if (SUCCEEDED(pSample->ConvertToContiguousBuffer(&pBuffer))) {
                                    BYTE* pData = NULL; DWORD length = 0;
                                    if (SUCCEEDED(pBuffer->Lock(&pData, NULL, &length))) {
                                        IMFMediaType* pCurrentType = NULL;
                                        if (SUCCEEDED(pReader->GetCurrentMediaType(MF_SOURCE_READER_FIRST_VIDEO_STREAM, &pCurrentType))) {
                                            UINT32 width = 0, height = 0;
                                            if (SUCCEEDED(MFGetAttributeSize(pCurrentType, MF_MT_FRAME_SIZE, &width, &height)) && width > 0 && height > 0) {
                                                LONG pitch = width * 4;
                                                MFGetStrideForBitmapInfoHeader(MFVideoFormat_RGB32.Data1, width, &pitch);

                                                Bitmap tempBmp(width, height, PixelFormat32bppRGB);
                                                BitmapData srcData; Rect srcRect(0, 0, width, height);
                                                if (tempBmp.LockBits(&srcRect, ImageLockModeWrite, PixelFormat32bppRGB, &srcData) == Ok) {
                                                    BYTE* pDest = (BYTE*)srcData.Scan0; BYTE* pSrc = pData;
                                                    if (pitch < 0) pSrc = pData + abs(pitch) * (height - 1);
                                                    for (UINT y = 0; y < height; y++) {
                                                        memcpy(pDest, pSrc, width * 4);
                                                        pDest += srcData.Stride; pSrc += pitch;
                                                    }
                                                    tempBmp.UnlockBits(&srcData);

                                                    if (pitch < 0) tempBmp.RotateFlip(RotateNoneFlipY);
                                                    UINT32 rotation = 0;
                                                    pCurrentType->GetUINT32(MF_MT_VIDEO_ROTATION, &rotation);
                                                    if (rotation == 90) tempBmp.RotateFlip(Rotate90FlipNone);
                                                    else if (rotation == 180) tempBmp.RotateFlip(Rotate180FlipNone);
                                                    else if (rotation == 270) tempBmp.RotateFlip(Rotate270FlipNone);

                                                    hBmp = CreateSolidPaddedThumbnail(&tempBmp, size);
                                                }
                                            }
                                            pCurrentType->Release();
                                        }
                                        pBuffer->Unlock();
                                    }
                                    pBuffer->Release();
                                }
                                pSample->Release();
                                if (hBmp) break;
                            }
                        }
                    }
                    pType->Release();
                }
            }
            pReader->Release();
        }
        pAttributes->Release();
    }
    pByteStream->Release();
    return hBmp;
}

bool FindVideoGPS(const std::wstring& path, double& lat, double& lon) {
    HANDLE hFile = CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ, NULL, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
    if (hFile == INVALID_HANDLE_VALUE) return false;

    DWORD fileSize = GetFileSize(hFile, NULL);
    auto searchISO6709 = [&](BYTE* buf, DWORD len) -> bool {
        for (DWORD i = 0; i < len - 20; ++i) {
            if ((buf[i] == '+' || buf[i] == '-') && isdigit(buf[i + 1]) && isdigit(buf[i + 2])) {
                std::string s((char*)buf + i, 60);
                size_t slash = s.find('/');
                if (slash != std::string::npos && slash >= 15 && slash < 50) {
                    s = s.substr(0, slash);

                    bool validChars = true;
                    for (char c : s) { if (!isdigit(c) && c != '+' && c != '-' && c != '.') { validChars = false; break; } }
                    if (!validChars) continue;

                    size_t secondSign = s.find_first_of("+-", 1);
                    if (secondSign != std::string::npos) {
                        size_t thirdSign = s.find_first_of("+-", secondSign + 1);
                        std::string latStr = s.substr(0, secondSign);
                        std::string lonStr = (thirdSign != std::string::npos) ? s.substr(secondSign, thirdSign - secondSign) : s.substr(secondSign);

                        try {
                            double tLat = std::stod(latStr);
                            double tLon = std::stod(lonStr);
                            if (tLat >= -90 && tLat <= 90 && tLon >= -180 && tLon <= 180) {
                                if (tLat != 0.0 || tLon != 0.0) {
                                    lat = tLat; lon = tLon;
                                    return true;
                                }
                            }
                        }
                        catch (...) {}
                    }
                }
            }
        }
        return false;
        };

    DWORD readBytes;
    std::vector<BYTE> buf(min(fileSize, (DWORD)(2 * 1024 * 1024)));
    ReadFile(hFile, buf.data(), buf.size(), &readBytes, NULL);
    if (searchISO6709(buf.data(), readBytes)) { CloseHandle(hFile); return true; }

    if (fileSize > 4 * 1024 * 1024) {
        SetFilePointer(hFile, -2 * 1024 * 1024, NULL, FILE_END);
        ReadFile(hFile, buf.data(), buf.size(), &readBytes, NULL);
        if (searchISO6709(buf.data(), readBytes)) { CloseHandle(hFile); return true; }
    }
    CloseHandle(hFile); return false;
}

std::string CleanLocationString(std::string part) {
    size_t slashPos;
    while ((slashPos = part.find(" / ")) != std::string::npos) part = part.substr(0, slashPos);
    while ((slashPos = part.find(";")) != std::string::npos) part = part.substr(0, slashPos);
    while ((slashPos = part.find("；")) != std::string::npos) part = part.substr(0, slashPos);
    while ((slashPos = part.find("/")) != std::string::npos) part = part.substr(0, slashPos);

    part.erase(0, part.find_first_not_of(" \t\r\n"));
    if (part.empty()) return "";
    part.erase(part.find_last_not_of(" \t\r\n") + 1);

    bool hasDigit = false;
    for (char c : part) { if (isdigit(c)) hasDigit = true; }
    if (hasDigit && part.length() <= 8) return "";

    return part;
}

// 【缓存提取 Key 生成器】按 0.001 精度(约100米)抹平坐标，生成公用缓存 Key
std::wstring GetGpsCacheKey(double lat, double lon) {
    wchar_t buf[128];
    swprintf(buf, 128, L"%.3f_%.3f", lat, lon);
    return std::wstring(buf);
}

void FetchAddressThread(double lat, double lon, HWND hwndGps, int sessionId, std::wstring cacheKey) {
    std::wstring url = L"https://nominatim.openstreetmap.org/reverse?format=json&lat=" + std::to_wstring(lat) + L"&lon=" + std::to_wstring(lon) + L"&accept-language=zh-CN";
    HINTERNET hNet = InternetOpenA("Win32MediaBrowser/1.0", INTERNET_OPEN_TYPE_PRECONFIG, NULL, NULL, 0);
    HINTERNET hConn = InternetOpenUrlW(hNet, url.c_str(), L"User-Agent: Win32MediaBrowser/1.0\r\n", -1, INTERNET_FLAG_RELOAD, 0);

    std::string response;
    if (hConn) {
        char buf[1024]; DWORD bytesRead;
        while (InternetReadFile(hConn, buf, sizeof(buf) - 1, &bytesRead) && bytesRead > 0) {
            buf[bytesRead] = 0; response += buf;
        }
        InternetCloseHandle(hConn);
    }
    InternetCloseHandle(hNet);

    if (sessionId != g_gpsSessionId) return;

    std::wstring resultText = L"地址解析失败";
    std::wstring detailedAddress = L"";

    if (!response.empty()) {
        auto extract = [&](const std::string& key) -> std::string {
            std::string search = "\"" + key + "\":\"";
            size_t p = response.find(search);
            if (p == std::string::npos) return "";
            p += search.length();
            size_t e = response.find("\"", p);
            return (e != std::string::npos) ? response.substr(p, e - p) : "";
            };

        std::string country = CleanLocationString(extract("country"));
        std::string state = CleanLocationString(extract("state")); if (state.empty()) state = CleanLocationString(extract("province"));
        std::string city = CleanLocationString(extract("city")); if (city.empty()) city = CleanLocationString(extract("town"));
        std::string suburb = CleanLocationString(extract("suburb"));

        std::string full = country + " " + state + " " + city + " " + suburb;
        if (full.length() > 3) {
            int len = MultiByteToWideChar(CP_UTF8, 0, full.c_str(), -1, NULL, 0);
            if (len > 0) {
                std::wstring wfull(len, 0);
                MultiByteToWideChar(CP_UTF8, 0, full.c_str(), -1, &wfull[0], len);
                wfull.resize(len - 1); resultText = wfull;
            }
        }

        std::string displayName = extract("display_name");
        if (!displayName.empty()) {
            std::vector<std::string> parts;
            size_t pos = 0; std::string temp = displayName;
            while ((pos = temp.find(",")) != std::string::npos) { parts.push_back(temp.substr(0, pos)); temp.erase(0, pos + 1); }
            parts.push_back(temp);

            for (auto it = parts.rbegin(); it != parts.rend(); ++it) {
                std::string cleaned = CleanLocationString(*it);
                if (cleaned.empty()) continue;
                int len = MultiByteToWideChar(CP_UTF8, 0, cleaned.c_str(), -1, NULL, 0);
                if (len > 0) {
                    std::wstring wpart(len, 0);
                    MultiByteToWideChar(CP_UTF8, 0, cleaned.c_str(), -1, &wpart[0], len);
                    wpart.resize(len - 1); detailedAddress += wpart + L" ";
                }
            }
        }
    }

    std::wstring finalDisplay = L"📍 " + resultText + L"\n\n详细地址:\n" + detailedAddress;

    // 保存到内存缓存，避免后续附近照片重复查询
    {
        std::lock_guard<std::mutex> lock(g_cacheMutex);
        g_gpsCache[cacheKey] = finalDisplay;
    }

    std::wstring displayText = L"GPS: " + std::to_wstring(lat) + L", " + std::to_wstring(lon) +
        L"\n" + finalDisplay +
        L"\n\n[双击在地图中打开]";
    SetWindowTextW(hwndGps, displayText.c_str());
}

// 【触发 GPS 拉取】懒加载策略：只在满足条件时执行获取，拦截高频垃圾请求
void TriggerGpsFetch(HWND hwnd) {
    if (!g_infoVisible) return;
    if (!g_hasGps) {
        SetWindowTextW(g_hGpsText, L"GPS: 无位置数据");
        return;
    }
    if (g_gpsAddressFetched) return;

    std::wstring cacheKey = GetGpsCacheKey(g_currentLat, g_currentLon);
    bool hitCache = false;
    std::wstring cachedAddress = L"";

    {
        std::lock_guard<std::mutex> lock(g_cacheMutex);
        if (g_gpsCache.count(cacheKey)) {
            hitCache = true;
            cachedAddress = g_gpsCache[cacheKey];
        }
    }

    if (hitCache) {
        // 缓存命中，秒出结果
        std::wstring displayText = L"GPS: " + std::to_wstring(g_currentLat) + L", " + std::to_wstring(g_currentLon) +
            L"\n" + cachedAddress + L"\n\n[双击在地图中打开]";
        SetWindowTextW(g_hGpsText, displayText.c_str());
        g_gpsAddressFetched = true;
    }
    else {
        // 未命中缓存：立即反馈原始数字以免感觉卡顿，并开启毫秒级防抖定时器
        std::wstring loadingText = L"GPS: " + std::to_wstring(g_currentLat) + L", " + std::to_wstring(g_currentLon) +
            L"\n📍 正在获取地址数据...";
        SetWindowTextW(g_hGpsText, loadingText.c_str());
        SetTimer(hwnd, 2, 800, NULL); // 800ms 防抖，快切照片绝不发请求！
    }
}

std::wstring ReadMetadataDirect(const std::wstring& path, MediaType type) {
    std::wstring info = L"文件名:\n" + path.substr(path.find_last_of(L"\\/") + 1) + L"\n\n";
    g_hasGps = false;
    g_gpsAddressFetched = false;

    if (type == MediaType::Image) {
        IWICImagingFactory* pFactory = NULL;
        if (SUCCEEDED(CoCreateInstance(CLSID_WICImagingFactory, NULL, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&pFactory)))) {
            IWICBitmapDecoder* pDecoder = GetSafeDecoder(pFactory, path);
            if (pDecoder) {
                IWICBitmapFrameDecode* pFrame = NULL;
                if (SUCCEEDED(pDecoder->GetFrame(0, &pFrame))) {
                    IWICMetadataQueryReader* pReader = NULL;
                    if (SUCCEEDED(pFrame->GetMetadataQueryReader(&pReader))) {
                        auto tryReadStr = [&](const wchar_t* query, std::wstring& out) {
                            PROPVARIANT var; PropVariantInit(&var);
                            if (SUCCEEDED(pReader->GetMetadataByName(query, &var)) && var.vt == VT_LPSTR) {
                                std::string s(var.pszVal); out = std::wstring(s.begin(), s.end());
                                PropVariantClear(&var); return true;
                            }
                            PropVariantClear(&var); return false;
                            };
                        std::wstring extDate;
                        if (tryReadStr(L"/app1/ifd/exif/{ushort=36867}", extDate) || tryReadStr(L"/ifd/exif/{ushort=36867}", extDate)) {
                            info += L"拍摄时间:\n" + extDate + L"\n\n";
                        }
                        else info += L"拍摄时间: 未找到 EXIF 数据\n\n";

                        auto tryReadGPS = [&](const wchar_t* latPath, const wchar_t* lonPath, const wchar_t* latRef, const wchar_t* lonRef) -> bool {
                            PROPVARIANT pLat, pLon, pLRef, pRRef;
                            PropVariantInit(&pLat); PropVariantInit(&pLon); PropVariantInit(&pLRef); PropVariantInit(&pRRef);
                            bool found = false;
                            if (SUCCEEDED(pReader->GetMetadataByName(latPath, &pLat)) && SUCCEEDED(pReader->GetMetadataByName(lonPath, &pLon))) {
                                auto parseGps = [](PROPVARIANT& v) -> double {
                                    if (v.vt == (VT_VECTOR | VT_UI8) && v.cauh.cElems == 3) {
                                        double d = v.cauh.pElems[0].HighPart ? (double)v.cauh.pElems[0].LowPart / (double)v.cauh.pElems[0].HighPart : 0;
                                        double m = v.cauh.pElems[1].HighPart ? (double)v.cauh.pElems[1].LowPart / (double)v.cauh.pElems[1].HighPart : 0;
                                        double s = v.cauh.pElems[2].HighPart ? (double)v.cauh.pElems[2].LowPart / (double)v.cauh.pElems[2].HighPart : 0;
                                        return d + m / 60.0 + s / 3600.0;
                                    } return 0.0;
                                    };
                                g_currentLat = parseGps(pLat); g_currentLon = parseGps(pLon);
                                if (SUCCEEDED(pReader->GetMetadataByName(latRef, &pLRef)) && pLRef.vt == VT_LPSTR && pLRef.pszVal[0] == 'S') g_currentLat = -g_currentLat;
                                if (SUCCEEDED(pReader->GetMetadataByName(lonRef, &pRRef)) && pRRef.vt == VT_LPSTR && pRRef.pszVal[0] == 'W') g_currentLon = -g_currentLon;
                                found = true; g_hasGps = true;
                            }
                            PropVariantClear(&pLat); PropVariantClear(&pLon); PropVariantClear(&pLRef); PropVariantClear(&pRRef);
                            return found;
                            };
                        if (!tryReadGPS(L"/app1/ifd/gps/{ushort=2}", L"/app1/ifd/gps/{ushort=4}", L"/app1/ifd/gps/{ushort=1}", L"/app1/ifd/gps/{ushort=3}"))
                            tryReadGPS(L"/ifd/gps/{ushort=2}", L"/ifd/gps/{ushort=4}", L"/ifd/gps/{ushort=1}", L"/ifd/gps/{ushort=3}");
                        pReader->Release();
                    } pFrame->Release();
                } pDecoder->Release();
            } pFactory->Release();
        }
    }
    else {
        WIN32_FILE_ATTRIBUTE_DATA fad;
        if (GetFileAttributesExW(path.c_str(), GetFileExInfoStandard, &fad)) {
            SYSTEMTIME st; FileTimeToSystemTime(&fad.ftLastWriteTime, &st);
            wchar_t dateBuf[256]; swprintf(dateBuf, 256, L"文件记录时间:\n%04d-%02d-%02d %02d:%02d:%02d\n\n", st.wYear, st.wMonth, st.wDay, st.wHour, st.wMinute, st.wSecond);
            info += dateBuf;
        }
        if (FindVideoGPS(path, g_currentLat, g_currentLon)) g_hasGps = true;
    }

    SetWindowTextW(g_hInfoText, info.c_str());
    return info;
}

void LayoutViewer() {
    if (!g_hViewerWindow) return;
    RECT rc; GetClientRect(g_hViewerWindow, &rc);
    int infoWidth = g_infoVisible ? 300 : 0;

    int ctrlHeight = (g_currentMediaType == MediaType::Image) ? 0 : 50;
    MoveWindow(g_hImageHost, 0, 0, rc.right - infoWidth, rc.bottom - ctrlHeight, TRUE);
    MoveWindow(g_hVideoHost, 0, 0, rc.right - infoWidth, rc.bottom - ctrlHeight, TRUE);
    if (g_pPlayer) g_pPlayer->UpdateVideo();

    if (g_infoVisible) {
        MoveWindow(g_hInfoPanel, rc.right - 300, 0, 300, rc.bottom, TRUE);
        MoveWindow(g_hInfoText, 10, 50, 280, 100, TRUE);
        MoveWindow(g_hGpsText, 10, 160, 280, rc.bottom - 170, TRUE);
        ShowWindow(g_hInfoPanel, SW_SHOW);
    }
    else ShowWindow(g_hInfoPanel, SW_HIDE);

    int showCtrl = (g_currentMediaType == MediaType::Image) ? SW_HIDE : SW_SHOW;
    ShowWindow(g_hBtnPlayPause, showCtrl);
    ShowWindow(g_hTrackProgress, showCtrl);
    ShowWindow(g_hTrackVolume, showCtrl);
    ShowWindow(g_hTimeLabel, showCtrl);
    ShowWindow(g_hVolumeLabel, showCtrl);

    MoveWindow(g_hBtnPlayPause, 10, rc.bottom - 45, 60, 35, TRUE);
    MoveWindow(g_hTrackProgress, 80, rc.bottom - 40, rc.right - infoWidth - 400, 30, TRUE);
    MoveWindow(g_hTimeLabel, rc.right - infoWidth - 310, rc.bottom - 35, 110, 20, TRUE);
    MoveWindow(g_hTrackVolume, rc.right - infoWidth - 190, rc.bottom - 40, 120, 30, TRUE);
    MoveWindow(g_hVolumeLabel, rc.right - infoWidth - 65, rc.bottom - 35, 55, 20, TRUE);

    MoveWindow(g_hBtnToggleInfo, rc.right - infoWidth - 110, 10, 100, 30, TRUE);
    BringWindowToTop(g_hBtnToggleInfo);

    InvalidateRect(g_hImageHost, NULL, FALSE);
    UpdateWindow(g_hImageHost);
}

void LoadMedia(int index) {
    if (index < 0 || index >= g_mediaFiles.size()) return;
    g_currentIndex = index;

    // 清除未执行的防抖动作，避免快速切图造成的积压拉取
    KillTimer(g_hViewerWindow, 2);

    if (g_pPlayer) { g_pPlayer->Shutdown(); g_pPlayer->Release(); g_pPlayer = NULL; }

    const MediaFile& file = g_mediaFiles[index];
    g_currentMediaType = file.type;
    std::wstring title = L"媒体浏览器 - " + file.fileName + L" (按ESC关闭，左右键切换，空格键暂停/播放)";
    SetWindowTextW(g_hViewerWindow, title.c_str());

    g_currentMediaInfo = ReadMetadataDirect(file.filePath, file.type);

    // 立即触发按需智能获取机制
    TriggerGpsFetch(g_hViewerWindow);

    if (file.type == MediaType::Image) {
        ShowWindow(g_hVideoHost, SW_HIDE); ShowWindow(g_hImageHost, SW_SHOW);

        int currentSession = ++g_imageLoadSessionId;
        std::thread([file, currentSession]() {
            CoInitializeEx(NULL, COINIT_MULTITHREADED);
            Bitmap* bmp = LoadImageWithOrientation(file.filePath, false);
            PostMessage(g_hViewerWindow, WM_USER_IMAGE_LOADED, currentSession, (LPARAM)bmp);
            CoUninitialize();
            }).detach();

    }
    else {
        if (g_currentImage) { delete g_currentImage; g_currentImage = NULL; }
        if (file.type == MediaType::Audio) { ShowWindow(g_hVideoHost, SW_HIDE); ShowWindow(g_hImageHost, SW_SHOW); }
        else { ShowWindow(g_hImageHost, SW_HIDE); ShowWindow(g_hVideoHost, SW_SHOW); }

        MFPCreateMediaPlayer(file.filePath.c_str(), FALSE, 0, NULL, file.type == MediaType::Video ? g_hVideoHost : NULL, &g_pPlayer);
        if (g_pPlayer) {
            g_pPlayer->Play(); g_isPlaying = true;
            SetWindowTextW(g_hBtnPlayPause, L"暂停");
            SendMessage(g_hTrackProgress, TBM_SETPOS, TRUE, 0);
            SendMessage(g_hTrackVolume, TBM_SETPOS, TRUE, 100);
            SetWindowTextW(g_hVolumeLabel, L"🔊 100%");
            g_pPlayer->SetVolume(1.0f);
        }
    }
    LayoutViewer();
}

void TogglePlayPause() {
    if (!g_pPlayer || g_currentMediaType == MediaType::Image) return;
    if (g_isPlaying) { g_pPlayer->Pause(); SetWindowTextW(g_hBtnPlayPause, L"播放"); }
    else { g_pPlayer->Play(); SetWindowTextW(g_hBtnPlayPause, L"暂停"); }
    g_isPlaying = !g_isPlaying;
}

LRESULT CALLBACK ImageHostProc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
    if (msg == WM_ERASEBKGND) return 1;
    if (msg == WM_PAINT) {
        PAINTSTRUCT ps; HDC hdc = BeginPaint(hwnd, &ps);
        RECT rc; GetClientRect(hwnd, &rc);

        HDC hMemDC = CreateCompatibleDC(hdc);
        HBITMAP hMemBmp = CreateCompatibleBitmap(hdc, rc.right, rc.bottom);
        HBITMAP hOldBmp = (HBITMAP)SelectObject(hMemDC, hMemBmp);

        Graphics g(hMemDC);
        g.Clear(Color(25, 25, 25));

        if (g_currentMediaType == MediaType::Audio) {
            SolidBrush textBrush(Color(220, 220, 220)); Font fontTitle(L"Microsoft YaHei", 24, FontStyleBold); Font fontSub(L"Microsoft YaHei", 14);
            g.DrawString(L"🎧 音频文件", -1, &fontTitle, PointF(rc.right / 2 - 120, rc.bottom / 2 - 60), &textBrush);
            g.DrawString(g_currentMediaInfo.c_str(), -1, &fontSub, PointF(rc.right / 2 - 120, rc.bottom / 2), &textBrush);
        }
        else if (g_currentImage && g_currentImage->GetLastStatus() == Ok) {
            g.SetInterpolationMode(InterpolationModeBilinear);
            float ratio = min((float)rc.right / g_currentImage->GetWidth(), (float)rc.bottom / g_currentImage->GetHeight());
            int w = g_currentImage->GetWidth() * ratio, h = g_currentImage->GetHeight() * ratio;
            g.DrawImage(g_currentImage, (rc.right - w) / 2, (rc.bottom - h) / 2, w, h);
        }

        BitBlt(hdc, 0, 0, rc.right, rc.bottom, hMemDC, 0, 0, SRCCOPY);
        SelectObject(hMemDC, hOldBmp); DeleteObject(hMemBmp); DeleteDC(hMemDC);
        EndPaint(hwnd, &ps); return 0;
    }
    return DefWindowProc(hwnd, msg, wp, lp);
}

LRESULT CALLBACK VideoHostProc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
    if (msg == WM_ERASEBKGND) return 1;
    if (msg == WM_PAINT) {
        PAINTSTRUCT ps; HDC hdc = BeginPaint(hwnd, &ps);
        FillRect(hdc, &ps.rcPaint, (HBRUSH)GetStockObject(BLACK_BRUSH)); EndPaint(hwnd, &ps); return 0;
    }
    return DefWindowProc(hwnd, msg, wp, lp);
}

LRESULT CALLBACK ViewerProc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
    switch (msg) {
    case WM_CREATE:
        SetWindowLong(hwnd, GWL_STYLE, GetWindowLong(hwnd, GWL_STYLE) | WS_CLIPCHILDREN);
        g_hImageHost = CreateWindowW(L"ImageHostClass", NULL, WS_CHILD | WS_VISIBLE | WS_CLIPSIBLINGS, 0, 0, 0, 0, hwnd, NULL, GetModuleHandle(NULL), NULL);
        g_hVideoHost = CreateWindowW(L"VideoHostClass", NULL, WS_CHILD | WS_VISIBLE | WS_CLIPSIBLINGS, 0, 0, 0, 0, hwnd, NULL, GetModuleHandle(NULL), NULL);
        g_hInfoPanel = CreateWindowW(L"Static", NULL, WS_CHILD | WS_VISIBLE | WS_CLIPSIBLINGS, 0, 0, 0, 0, hwnd, NULL, GetModuleHandle(NULL), NULL);
        g_hInfoText = CreateWindowW(L"Static", L"", WS_CHILD | WS_VISIBLE, 0, 0, 0, 0, g_hInfoPanel, NULL, GetModuleHandle(NULL), NULL);
        g_hGpsText = CreateWindowW(L"Static", L"", WS_CHILD | WS_VISIBLE | SS_NOTIFY, 0, 0, 0, 0, g_hInfoPanel, NULL, GetModuleHandle(NULL), NULL);

        g_hBtnToggleInfo = CreateWindowW(L"Button", g_infoVisible ? L"隐藏信息栏" : L"显示信息栏", WS_CHILD | WS_VISIBLE | WS_CLIPSIBLINGS, 0, 0, 0, 0, hwnd, (HMENU)101, GetModuleHandle(NULL), NULL);
        g_hBtnPlayPause = CreateWindowW(L"Button", L"暂停", WS_CHILD | WS_VISIBLE | WS_CLIPSIBLINGS, 0, 0, 0, 0, hwnd, (HMENU)102, GetModuleHandle(NULL), NULL);
        g_hTrackProgress = CreateWindowW(TRACKBAR_CLASS, L"", WS_CHILD | WS_VISIBLE | WS_CLIPSIBLINGS | TBS_HORZ, 0, 0, 0, 0, hwnd, (HMENU)103, GetModuleHandle(NULL), NULL);
        g_hTrackVolume = CreateWindowW(TRACKBAR_CLASS, L"", WS_CHILD | WS_VISIBLE | WS_CLIPSIBLINGS | TBS_HORZ, 0, 0, 0, 0, hwnd, (HMENU)104, GetModuleHandle(NULL), NULL);
        g_hTimeLabel = CreateWindowW(L"Static", L"00:00 / 00:00", WS_CHILD | WS_VISIBLE | WS_CLIPSIBLINGS, 0, 0, 0, 0, hwnd, NULL, GetModuleHandle(NULL), NULL);
        g_hVolumeLabel = CreateWindowW(L"Static", L"🔊 100%", WS_CHILD | WS_VISIBLE | WS_CLIPSIBLINGS, 0, 0, 0, 0, hwnd, NULL, GetModuleHandle(NULL), NULL);
        SendMessage(g_hTrackVolume, TBM_SETRANGE, TRUE, MAKELPARAM(0, 100));

        ApplyGlobalFont(g_hInfoText); ApplyGlobalFont(g_hGpsText); ApplyGlobalFont(g_hBtnToggleInfo);
        ApplyGlobalFont(g_hBtnPlayPause); ApplyGlobalFont(g_hTimeLabel); ApplyGlobalFont(g_hVolumeLabel);
        g_OldStaticProc = (WNDPROC)SetWindowLongPtr(g_hGpsText, GWLP_WNDPROC, (LONG_PTR)GpsLabelProc);
        SetTimer(hwnd, 1, 100, NULL);
        break;
    case WM_TIMER:
        if (wp == 1 && g_pPlayer && (g_currentMediaType == MediaType::Video || g_currentMediaType == MediaType::Audio)) {
            PROPVARIANT varPos, varDur; PropVariantInit(&varPos); PropVariantInit(&varDur);
            if (SUCCEEDED(g_pPlayer->GetDuration(MFP_POSITIONTYPE_100NS, &varDur))) {
                long totalMs = 0;
                if (varDur.vt == VT_UI8) totalMs = varDur.uhVal.QuadPart / 10000LL;
                else if (varDur.vt == VT_I8) totalMs = varDur.hVal.QuadPart / 10000LL;

                if (totalMs > 0) {
                    SendMessage(g_hTrackProgress, TBM_SETRANGEMAX, TRUE, totalMs);
                    if (SUCCEEDED(g_pPlayer->GetPosition(MFP_POSITIONTYPE_100NS, &varPos))) {
                        long curMs = 0;
                        if (varPos.vt == VT_UI8) curMs = varPos.uhVal.QuadPart / 10000LL;
                        else if (varPos.vt == VT_I8) curMs = varPos.hVal.QuadPart / 10000LL;

                        SendMessage(g_hTrackProgress, TBM_SETPOS, TRUE, curMs);
                        long totalSecs = totalMs / 1000, curSecs = curMs / 1000;
                        wchar_t timeStr[64]; swprintf(timeStr, 64, L"%02d:%02d / %02d:%02d", curSecs / 60, curSecs % 60, totalSecs / 60, totalSecs % 60);
                        SetWindowTextW(g_hTimeLabel, timeStr);

                        if (curMs >= totalMs - 200 && g_isPlaying) {
                            g_pPlayer->Pause(); g_isPlaying = false;
                            SetWindowTextW(g_hBtnPlayPause, L"播放");
                            PROPVARIANT varStart; PropVariantInit(&varStart); varStart.vt = VT_I8; varStart.hVal.QuadPart = 0;
                            g_pPlayer->SetPosition(GUID_NULL, &varStart);
                            SendMessage(g_hTrackProgress, TBM_SETPOS, TRUE, 0);
                            swprintf(timeStr, 64, L"00:00 / %02d:%02d", totalSecs / 60, totalSecs % 60);
                            SetWindowTextW(g_hTimeLabel, timeStr);
                        }
                    }
                }
            }
        }
        // 【防封防抖触发】计时器2: 照片切换停留800ms后安全拉取网络数据
        else if (wp == 2) {
            KillTimer(hwnd, 2);
            if (g_hasGps && g_infoVisible && !g_gpsAddressFetched) {
                int currentGpsSession = ++g_gpsSessionId;
                std::wstring cacheKey = GetGpsCacheKey(g_currentLat, g_currentLon);
                std::thread([lat = g_currentLat, lon = g_currentLon, hwnd = g_hGpsText, currentGpsSession, cacheKey]() {
                    FetchAddressThread(lat, lon, hwnd, currentGpsSession, cacheKey);
                    }).detach();
                g_gpsAddressFetched = true;
            }
        }
        break;
    case WM_HSCROLL:
        if ((HWND)lp == g_hTrackProgress && g_pPlayer) {
            if (LOWORD(wp) == TB_THUMBTRACK || LOWORD(wp) == TB_ENDTRACK) {
                long posMs = SendMessage(g_hTrackProgress, TBM_GETPOS, 0, 0);
                PROPVARIANT var; PropVariantInit(&var); var.vt = VT_I8; var.hVal.QuadPart = (LONGLONG)posMs * 10000LL;
                g_pPlayer->SetPosition(GUID_NULL, &var);
            }
        }
        else if ((HWND)lp == g_hTrackVolume && g_pPlayer) {
            int volInt = SendMessage(g_hTrackVolume, TBM_GETPOS, 0, 0);
            g_pPlayer->SetVolume((float)volInt / 100.0f);
            wchar_t volStr[32]; swprintf(volStr, 32, L"🔊 %d%%", volInt);
            SetWindowTextW(g_hVolumeLabel, volStr);
        }
        break;
    case WM_USER_IMAGE_LOADED: {
        int sessionId = (int)wp; Bitmap* bmp = (Bitmap*)lp;
        if (sessionId == g_imageLoadSessionId) {
            if (g_currentImage) delete g_currentImage;
            g_currentImage = bmp;
            InvalidateRect(g_hImageHost, NULL, FALSE);
        }
        else { if (bmp) delete bmp; }
        break;
    }
    case WM_SIZE: LayoutViewer(); break;
    case WM_COMMAND:
        if (LOWORD(wp) == 101) {
            g_infoVisible = !g_infoVisible;
            SetWindowTextW(g_hBtnToggleInfo, g_infoVisible ? L"隐藏信息栏" : L"显示信息栏");
            LayoutViewer();
            if (g_infoVisible) TriggerGpsFetch(hwnd); // 重新激活按需加载
            SetFocus(hwnd);
        }
        else if (LOWORD(wp) == 102) { TogglePlayPause(); SetFocus(hwnd); } break;
    case WM_KEYDOWN:
        if (wp == VK_ESCAPE) PostMessage(hwnd, WM_CLOSE, 0, 0);
        else if (wp == VK_LEFT && g_currentIndex > 0) LoadMedia(g_currentIndex - 1);
        else if (wp == VK_RIGHT && g_currentIndex < g_mediaFiles.size() - 1) LoadMedia(g_currentIndex + 1);
        break;
    case WM_CLOSE:
        KillTimer(hwnd, 1); KillTimer(hwnd, 2); ++g_imageLoadSessionId;
        if (g_pPlayer) { g_pPlayer->Shutdown(); g_pPlayer->Release(); g_pPlayer = NULL; }
        if (g_currentImage) { delete g_currentImage; g_currentImage = NULL; }
        DestroyWindow(hwnd); g_hViewerWindow = NULL;
        break;
    }
    return DefWindowProc(hwnd, msg, wp, lp);
}

void AsyncScanDirectory(std::wstring folder, HWND hTarget, int sessionId) {
    CoInitializeEx(NULL, COINIT_MULTITHREADED); MFStartup(MF_VERSION);
    PostMessage(hTarget, WM_USER_SCAN_START, 0, 0);

    WIN32_FIND_DATAW ffd; HANDLE hFind = FindFirstFileW((folder + L"\\*").c_str(), &ffd);
    if (hFind == INVALID_HANDLE_VALUE) { MFShutdown(); CoUninitialize(); PostMessage(hTarget, WM_USER_SCAN_DONE, 0, 0); return; }

    std::vector<std::wstring> filePaths;
    do { if (!(ffd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY)) filePaths.push_back(folder + L"\\" + ffd.cFileName); } while (FindNextFileW(hFind, &ffd) && g_scanSessionId == sessionId);
    FindClose(hFind);

    int total = filePaths.size();
    int validCount = 0;
    std::vector<int> validIndices(total, -1);
    std::vector<MediaType> types(total, MediaType::Unknown);

    for (int i = 0; i < total && g_scanSessionId == sessionId; ++i) {
        types[i] = IdentifyFile(filePaths[i]);
        if (types[i] != MediaType::Unknown) {
            validIndices[i] = validCount++;
            MediaFile* mf = new MediaFile{ filePaths[i], filePaths[i].substr(filePaths[i].find_last_of(L"\\/") + 1), types[i] };
            PostMessage(hTarget, WM_USER_SCAN_FOUND, (WPARAM)mf, 0);
        }
    }

    for (int i = 0; i < total && g_scanSessionId == sessionId; ++i) {
        if (types[i] != MediaType::Unknown) {
            ScanItemData* item = new ScanItemData(); item->uiIndex = validIndices[i]; item->totalCount = validCount; item->sessionId = sessionId;
            if (types[i] == MediaType::Image) item->hBmp = CreateThumbnailWIC(filePaths[i], 120);
            else if (types[i] == MediaType::Video) item->hBmp = CreateVideoThumbnail(filePaths[i], 120);
            else item->hBmp = NULL;
            PostMessage(hTarget, WM_USER_SCAN_ITEM, (WPARAM)item, 0);
        }
    }
    MFShutdown(); CoUninitialize(); PostMessage(hTarget, WM_USER_SCAN_DONE, 0, 0);
}

LRESULT CALLBACK MainProc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
    switch (msg) {
    case WM_CREATE: {
        HWND hBtn = CreateWindowW(L"Button", L"选择目录...", WS_CHILD | WS_VISIBLE, 10, 10, 150, 30, hwnd, (HMENU)201, NULL, NULL);
        g_hProgressText = CreateWindowW(L"Static", L"准备就绪", WS_CHILD | WS_VISIBLE, 170, 15, 600, 30, hwnd, NULL, NULL, NULL);
        g_hListView = CreateWindowW(WC_LISTVIEW, L"", WS_CHILD | WS_VISIBLE | LVS_ICON | LVS_AUTOARRANGE, 0, 50, 800, 550, hwnd, NULL, NULL, NULL);

        ApplyGlobalFont(hBtn); ApplyGlobalFont(g_hProgressText); ApplyGlobalFont(g_hListView);

        HIMAGELIST hImgList = ImageList_Create(120, 120, ILC_COLOR32 | ILC_MASK, 100, 100);
        ImageList_AddIcon(hImgList, LoadIcon(NULL, IDI_APPLICATION));
        ListView_SetImageList(g_hListView, hImgList, LVSIL_NORMAL);
        break;
    }
    case WM_SIZE: MoveWindow(g_hListView, 0, 50, LOWORD(lp), HIWORD(lp) - 50, TRUE); break;
    case WM_COMMAND:
        if (LOWORD(wp) == 201) {
            IFileDialog* pfd = NULL;
            if (SUCCEEDED(CoCreateInstance(CLSID_FileOpenDialog, NULL, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&pfd)))) {
                DWORD dwOptions; pfd->GetOptions(&dwOptions); pfd->SetOptions(dwOptions | FOS_PICKFOLDERS);
                if (SUCCEEDED(pfd->Show(hwnd))) {
                    IShellItem* psi; pfd->GetResult(&psi); PWSTR pszPath; psi->GetDisplayName(SIGDN_FILESYSPATH, &pszPath);
                    std::wstring pathStr = pszPath; CoTaskMemFree(pszPath); psi->Release();
                    int newSessionId = ++g_scanSessionId;
                    std::thread([pathStr, hwnd, newSessionId]() { AsyncScanDirectory(pathStr, hwnd, newSessionId); }).detach();
                } pfd->Release();
            }
        } break;
    case WM_USER_SCAN_START:
        SendMessage(g_hListView, WM_SETREDRAW, FALSE, 0); ListView_DeleteAllItems(g_hListView); g_mediaFiles.clear(); SendMessage(g_hListView, WM_SETREDRAW, TRUE, 0);
        while (ImageList_GetImageCount(ListView_GetImageList(g_hListView, LVSIL_NORMAL)) > 1) { ImageList_Remove(ListView_GetImageList(g_hListView, LVSIL_NORMAL), 1); }
        SetWindowTextW(g_hProgressText, L"正在极速预载文件列表...");
        break;
    case WM_USER_SCAN_FOUND: {
        MediaFile* mf = (MediaFile*)wp; g_mediaFiles.push_back(*mf);
        LVITEMW lvi = { 0 }; lvi.mask = LVIF_TEXT | LVIF_IMAGE | LVIF_PARAM; lvi.iItem = g_mediaFiles.size() - 1; lvi.iImage = 0; lvi.pszText = (LPWSTR)mf->fileName.c_str(); lvi.lParam = g_mediaFiles.size() - 1;
        ListView_InsertItem(g_hListView, &lvi); delete mf;
        break;
    }
    case WM_USER_SCAN_ITEM: {
        ScanItemData* data = (ScanItemData*)wp;
        if (data->sessionId == g_scanSessionId && data->hBmp) {
            int imgIdx = ImageList_Add(ListView_GetImageList(g_hListView, LVSIL_NORMAL), data->hBmp, NULL);
            LVITEMW lvi = { 0 }; lvi.mask = LVIF_IMAGE; lvi.iItem = data->uiIndex; lvi.iImage = imgIdx; ListView_SetItem(g_hListView, &lvi);
        }
        if (data->hBmp) DeleteObject(data->hBmp);
        if (data->uiIndex % 3 == 0 || data->uiIndex + 1 == data->totalCount) {
            wchar_t buf[256]; swprintf(buf, 256, L"正在后台提取缩略图: %d / %d", data->uiIndex + 1, data->totalCount); SetWindowTextW(g_hProgressText, buf);
        }
        delete data; break;
    }
    case WM_USER_SCAN_DONE: SetWindowTextW(g_hProgressText, L"扫描与提取全部完成！"); break;
    case WM_NOTIFY:
        if (((LPNMHDR)lp)->code == NM_DBLCLK && ((LPNMHDR)lp)->hwndFrom == g_hListView) {
            int sel = ListView_GetNextItem(g_hListView, -1, LVNI_SELECTED);
            if (sel != -1) {
                LVITEMW lvi = { 0 }; lvi.mask = LVIF_PARAM; lvi.iItem = sel; ListView_GetItem(g_hListView, &lvi);
                if (!g_hViewerWindow) g_hViewerWindow = CreateWindowW(L"ViewerClass", L"查看器", WS_OVERLAPPEDWINDOW, CW_USEDEFAULT, CW_USEDEFAULT, 1000, 600, NULL, NULL, GetModuleHandle(NULL), NULL);
                ShowWindow(g_hViewerWindow, SW_SHOW);
                BringWindowToTop(g_hViewerWindow);
                SetFocus(g_hViewerWindow);
                LoadMedia(lvi.lParam);
            }
        } break;
    case WM_DESTROY: ++g_scanSessionId; PostQuitMessage(0); break;
    }
    return DefWindowProc(hwnd, msg, wp, lp);
}

int APIENTRY wWinMain(HINSTANCE hInst, HINSTANCE, LPWSTR, int nCmdShow) {
    INITCOMMONCONTROLSEX icex; icex.dwSize = sizeof(INITCOMMONCONTROLSEX); icex.dwICC = ICC_WIN95_CLASSES | ICC_BAR_CLASSES | ICC_UPDOWN_CLASS; InitCommonControlsEx(&icex);
    CoInitializeEx(NULL, COINIT_APARTMENTTHREADED); MFStartup(MF_VERSION);
    GdiplusStartupInput gdiplusStartupInput; ULONG_PTR gdiplusToken; GdiplusStartup(&gdiplusToken, &gdiplusStartupInput, NULL);

    g_hFont = CreateFontW(-14, 0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE, DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY, DEFAULT_PITCH | FF_DONTCARE, L"Microsoft YaHei");

    WNDCLASSW wc = { 0 }; wc.lpfnWndProc = MainProc; wc.hInstance = hInst; wc.hbrBackground = (HBRUSH)(COLOR_WINDOW + 1); wc.hCursor = LoadCursor(NULL, IDC_ARROW); wc.lpszClassName = L"MainBrowserClass"; RegisterClassW(&wc);
    WNDCLASSW wcView = wc; wcView.lpfnWndProc = ViewerProc; wcView.lpszClassName = L"ViewerClass"; RegisterClassW(&wcView);
    WNDCLASSW wcImg = wc; wcImg.lpfnWndProc = ImageHostProc; wcImg.lpszClassName = L"ImageHostClass"; RegisterClassW(&wcImg);
    WNDCLASSW wcVid = wc; wcVid.lpfnWndProc = VideoHostProc; wcVid.lpszClassName = L"VideoHostClass"; RegisterClassW(&wcVid);

    g_hMainWindow = CreateWindowW(L"MainBrowserClass", L"纯 Win32 媒体浏览器 (防封防抖极速缓存版)", WS_OVERLAPPEDWINDOW, CW_USEDEFAULT, CW_USEDEFAULT, 1000, 700, NULL, NULL, hInst, NULL);
    ShowWindow(g_hMainWindow, nCmdShow);

    MSG msg;
    while (GetMessage(&msg, NULL, 0, 0)) {
        bool isViewerOrChild = (msg.hwnd == g_hViewerWindow || GetAncestor(msg.hwnd, GA_ROOT) == g_hViewerWindow);
        if (g_hViewerWindow && isViewerOrChild && msg.message == WM_KEYDOWN) {
            if (msg.wParam == VK_ESCAPE) {
                msg.hwnd = g_hViewerWindow;
            }
            else if (msg.wParam == VK_SPACE) {
                SendMessage(g_hViewerWindow, WM_COMMAND, 102, 0);
                continue;
            }
            else if (msg.wParam == VK_LEFT || msg.wParam == VK_RIGHT) {
                HWND hFocus = GetFocus();
                if (hFocus != g_hTrackProgress && hFocus != g_hTrackVolume) {
                    msg.hwnd = g_hViewerWindow;
                }
            }
        }

        TranslateMessage(&msg); DispatchMessage(&msg);
    }
    if (g_hFont) DeleteObject(g_hFont);
    GdiplusShutdown(gdiplusToken); MFShutdown(); CoUninitialize();
    return 0;
}