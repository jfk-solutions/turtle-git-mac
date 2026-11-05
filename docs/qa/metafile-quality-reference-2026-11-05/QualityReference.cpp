// SPDX-License-Identifier: MIT
// Independent Windows GDI+ ordinary-paint quality / pixel-phase witness.
// No TurtleGit renderer, SVG, CoreGraphics or third-party rasterizer is linked.
#define NOMINMAX
#include <windows.h>
#include <gdiplus.h>
#include <filesystem>
#include <fstream>
#include <vector>
#include <string>
#include <sstream>
#include <iostream>
#include <iterator>
#include <iomanip>
#include <algorithm>
#include <stdexcept>
using namespace Gdiplus;
namespace fs = std::filesystem;
using Bytes = std::vector<BYTE>;
constexpr int W = 128, H = 96;
constexpr size_t Budget = 16 * 1024 * 1024;

static void ok(Status s, const char* step) { if (s != Ok) throw std::runtime_error(std::string(step) + " status=" + std::to_string(s)); }
static void need(const Bytes& b, size_t p, size_t n) { if (p > b.size() || n > b.size() - p) throw std::runtime_error("wire bounds"); }
static WORD u16(const Bytes& b, size_t p) { need(b,p,2);return WORD(b[p] | WORD(b[p+1]) << 8); }
static DWORD u32(const Bytes& b, size_t p) { return DWORD(u16(b,p)) | DWORD(u16(b,p+2)) << 16; }
static Bytes read(const fs::path& p) { std::ifstream f(p,std::ios::binary);if (!f) throw std::runtime_error("read wire");Bytes b((std::istreambuf_iterator<char>(f)),{});if (b.size() > 2*1024*1024) throw std::runtime_error("wire budget");return b; }
static void write(const fs::path& p, const Bytes& b) { std::ofstream f(p,std::ios::binary);f.write(reinterpret_cast<const char*>(b.data()),std::streamsize(b.size()));if (!f) throw std::runtime_error("write bytes"); }
static std::string hex(const Bytes& b, size_t p, size_t n) { need(b,p,n);std::ostringstream s;s << std::hex << std::setfill('0');for (size_t i=0;i<n;i++) s << std::setw(2) << unsigned(b[p+i]);return s.str(); }

