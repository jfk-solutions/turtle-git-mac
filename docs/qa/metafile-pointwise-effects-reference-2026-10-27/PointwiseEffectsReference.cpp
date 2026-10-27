// Original Windows SDK assay. This observes pixels; it contains no port formulas.
#define GDIPVER 0x0110
#include <windows.h>
#include <gdiplus.h>
#include <algorithm>
#include <array>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <memory>
#include <stdexcept>
#include <string>
#include <vector>
using namespace Gdiplus;
namespace fs = std::filesystem;
static constexpr UINT side = 32;
static CLSID pngEncoder{};

static void check(Status status, const char* operation) {
    if (status != Ok) throw std::runtime_error(std::string(operation) + ":" + std::to_string(status));
}
static std::string json(const std::string& text) {
    std::string out = "\"";
    const char hex[] = "0123456789abcdef";
    for (unsigned char ch : text) {
        if (ch == '"' || ch == '\\') { out += '\\'; out += char(ch); }
        else if (ch < 32) { out += "\\u00"; out += hex[ch >> 4]; out += hex[ch & 15]; }
        else out += char(ch);
    }
    return out + '"';
}
static std::ofstream file(const fs::path& path, bool binary = false) {
    std::ofstream out(path, std::ios::out | std::ios::trunc | (binary ? std::ios::binary : std::ios::openmode(0)));
    out.exceptions(std::ios::badbit | std::ios::failbit);
    if (!out) throw std::runtime_error("cannot create " + path.filename().string());
    return out;
}
struct Startup {
    ULONG_PTR token{};
    explicit Startup(UINT version) {
        GdiplusStartupInput input; input.GdiplusVersion = version;
        check(GdiplusStartup(&token, &input, nullptr), "startup");
    }
    ~Startup() { if (token) GdiplusShutdown(token); }
};
struct ScreenDC {
    HDC value = GetDC(nullptr);
    ScreenDC() { if (!value) throw std::runtime_error("screen DC unavailable"); }
    ~ScreenDC() { ReleaseDC(nullptr, value); }
};
static void findPNGEncoder() {
    UINT count = 0, bytes = 0;
    check(GetImageEncodersSize(&count, &bytes), "encoder size");
    if (!count || !bytes) throw std::runtime_error("no image encoders");
    std::vector<BYTE> buffer(bytes);
    auto encoders = reinterpret_cast<ImageCodecInfo*>(buffer.data());
    check(GetImageEncoders(count, bytes, encoders), "encoders");
    for (UINT i = 0; i < count; ++i) if (wcscmp(encoders[i].MimeType, L"image/png") == 0) {
        pngEncoder = encoders[i].Clsid; return;
    }
    throw std::runtime_error("no PNG encoder");
}
static Color sourceColor(UINT index) {
    if (index < 256) return Color(255, BYTE(index), BYTE(index), BYTE(index));
    if (index < 985) {
        static constexpr BYTE levels[] = {0,1,31,63,127,128,191,254,255};
        UINT n = index - 256;
        return Color(255, levels[n / 81], levels[(n / 9) % 9], levels[n % 9]);
    }
    static constexpr BYTE alpha[] = {0,1,2,3,7,15,31,63,127,128,191,254,255};
    static constexpr BYTE colors[][3] = {{70,140,210},{255,1,128},{1,255,0}};
    UINT n = index - 985;
    return Color(alpha[n % 13], colors[n / 13][0], colors[n / 13][1], colors[n / 13][2]);
}
static std::unique_ptr<Bitmap> atlas() {
    auto result = std::make_unique<Bitmap>(side, side, PixelFormat32bppARGB);
    check(result->GetLastStatus(), "atlas allocation"); check(result->SetResolution(96,96), "atlas DPI");
    for (UINT i = 0; i < side * side; ++i) check(result->SetPixel(i % side, i / side, sourceColor(i)), "atlas pixel");
    return result;
}
static void pixels(Bitmap& image, const fs::path& dir, const std::string& name, std::ostream& report) {
    UINT width = image.GetWidth(), height = image.GetHeight();
    check(image.GetLastStatus(), "image dimensions");
    if (!width || !height || width > 128 || height > 128) throw std::runtime_error("unexpected image dimensions");
    check(image.Save((dir / (name + ".png")).c_str(), &pngEncoder, nullptr), "save PNG");
    auto out = file(dir / (name + ".rgba"), true);
    for (UINT y = 0; y < height; ++y) for (UINT x = 0; x < width; ++x) {
        Color color; check(image.GetPixel(x,y,&color), "read pixel");
        const BYTE sample[] = {color.GetR(),color.GetG(),color.GetB(),color.GetA()};
        out.write(reinterpret_cast<const char*>(sample), 4);
    }
    report << ",\"width\":" << width << ",\"height\":" << height
           << ",\"rgba\":" << json(name + ".rgba") << ",\"png\":" << json(name + ".png");
}
enum class Family { balance, hsl, levels, curve, tint };
struct Case {
    Family family;
    std::array<int,3> values;
    std::string name;
    const char* familyName() const {
        switch (family) {
        case Family::balance:return "colorBalance";
        case Family::hsl:return "hueSaturationLightness";
        case Family::levels:return "levels";
        case Family::curve:return "colorCurve";
        case Family::tint:return "tint";
        }
        throw std::runtime_error("unknown family");
    }
    void describe(std::ostream& out) const {
        const char* keys[3]{};
        switch (family) {
        case Family::balance:keys[0]="cyanRed";keys[1]="magentaGreen";keys[2]="yellowBlue";break;
        case Family::hsl:keys[0]="hueLevel";keys[1]="saturationLevel";keys[2]="lightnessLevel";break;
        case Family::levels:keys[0]="highlight";keys[1]="midtone";keys[2]="shadow";break;
        case Family::curve:keys[0]="adjustment";keys[1]="channel";keys[2]="adjustValue";break;
        case Family::tint:keys[0]="hue";keys[1]="amount";break;
        }
        out << ",\"source\":" << json(name) << ",\"family\":" << json(familyName()) << ",\"parameters\":{";
        for (int i = 0; i < 3 && keys[i]; ++i) { if (i) out << ','; out << json(keys[i]) << ':' << values[i]; }
        out << "},\"emf\":" << json(name + ".emf");
    }
};
static std::vector<Case> cases() {
    std::vector<Case> result;
    auto add = [&](Family family, const char* prefix, int a, int b, int c) {
        std::array<int,3> values{{a,b,c}};
        for (const auto& prior : result) if (prior.family == family && prior.values == values) return;
        result.push_back({family,values,std::string(prefix)+"-"+std::to_string(a)+"-"+std::to_string(b)+"-"+std::to_string(c)});
    };
    for (int a : {-75,0,60}) for (int b : {-75,0,60}) for (int c : {-75,0,60}) add(Family::balance,"balance",a,b,c);
    for (int axis = 0; axis < 3; ++axis) for (int edge : {-100,100}) {
        int v[3]{};v[axis]=edge;add(Family::balance,"balance",v[0],v[1],v[2]);
    }
    for (int h : {-120,0,120}) for (int s : {-75,0,60}) for (int l : {-75,0,60}) add(Family::hsl,"hsl",h,s,l);
    for (int axis = 0; axis < 3; ++axis) for (int sign : {-1,1}) {
        int v[3]{};v[axis]=sign*(axis==0 ? 180:100);add(Family::hsl,"hsl",v[0],v[1],v[2]);
    }
    for (int h : {0,50,100}) for (int m : {-100,0,100}) for (int s : {0,50,100}) add(Family::levels,"levels",h,m,s);
    for (int mode = 0; mode < 8; ++mode) for (int channel = 0; channel < 4; ++channel) {
        const std::array<int,5> values = mode < 2 ? std::array<int,5>{{-255,-64,0,64,255}} :
            mode < 6 ? std::array<int,5>{{-100,-25,0,25,100}} : std::array<int,5>{{0,1,127,254,255}};
        for (int value : values) add(Family::curve,"curve",mode,channel,value);
    }
    for (int h : {-180,-120,-60,0,60,120,180}) for (int amount : {-100,-50,0,50,100}) add(Family::tint,"tint",h,amount,0);
    if (result.size() != 288) throw std::runtime_error("case inventory changed");
    return result;
}
// Each callback receives a concrete SDK object with its ordinary lifetime.
// Never delete a derived Effect through an assumed virtual base destructor.
template<class Body> static void withEffect(const Case& item, Body&& body) {
    const auto& v=item.values;
    switch (item.family) {
    case Family::balance: {ColorBalanceParams p{v[0],v[1],v[2]};ColorBalance e;body(e,e.SetParameters(&p));break;}
    case Family::hsl: {HueSaturationLightnessParams p{v[0],v[1],v[2]};HueSaturationLightness e;body(e,e.SetParameters(&p));break;}
    case Family::levels: {LevelsParams p{v[0],v[1],v[2]};Levels e;body(e,e.SetParameters(&p));break;}
    case Family::curve: {ColorCurveParams p{static_cast<CurveAdjustments>(v[0]),static_cast<CurveChannel>(v[1]),v[2]};ColorCurve e;body(e,e.SetParameters(&p));break;}
    case Family::tint: {TintParams p{v[0],v[1]};Tint e;body(e,e.SetParameters(&p));break;}
    }
}
static void record(const Case& item, Effect& effect, const fs::path& dir, std::ostream& out) {
    ScreenDC screen;
    Metafile recorded((dir/(item.name+".emf")).c_str(),screen.value,RectF(0,0,REAL(side),REAL(side)),
                      MetafileFrameUnitPixel,EmfTypeEmfPlusOnly,L"TurtleGit original pointwise reference");
    const Status created=recorded.GetLastStatus();out << ",\"recordCreateStatus\":" << created;
    if (created != Ok) return;
    Graphics graphics(&recorded);check(graphics.GetLastStatus(),"record graphics");
    check(graphics.SetPageUnit(UnitPixel),"record units");
    check(graphics.SetCompositingMode(CompositingModeSourceCopy),"record compositing");
    check(graphics.Clear(Color(0,0,0,0)),"record clear");
    auto input=atlas();RectF source(0,0,REAL(side),REAL(side));Matrix identity;
    const Status status=graphics.DrawImage(input.get(),&source,&identity,&effect,nullptr,UnitPixel);
    out << ",\"recordStatus\":" << status << ",\"recordFrameWidth\":32,\"recordFrameHeight\":32";
}
static void direct(const Case& item, Effect& effect, const fs::path& dir, const std::string& prefix, std::ostream& out) {
    auto input=atlas();effect.UseAuxData(TRUE);
    const Status applied=input->ApplyEffect(&effect,nullptr);
    const UINT auxBytes=effect.GetAuxDataSize();
    out << ",\"applyStatus\":" << applied << ",\"auxBytes\":" << auxBytes;
    if (effect.GetAuxData() && auxBytes > 0) {
        if (auxBytes > 1024*1024) throw std::runtime_error("auxiliary data exceeds assay bound");
        const std::string name=prefix+item.name+".lut";
        auto aux=file(dir/name,true);aux.write(static_cast<const char*>(effect.GetAuxData()),auxBytes);
        out << ",\"lut\":" << json(name);
    }
    if (applied == Ok) pixels(*input,dir,prefix+item.name,out);
}
static void replay(const Case& item, const fs::path& dir, const std::string& prefix, std::ostream& out) {
    Bitmap image((dir/(item.name+".emf")).c_str(),FALSE);
    const Status loaded=image.GetLastStatus();out << ",\"bitmapLoadStatus\":" << loaded;
    if (loaded != Ok) return;
    const UINT width=image.GetWidth(),height=image.GetHeight();
    out << ",\"intrinsicWidth\":" << width << ",\"intrinsicHeight\":" << height
        << ",\"expectedSize\":" << (width==side && height==side ? "true":"false");
    // Retain true dimensions: a recorder/constructor mismatch is never hidden
    // by stretching a successful result into the requested 32x32 viewport.
    if (!width || !height || width>128 || height>128) throw std::runtime_error("unbounded replay dimensions");
    out << ",\"intrinsic\":{\"name\":" << json(prefix+item.name+"-intrinsic");
    pixels(image,dir,prefix+item.name+"-intrinsic",out);out << '}';
    Bitmap output(width,height,PixelFormat32bppARGB);check(output.GetLastStatus(),"replay allocation");
    check(output.SetResolution(96,96),"replay DPI");
    Status drawn;
    {
        Graphics graphics(&output);check(graphics.Clear(Color(0,0,0,0)),"replay clear");
        check(graphics.SetCompositingMode(CompositingModeSourceCopy),"replay compositing");
        check(graphics.SetInterpolationMode(InterpolationModeDefault),"Picture interpolation");
        check(graphics.SetPixelOffsetMode(PixelOffsetModeHalf),"Picture pixel offset");
        ImageAttributes attributes;check(attributes.SetWrapMode(WrapModeTileFlipXY),"Picture wrap");
        drawn=graphics.DrawImage(&image,Rect(0,0,INT(width),INT(height)),0,0,INT(width),INT(height),UnitPixel,&attributes);
    }
    out << ",\"drawStatus\":" << drawn;
    if (drawn == Ok) pixels(output,dir,prefix+item.name,out);
}
int main(int argc,char** argv) {
    if (argc != 3) return 2;
    try {
        const std::string mode=argv[1];
        if (mode!="generate" && mode!="direct-v1" && mode!="replay" && mode!="replay-v1") return 2;
        const bool versionOne=mode=="direct-v1" || mode=="replay-v1";
        Startup startup(versionOne ? 1:2);findPNGEncoder();
        const fs::path dir=fs::absolute(argv[2]);fs::create_directories(dir);
        auto report=file(dir/(mode+".json"));
        wchar_t modulePath[32768]{};
        const DWORD moduleLength=GetModuleFileNameW(GetModuleHandleW(L"gdiplus.dll"),modulePath,32768);
        if (!moduleLength || moduleLength>=32768) throw std::runtime_error("cannot identify loaded GDI+ module");
        report << "{\"platform\":\"native Windows GDI+\",\"startupVersion\":" << (versionOne ? 1:2)
               << ",\"gdiplusModule\":" << json(fs::path(modulePath).u8string())
               << ",\"mode\":" << json(mode) << ",\"caseCount\":288,\"format\":\"straight RGBA row-major top-left\",\"atlas\":{";
        report << "\"width\":32,\"height\":32,\"rgba\":\"atlas.rgba\",\"png\":\"atlas.png\",\"requestedRGBA\":\"atlas-requested.rgba\","
               << "\"gray\":{\"start\":0,\"count\":256,\"alpha\":255},"
               << "\"cube\":{\"start\":256,\"count\":729,\"levels\":[0,1,31,63,127,128,191,254,255],\"order\":\"red major, blue minor\",\"alpha\":255},"
               << "\"alphaSpecial\":{\"start\":985,\"count\":39,\"rgb\":[[70,140,210],[255,1,128],[1,255,0]],\"alpha\":[0,1,2,3,7,15,31,63,127,128,191,254,255],\"order\":\"RGB major, alpha minor\"}}";
        if (mode=="generate") {
            auto requested=file(dir/"atlas-requested.rgba",true);
            for (UINT i=0;i<side*side;++i) {
                const Color c=sourceColor(i);const BYTE p[]={c.GetR(),c.GetG(),c.GetB(),c.GetA()};
                requested.write(reinterpret_cast<const char*>(p),4);
            }
            auto input=atlas();report << ",\"sourceAtlas\":{\"name\":\"atlas\"";pixels(*input,dir,"atlas",report);report << '}';
        }
        report << ",\"cases\":[";
        bool first=true;
        for (const auto& item:cases()) {
            if (!first) report << ',';first=false;
            const std::string prefix=mode=="generate" ? "":mode+"-";
            report << "{\"name\":" << json(prefix+item.name);item.describe(report);
            try {
                if (mode=="generate" || mode=="direct-v1") {
                    if (mode=="generate") {
                        try {withEffect(item,[&](auto& effect,Status status) {
                            report << ",\"recordSetParametersStatus\":" << status;
                            if (status==Ok) record(item,effect,dir,report);
                        });} catch (const std::exception& error) {report << ",\"recordError\":" << json(error.what());}
                    }
                    // Fresh instance excludes ApplyEffect auxiliary state from
                    // the original SDK recording and from each other case.
                    try {withEffect(item,[&](auto& effect,Status status) {
                        report << ",\"setParametersStatus\":" << status;
                        if (status==Ok) direct(item,effect,dir,prefix,report);
                    });} catch (const std::exception& error) {report << ",\"directError\":" << json(error.what());}
                } else replay(item,dir,prefix,report);
            } catch (const std::exception& error) {report << ",\"error\":" << json(error.what());}
            report << '}';report.flush();
        }
        report << "]}\n";report.close();return 0;
    } catch(const std::exception& error) {std::cerr << error.what() << '\n';return 1;}
}