enum class Scene { Basic, SaveRestore, Container, RectContainer, Transform, Clip, Over, Copy, Quality, Linear, Hatch, Texture };
struct Case { std::string name; Scene scene; int smoothing, pixel, quality; };
static std::vector<Case> cases() {
    std::vector<Case> a;
    for (int s=0;s<=5;s++) for (int p=0;p<=4;p++) a.push_back({"ordinary-s"+std::to_string(s)+"-p"+std::to_string(p),Scene::Basic,s,p,0});
    a.push_back({"save-restore",Scene::SaveRestore,5,3,0});
    a.push_back({"container",Scene::Container,5,3,0});
    a.push_back({"rectangle-container",Scene::RectContainer,5,3,0});
    a.push_back({"affine-transform",Scene::Transform,5,4,0});
    a.push_back({"device-clip",Scene::Clip,5,4,0});
    a.push_back({"source-over-overlap",Scene::Over,4,3,0});
    a.push_back({"source-copy-overlap",Scene::Copy,4,3,0});
    for (int q=0;q<=4;q++) a.push_back({"compositing-quality-"+std::to_string(q),Scene::Quality,4,3,q});
    for (int q=0;q<=4;q++) a.push_back({"source-copy-compositing-quality-"+std::to_string(q),Scene::Copy,4,3,q});
    for (auto scene : {Scene::Linear,Scene::Hatch,Scene::Texture}) for (int p : {3,4}) {
        std::string n=scene==Scene::Linear ? "linear" : scene==Scene::Hatch ? "hatch" : "texture";
        a.push_back({"brush-"+n+"-p"+std::to_string(p),scene,3,p,0});
    }
    if (a.size()!=53) throw std::runtime_error("case inventory");
    return a;
}
static void state(std::ostream& out, Graphics& g, const char* phase, bool& first) {
    if (!first) out << ',';first=false;
    const auto s=g.GetSmoothingMode();const auto p=g.GetPixelOffsetMode();
    const auto q=g.GetCompositingQuality();const auto c=g.GetCompositingMode();
    out << "{\"phase\":\"" << phase << "\",\"smoothing\":" << int(s) << ",\"pixelOffset\":" << int(p)
        << ",\"compositingQuality\":" << int(q) << ",\"compositingMode\":" << int(c) << "}";
}
static void ordinary(Graphics& g) {
    Pen black(Color(255,0,0,0),1.0f);ok(black.GetLastStatus(),"black pen");
    const REAL xs[]={8.0f,16.25f,24.5f,32.75f};
    for (REAL x:xs) ok(g.DrawLine(&black,x,6.0f,x,28.0f),"fractional vertical line");
    SolidBrush green(Color(255,20,150,70));
    const REAL edges[]={48.125f,58.25f,68.375f,78.5f};
    for (REAL x:edges) ok(g.FillRectangle(&green,x,6.25f,5.0f,22.25f),"fractional fill edge");
    SolidBrush red(Color(255,200,40,20));
    PointF wedge[]={{4.125f,38.25f},{54.875f,40.125f},{8.375f,78.875f}};
    ok(g.FillPolygon(&red,wedge,3,FillModeWinding),"slanted opaque wedge");
    ok(g.DrawLine(&black,64.25f,38.125f,118.875f,68.625f),"thin diagonal");
    SolidBrush alpha(Color(153,20,180,80));Pen blue(Color(255,30,60,220),1.5f);
    ok(g.FillEllipse(&alpha,66.125f,55.375f,21.75f,20.5f),"alpha ellipse");
    ok(g.DrawEllipse(&blue,66.125f,55.375f,21.75f,20.5f),"ellipse stroke");
    Pen curve(Color(255,180,20,160),2.25f);GraphicsPath path;
    ok(path.AddBezier(64.125f,88.25f,78.5f,68.875f,98.25f,98.5f,121.75f,76.125f),"Bezier path");
    ok(g.DrawPath(&curve,&path),"Bezier stroke");
}
static void overlap(Graphics& g) {
    SolidBrush background(Color(255,32,64,96)),red(Color(129,240,30,20)),green(Color(97,20,230,60)),blue(Color(161,30,70,240));
    ok(g.FillRectangle(&background,4.0f,4.0f,120.0f,88.0f),"overlap background");
    ok(g.FillRectangle(&red,10.25f,12.5f,69.5f,56.25f),"overlap red");
    ok(g.FillEllipse(&green,38.125f,20.375f,70.5f,62.25f),"overlap green");
    PointF p[]={{14.25f,80.5f},{113.75f,38.125f},{105.5f,88.25f}};
    ok(g.FillPolygon(&blue,p,3,FillModeAlternate),"overlap blue");
}
static void brushes(Graphics& g, Scene scene) {
    ok(g.SetRenderingOrigin(3,5),"brush rendering origin");
    const RectF area(4.25f,4.25f,119.5f,87.5f);
    if (scene==Scene::Linear) {
        LinearGradientBrush b(PointF(0,0),PointF(128,0),Color(255,220,20,40),Color(255,30,70,230));
        ok(b.GetLastStatus(),"linear brush");ok(b.SetWrapMode(WrapModeTile),"linear tile");ok(g.FillRectangle(&b,area),"linear fill");
    } else if (scene==Scene::Hatch) {
        HatchBrush b(HatchStyleDiagonalCross,Color(255,30,40,220),Color(255,230,200,20));
        ok(b.GetLastStatus(),"hatch brush");ok(g.FillRectangle(&b,area),"hatch fill");
    } else {
        Bitmap tile(2,2,PixelFormat32bppARGB);ok(tile.SetResolution(96,96),"tile DPI");
        ok(tile.SetPixel(0,0,Color(255,240,20,30)),"tile00");ok(tile.SetPixel(1,0,Color(255,30,220,40)),"tile10");
        ok(tile.SetPixel(0,1,Color(255,30,60,230)),"tile01");ok(tile.SetPixel(1,1,Color(255,230,210,30)),"tile11");
        TextureBrush b(&tile,WrapModeTile);ok(b.GetLastStatus(),"texture brush");Matrix m(1,0,0,1,0.25f,0.5f);
        ok(b.SetTransform(&m),"texture transform");ok(g.FillRectangle(&b,area),"texture fill");
    }
}
static std::string draw(Graphics& g, const Case& c) {
    ok(g.Clear(Color(0,0,0,0)),"transparent Clear");ok(g.SetPageUnit(UnitPixel),"UnitPixel");
    ok(g.SetSmoothingMode(static_cast<SmoothingMode>(c.smoothing)),"requested smoothing");
    ok(g.SetPixelOffsetMode(static_cast<PixelOffsetMode>(c.pixel)),"requested pixel offset");
    ok(g.SetCompositingQuality(static_cast<CompositingQuality>(c.quality)),"requested compositing quality");
    ok(g.SetCompositingMode(CompositingModeSourceOver),"initial SourceOver");
    std::ostringstream observations;observations << '[';bool first=true;state(observations,g,"configured",first);
    if (c.scene==Scene::Basic) ordinary(g);
    else if (c.scene==Scene::Over || c.scene==Scene::Copy || c.scene==Scene::Quality) {
        if (c.scene==Scene::Copy) ok(g.SetCompositingMode(CompositingModeSourceCopy),"SourceCopy");
        state(observations,g,"before-overlap",first);overlap(g);
    } else if (c.scene==Scene::Linear || c.scene==Scene::Hatch || c.scene==Scene::Texture) brushes(g,c.scene);
    else if (c.scene==Scene::Transform) {
        Matrix m(0.75f,0.125f,-0.1f,0.75f,18.25f,4.5f);ok(g.SetTransform(&m),"affine transform");ordinary(g);
    } else if (c.scene==Scene::Clip) {
        ok(g.SetClip(RectF(18.125f,12.375f,84.5f,63.25f),CombineModeReplace),"device clip before transform");
        ok(g.TranslateTransform(3.25f,2.5f),"post-clip translation");ordinary(g);
    } else {
        const auto save=g.Save();ok(g.GetLastStatus(),"outer Save");
        ok(g.ScaleTransform(0.45f,0.45f),"first state scale");ordinary(g);ok(g.Restore(save),"outer Restore");
        const auto stateID=g.Save();ok(g.GetLastStatus(),"state Save");
        GraphicsContainer container=0;
        if (c.scene==Scene::Container) {container=g.BeginContainer();ok(g.GetLastStatus(),"BeginContainer");}
        if (c.scene==Scene::RectContainer) {container=g.BeginContainer(RectF(48,0,76,48),RectF(0,0,128,96),UnitPixel);ok(g.GetLastStatus(),"rectangle BeginContainer");}
        ok(g.SetSmoothingMode(SmoothingModeNone),"inner smoothing");ok(g.SetPixelOffsetMode(PixelOffsetModeHalf),"inner pixel");
        ok(g.SetCompositingQuality(CompositingQualityGammaCorrected),"inner quality");state(observations,g,"inside-saved-state",first);
        if (c.scene!=Scene::RectContainer) {ok(g.TranslateTransform(56,0),"second state translation");ok(g.ScaleTransform(0.45f,0.45f),"second state scale");}
        ordinary(g);
        if (c.scene==Scene::Container || c.scene==Scene::RectContainer) {ok(g.EndContainer(container),"EndContainer");state(observations,g,"after-container",first);}
        ok(g.Restore(stateID),"state Restore");state(observations,g,"after-restore",first);
        ok(g.TranslateTransform(12,50),"restored translation");ok(g.ScaleTransform(0.45f,0.45f),"restored scale");ordinary(g);
    }
    state(observations,g,"final",first);observations << ']';return observations.str();
}
static Bytes pixels(Bitmap& image) {
    if (image.GetWidth()!=W || image.GetHeight()!=H) throw std::runtime_error("capture dimensions");
    Bytes out;out.reserve(W*H*4);for (int y=0;y<H;y++) for (int x=0;x<W;x++) {
        Color c;ok(image.GetPixel(x,y,&c),"GetPixel");out.insert(out.end(),{c.GetR(),c.GetG(),c.GetB(),c.GetA()});
    } return out;
}
static std::string pixelSummary(const Bytes& b) {
    size_t ink=0,partial=0;for (size_t p=0;p<b.size();p+=4) {if (b[p+3]) ink++;if (b[p+3] && b[p+3]!=255) partial++;}
    std::ostringstream s;s << "{\"nonzeroAlphaPixels\":" << ink << ",\"partialAlphaPixels\":" << partial << ",\"interiorProbes\":[";
    const int locations[][2]={{16,16},{17,16},{64,48},{119,80},{48,16},{49,16},{58,16},{59,16}};
    bool first=true;for (const auto& xy:locations) {if (!first) s << ',';first=false;size_t p=size_t(xy[1]*W+xy[0])*4;s << "{\"xy\":[" << xy[0] << ',' << xy[1] << "],\"rgba\":[" << int(b[p]) << ',' << int(b[p+1]) << ',' << int(b[p+2]) << ',' << int(b[p+3]) << "]}";}s << "]}";return s.str();
}
static size_t differences(const Bytes& a,const Bytes& b) { if (a.size()!=b.size()) throw std::runtime_error("comparison dimensions");size_t n=0;for (size_t p=0;p<a.size();p+=4) if (!std::equal(a.begin()+p,a.begin()+p+4,b.begin()+p)) n++;return n; }
struct Wire { Bytes reserved; size_t records=0,changed=0;std::string json; };
static Wire auditWire(const Bytes& b) {
    need(b,0,88);if (u32(b,0)!=EMR_HEADER || u32(b,40)!=0x464d4520 || u32(b,48)!=b.size()) throw std::runtime_error("EMF header framing");
    Wire r;r.reserved=b;std::ostringstream s;s << "{\"records\":[";bool first=true;size_t outer=0;bool eof=false;
    for (size_t p=0;p<b.size();) {
        need(b,p,8);DWORD type=u32(b,p),size=u32(b,p+4);if (size<8 || size%4 || size>b.size()-p || ++outer>8192) throw std::runtime_error("EMF record framing");
        if (type==EMR_GDICOMMENT) {
            if (size<12) throw std::runtime_error("short comment record");
            need(b,p+8,4);DWORD n=u32(b,p+8);if (n>size-12) throw std::runtime_error("comment framing");
            if (n>=4 && u32(b,p+12)==0x2b464d45) {
                size_t q=p+16,end=p+12+n;
                while (q<end) {
                    need(b,q,12);WORD rt=u16(b,q),flags=u16(b,q+2);DWORD bytes=u32(b,q+4),data=u32(b,q+8);
                    if (bytes<12 || bytes%4 || bytes>end-q || data>bytes-12 || ++r.records>8192) throw std::runtime_error("EMF+ record framing");
                    if (!first) s << ',';first=false;
                    s << "{\"outerOffset\":" << p << ",\"offset\":" << q << ",\"type\":" << rt << ",\"flags\":" << flags << ",\"size\":" << bytes << ",\"dataSize\":" << data << ",\"dataHex\":\"" << hex(b,q+12,data) << "\"}";
                    if (rt==0x401e || rt==0x4022 || rt==0x4024) {r.reserved[q+3]|=0xff;r.changed++;}
                    q+=bytes;
                }
                if (q!=end) throw std::runtime_error("EMF+ comment ending");
            }
        }
        if (type==EMR_EOF) {if (p+size!=b.size()) throw std::runtime_error("trailing EMF bytes");eof=true;}
        p+=size;
    }
    if (!eof || !r.records) throw std::runtime_error("missing native EMF+ records");
    s << "],\"nativePlusRecordCount\":" << r.records << ",\"reservedHighByteChanges\":" << r.changed << "}";r.json=s.str();return r;
}
struct Replay { Bytes rgba;std::string json; };
static Replay replay(const fs::path& file,bool picture) {
    Bitmap canvas(W,H,PixelFormat32bppARGB);ok(canvas.SetResolution(96,96),"replay DPI");
    std::ostringstream report;report << "{\"consumer\":\"" << (picture?"Bitmap(file,FALSE)+GetRawFormat+Picture-boundary":"Metafile(file)+natural-explicit-rectangle") << "\"";
    {
        Graphics g(&canvas);ok(g.Clear(Color(0,0,0,0)),"replay Clear");ok(g.SetPageUnit(UnitPixel),"replay page");
        if (picture) {
            Bitmap image(file.c_str(),FALSE);const auto constructor=image.GetLastStatus();GUID format{};const auto raw=image.GetRawFormat(&format),loaded=image.GetLastStatus();
            report << ",\"constructorDiagnosticStatus\":" << constructor << ",\"rawFormatStatus\":" << raw << ",\"loadStatusAfterRawFormat\":" << loaded << ",\"rawFormatData1\":" << format.Data1;
            ok(loaded,"Picture load after raw format");ok(raw,"Picture raw format");
            report << ",\"intrinsicWidth\":" << image.GetWidth() << ",\"intrinsicHeight\":" << image.GetHeight();
            ok(g.SetInterpolationMode(InterpolationModeDefault),"Picture interpolation");ok(g.SetPixelOffsetMode(PixelOffsetModeHalf),"Picture pixel offset");
            ImageAttributes attributes;ok(attributes.SetWrapMode(WrapModeTileFlipXY),"Picture wrap");
            ok(g.DrawImage(&image,Rect(0,0,W,H),0,0,W,H,UnitPixel,&attributes),"Picture DrawImage");
        } else {
            Metafile image(file.c_str());ok(image.GetLastStatus(),"native metafile load");RectF bounds;Unit unit;ok(image.GetBounds(&bounds,&unit),"native bounds");
            report << ",\"intrinsicWidth\":" << image.GetWidth() << ",\"intrinsicHeight\":" << image.GetHeight() << ",\"bounds\":[" << bounds.X << ',' << bounds.Y << ',' << bounds.Width << ',' << bounds.Height << "],\"boundsUnit\":" << int(unit);
            ok(g.DrawImage(&image,Rect(0,0,W,H),0,0,W,H,UnitPixel),"natural DrawImage");
        }
    }
    auto bytes=pixels(canvas);report << ",\"pixels\":" << pixelSummary(bytes) << '}';return {std::move(bytes),report.str()};
}
static void capture(const Case& c,const fs::path& out,std::ostream& report) {
    Bitmap direct(W,H,PixelFormat32bppARGB);ok(direct.SetResolution(96,96),"direct DPI");std::string directStates;
    {Graphics g(&direct);directStates=draw(g,c);}auto directBytes=pixels(direct);write(out/(c.name+"-direct.rgba"),directBytes);
    const auto filename=out/(c.name+".emf");std::string recordedStates;
    Bitmap reference(W,H,PixelFormat32bppARGB);ok(reference.SetResolution(96,96),"reference DPI");Graphics referenceGraphics(&reference);HDC hdc=referenceGraphics.GetHDC();if (!hdc) throw std::runtime_error("reference HDC");
    try {
        {Metafile image(filename.c_str(),hdc,RectF(0,0,REAL(W),REAL(H)),MetafileFrameUnitPixel,EmfTypeEmfPlusOnly);ok(image.GetLastStatus(),"native recording");Graphics g(&image);recordedStates=draw(g,c);}
    } catch (...) {referenceGraphics.ReleaseHDC(hdc);throw;}
    ok(referenceGraphics.ReleaseHDC(hdc),"release reference HDC");
    auto wire=read(filename);auto audit=auditWire(wire);
    {std::ofstream records(out/(c.name+"-records.json"));records << audit.json;if (!records) throw std::runtime_error("write record report");}
    auto natural=replay(filename,false),picture=replay(filename,true);
    write(out/(c.name+"-natural.rgba"),natural.rgba);write(out/(c.name+"-picture.rgba"),picture.rgba);
    const auto reservedFile=out/(c.name+"-reserved.emf");write(reservedFile,audit.reserved);
    std::string reservedObservation;
    try {auto reserved=replay(reservedFile,false);write(out/(c.name+"-reserved-natural.rgba"),reserved.rgba);reservedObservation="{\"capture\":"+reserved.json+",\"originalNaturalPixelMismatches\":"+std::to_string(differences(natural.rgba,reserved.rgba))+"}";}
    catch (const std::exception& e) {reservedObservation="{\"error\":\""+std::string(e.what())+"\"}";}
    report << "{\"name\":\"" << c.name << "\",\"requested\":{\"smoothing\":" << c.smoothing << ",\"pixelOffset\":" << c.pixel << ",\"compositingQuality\":" << c.quality << "},\"directStates\":" << directStates << ",\"recordingStates\":" << recordedStates << ",\"directPixels\":" << pixelSummary(directBytes) << ",\"wireBytes\":" << wire.size() << ",\"nativePlusRecordCount\":" << audit.records << ",\"natural\":" << natural.json << ",\"picture\":" << picture.json << ",\"directNaturalPixelMismatches\":" << differences(directBytes,natural.rgba) << ",\"naturalPicturePixelMismatches\":" << differences(natural.rgba,picture.rgba) << ",\"reservedHighByteChanges\":" << audit.changed << ",\"reserved\":" << reservedObservation << "}";
}
int wmain(int argc,wchar_t** argv) {
    if (argc!=2) return 2;ULONG_PTR token=0;GdiplusStartupInput startup;if (GdiplusStartup(&token,&startup,nullptr)!=Ok) return 3;int result=0;
    try {
        const fs::path out(argv[1]);if (fs::exists(out) && !fs::is_empty(out)) throw std::runtime_error("output directory must be fresh");fs::create_directories(out);
        const auto inventory=cases();std::ofstream report(out/"quality-observations.json");
        report << "{\"schema\":1,\"purpose\":\"independent native-recorded ordinary-paint quality and phase observation; no renderer kernel assumed\",\"width\":" << W << ",\"height\":" << H << ",\"rgbaOrder\":\"top-down straight RGBA from GDI+ GetPixel; alpha unchanged\",\"background\":\"transparent Clear\",\"requestedCaseCount\":" << inventory.size() << ",\"brushControls\":{\"bounds\":[4.25,4.25,119.5,87.5],\"linearEndpoints\":[0,0,128,0],\"linearColorsARGB\":[[255,220,20,40],[255,30,70,230]],\"wrapMode\":\"Tile\",\"renderingOrigin\":[3,5],\"hatch\":\"DiagonalCross opaque RGB30/40/220 over230/200/20\",\"textureMatrix\":[1,0,0,1,0.25,0.5],\"texture2x2RGBRows\":[[[240,20,30],[30,220,40]],[[30,60,230],[230,210,30]]]},\"cases\":[";
        bool first=true;for (const auto& c:inventory) {if (!first) report << ',';first=false;capture(c,out,report);report.flush();}
        report << "],\"completedCaseCount\":" << inventory.size() << '}';report.close();if (!report) throw std::runtime_error("write manifest");
        uintmax_t bytes=0;for (const auto& file:fs::directory_iterator(out)) if (file.is_regular_file()) bytes+=file.file_size();if (bytes>Budget) throw std::runtime_error("artifact exceeds16MiB");
        std::cout << "Captured " << inventory.size() << " independent direct/native/Picture cases; " << bytes << " bytes. Pixel equality remains an observation.\n";
    } catch (const std::exception& e) {std::cerr << e.what() << '\n';result=1;}
    GdiplusShutdown(token);return result;
}
