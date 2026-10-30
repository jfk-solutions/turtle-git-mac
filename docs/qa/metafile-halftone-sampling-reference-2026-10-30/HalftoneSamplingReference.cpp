// SPDX-License-Identifier: MIT
// Original independent Windows observation utility. No TurtleGit rendering code.
// continuity.wmf is the byte-identical hand-final-color32-mode4-phase0 input
// retained from Picture observation run40388446061 (2026-10-26), SHA256
// 56587d45ceda1fd246523ca8e04c64bccbed942dbd2aca5c2815937d38555c37.
// Observations constrain candidate sampling/rounding models; matching a finite
// basis does not prove a unique universal Windows kernel or device profile.
#define NOMINMAX
#include <windows.h>
#include <gdiplus.h>
#include <filesystem>
#include <fstream>
#include <vector>
#include <string>
#include <sstream>
#include <iostream>
#include <map>
#include <iterator>
#include <algorithm>
#include <stdexcept>
using namespace Gdiplus;
namespace fs=std::filesystem;
using Bytes=std::vector<BYTE>;
constexpr int W=64,H=40;
static void word(Bytes& b,int n){b.push_back(BYTE(n));b.push_back(BYTE(unsigned(n)>>8));}
static void dword(Bytes& b,DWORD n){word(b,int(n));word(b,int(n>>16));}
static void write(const fs::path& p,const Bytes& b){std::ofstream f(p,std::ios::binary);f.write(reinterpret_cast<const char*>(b.data()),std::streamsize(b.size()));if(!f)throw std::runtime_error("write");}
static Bytes wr(WORD type,Bytes p={}){if(p.size()%2)p.push_back(0);Bytes b;dword(b,DWORD((p.size()+6)/2));word(b,type);b.insert(b.end(),p.begin(),p.end());return b;}
static Bytes shorts(std::initializer_list<int> v){Bytes b;for(int n:v)word(b,n);return b;}
struct Case{
 std::string name,group;bool vertical=false,self=false,mixed=false,mixedIntegral=false,clipped=false,constant64=false;
 int length=7,destination=4,position=3,pointY=3,pattern=0,amplitude=64,quarter=0,crop=0,translation=0,state=0;
 // state0 HALFTONE;1 COLORONCOLOR;2 HALFTONE/save/COLORONCOLOR/restore;
 // state3 COLORONCOLOR/save/HALFTONE/restore.
 std::string key()const{std::ostringstream s;s<<vertical<<self<<mixed<<mixedIntegral<<clipped<<constant64<<":"<<pattern<<":"<<length<<":"<<destination<<":"<<quarter<<":"<<crop<<":"<<translation<<":"<<state;return s.str();}
 int width()const{return pattern==4?8:pattern?7:mixed?8:vertical?1:length+2*crop;}
 int height()const{return pattern==4?4:pattern?7:mixed?8:vertical?length+2*crop:1;}
 int sx()const{return vertical?0:crop;}int sy()const{return vertical?crop:0;}
 int sw()const{return pattern==4?8:pattern?7:mixed?8:vertical?1:length;}int sh()const{return pattern==4?4:pattern?7:mixed?8:vertical?length:1;}
 int dw()const{return pattern==4?3:pattern?4:mixed?(vertical?(mixedIntegral?4:3):4):vertical?1:destination;}int dh()const{return pattern==4?2:pattern?4:mixed?(vertical?4:(mixedIntegral?4:3)):vertical?destination:1;}
 int dx()const{return 30+translation;}int dy()const{return 4+translation;}
 int sample(int x,int y)const{
  int i=vertical?y:x;int base=constant64?64:128;
  if(crop&&(i<crop||i>=crop+length))return 32; // crop guard differs from crop's128 baseline
  if(position>=0&&(pattern==1||pattern==4))return base+((x==position&&y==pointY)?amplitude:0);
  if(position>=0&&pattern==2)return base+(((x+y)&1)?-amplitude:amplitude);
  if(position>=0&&pattern==3)return base+(((x*3+y*5+x*y)%7<3)?amplitude:-amplitude);
  if(position>=0 && (mixed?(vertical?y==3:x==3):i==position+crop))return base+amplitude;
  return base;
 }
};
static std::vector<Case> cases(){std::vector<Case> v;auto add=[&](Case c){c.name="c"+std::to_string(v.size());v.push_back(c);};
 for(bool vertical:{false,true})for(auto pair:{std::pair<int,int>{7,4},{8,3}})for(int pos=0;pos<pair.first;pos++)for(int amp:{-127,-64,-16,16,64,127}){Case c;c.group="signed-impulse";c.vertical=vertical;c.length=pair.first;c.destination=pair.second;c.position=pos;c.amplitude=amp;add(c);}
 for(bool vertical:{false,true})for(auto p:{std::pair<int,int>{17,8},{17,9},{17,16},{16,7},{16,8},{16,9},{31,15},{31,16},{31,17}})for(int amp:{-64,64}){Case c;c.group="ratio";c.vertical=vertical;c.length=p.first;c.destination=p.second;c.position=p.first/2;c.amplitude=amp;add(c);}
 for(bool vertical:{false,true})for(auto p:{std::pair<int,int>{7,4},{8,3}})for(int q=0;q<4;q++)for(int amp:{-64,64}){Case c;c.group="fractional-phase";c.vertical=vertical;c.length=p.first;c.destination=p.second;c.position=p.first/2;c.quarter=q;c.amplitude=amp;add(c);}
 for(bool vertical:{false,true})for(int pos:{0,3,6})for(int amp:{-64,64}){Case c;c.group="guarded-crop";c.vertical=vertical;c.crop=2;c.position=pos;c.amplitude=amp;add(c);}
 for(bool vertical:{false,true})for(auto p:{std::pair<int,int>{7,4},{8,3}})for(int shift:{0,1})for(int amp:{-64,64}){Case c;c.group="self-source";c.vertical=vertical;c.self=true;c.length=p.first;c.destination=p.second;c.position=p.first/2;c.translation=shift;c.amplitude=amp;add(c);}
 for(bool vertical:{false,true})for(int state=0;state<4;state++){Case c;c.group="saved-mode";c.vertical=vertical;c.state=state;add(c);}
 for(bool vertical:{false,true})for(bool integral:{false,true})for(int amp:{-64,64}){Case c;c.group="mixed-axis";c.mixed=true;c.mixedIntegral=integral;c.vertical=vertical;c.amplitude=amp;add(c);}
 for(bool vertical:{false,true})for(int amp:{-64,64}){Case c;c.group="destination-clip";c.vertical=vertical;c.clipped=true;c.amplitude=amp;add(c);}
 for(bool vertical:{false,true})for(int amp:{-64,64}){Case c;c.group="enlargement-control";c.vertical=vertical;c.length=4;c.destination=7;c.position=1;c.amplitude=amp;add(c);}
 for(auto xy:{std::pair<int,int>{3,3},{3,0},{0,0}})for(int amp:{-64,64}){Case c;c.group="point-impulse2d";c.pattern=1;c.position=xy.first;c.pointY=xy.second;c.amplitude=amp;add(c);}
 for(int pattern:{2,3})for(int amp:{16,64})for(int q:{0,1}){Case c;c.group="heldout-pattern2d";c.pattern=pattern;c.amplitude=amp;c.quarter=q;add(c);}
 for(bool vertical:{false,true})for(int q:{1,3})for(int amp:{-64,64}){Case c;c.group="fractional-self-source";c.self=true;c.vertical=vertical;c.quarter=q;c.amplitude=amp;add(c);}
 for(auto xy:{std::pair<int,int>{3,1},{3,0},{0,0}})for(int amp:{-64,64}){Case c;c.group="point-impulse2d-continuity-ratio";c.pattern=4;c.length=8;c.destination=3;c.position=xy.first;c.pointY=xy.second;c.amplitude=amp;add(c);}
 if(v.size()!=328)throw std::runtime_error("diagnostic matrix count");
 std::map<std::string,Case> baseline;for(const auto& c:v){Case b=c;b.position=-1;b.amplitude=0;b.group="matched-constant128";baseline.emplace(b.key(),b);}
 for(auto& p:baseline)add(p.second);
 for(bool vertical:{false,true})for(auto p:{std::pair<int,int>{7,4},{8,3}}){Case c;c.group="constant64";c.vertical=vertical;c.length=p.first;c.destination=p.second;c.position=-1;c.amplitude=0;c.constant64=true;add(c);}
 if(v.size()!=400)throw std::runtime_error("baseline matrix count");return v;
}
static Bytes bitmap(const Case& c){Bytes b=shorts({0,c.width(),c.height(),c.width()*4});b.push_back(1);b.push_back(32);for(int y=0;y<c.height();y++)for(int x=0;x<c.width();x++){BYTE g=BYTE(c.sample(x,y));b.insert(b.end(),{g,g,g,0});}return b;}
static Bytes wmf(const Case& c){std::vector<Bytes> r;auto emit=[&](WORD t,Bytes b={}){r.push_back(wr(t,b));};
 // The isolated Windows wire-state probe41019384262 proved that a
 // prepended MM_TEXT before anisotropic playback can blank Bitmap(FALSE).
 // Match the retained positive wire's initial mode and identity window.
 emit(META_SETMAPMODE,shorts({MM_ANISOTROPIC}));emit(META_SETWINDOWEXT,shorts({H,W}));emit(META_CREATEPENINDIRECT,shorts({PS_NULL,0,0,0,0}));emit(META_SELECTOBJECT,shorts({0}));
 Bytes brush=shorts({BS_SOLID});dword(brush,RGB(64,64,64));word(brush,0);emit(META_CREATEBRUSHINDIRECT,brush);emit(META_SELECTOBJECT,shorts({1}));emit(META_RECTANGLE,shorts({H,W,0,0}));
 if(c.self){for(int y=0;y<c.height();y++)for(int x=0;x<c.width();x++){Bytes p;BYTE g=BYTE(c.sample(x,y));dword(p,RGB(g,g,g));word(p,2+y);word(p,2+x);emit(META_SETPIXEL,p);}}
 emit(META_SETSTRETCHBLTMODE,shorts({c.state==1||c.state==3?COLORONCOLOR:HALFTONE}));
 if(c.state>=2){emit(META_SAVEDC);emit(META_SETSTRETCHBLTMODE,shorts({c.state==2?COLORONCOLOR:HALFTONE}));emit(META_RESTOREDC,shorts({-1}));}
 // Exact rational mapping: logical destination origin/size is multiplied by4;
 // negative window origin supplies quarter-device-pixel translation. Source
 // coordinates of serialized Bitmap16 are independent pixel coordinates.
 emit(META_SETMAPMODE,shorts({MM_ANISOTROPIC}));emit(META_SETWINDOWORG,shorts({c.vertical?-c.quarter:0,c.vertical?0:-c.quarter}));emit(META_SETWINDOWEXT,shorts({H*4,W*4}));emit(META_SETVIEWPORTEXT,shorts({H,W}));
 if(c.clipped)emit(META_INTERSECTCLIPRECT,shorts({(c.dy()+c.dh())*4,(c.dx()+c.dw())*4,(c.dy()+(c.vertical?1:0))*4,(c.dx()+(c.vertical?0:1))*4}));
 Bytes p;dword(p,SRCCOPY);word(p,c.sh()*(c.self?4:1));word(p,c.sw()*(c.self?4:1));word(p,(c.sy()+(c.self?2:0))*(c.self?4:1));word(p,(c.sx()+(c.self?2:0))*(c.self?4:1));
 if(c.self)word(p,0); // META_STRETCHBLT without bitmap has a reserved WORD.
 word(p,c.dh()*4);word(p,c.dw()*4);word(p,c.dy()*4);word(p,c.dx()*4);
 if(!c.self){auto b=bitmap(c);p.insert(p.end(),b.begin(),b.end());}emit(META_STRETCHBLT,p);
 emit(0x0000); // MS-WMF META_EOF opcode; Windows SDK has no META_EOF symbol.
 Bytes out;dword(out,0x9ac6cdd7);word(out,0);word(out,0);word(out,0);word(out,W);word(out,H);word(out,96);dword(out,0);WORD checksum=0;for(size_t i=0;i<out.size();i+=2)checksum^=WORD(out[i]|out[i+1]<<8);word(out,checksum);
 size_t size=18,max=0;for(const auto& a:r){size+=a.size();max=std::max(max,a.size()/2);}word(out,1);word(out,9);word(out,0x300);dword(out,DWORD(size/2));word(out,2);dword(out,DWORD(max));word(out,0);for(const auto& a:r)out.insert(out.end(),a.begin(),a.end());return out;
}
struct Surface{HDC dc=nullptr;HBITMAP bmp=nullptr;HGDIOBJ old=nullptr;void* bits=nullptr;Surface(){dc=CreateCompatibleDC(nullptr);BITMAPINFO b{};b.bmiHeader.biSize=40;b.bmiHeader.biWidth=W;b.bmiHeader.biHeight=-H;b.bmiHeader.biPlanes=1;b.bmiHeader.biBitCount=32;bmp=CreateDIBSection(dc,&b,DIB_RGB_COLORS,&bits,nullptr,0);if(!dc||!bmp)throw std::runtime_error("surface");old=SelectObject(dc,bmp);std::fill_n(static_cast<BYTE*>(bits),W*H*4,BYTE(0));}~Surface(){SelectObject(dc,old);DeleteObject(bmp);DeleteDC(dc);}};
static void surfaceRaw(Surface& s,const fs::path& p){GdiFlush();Bytes b;auto src=static_cast<const BYTE*>(s.bits);for(int i=0;i<W*H;i++)b.insert(b.end(),{src[i*4+2],src[i*4+1],src[i*4],src[i*4+3]});write(p,b);}
static int picture(const fs::path& input,const fs::path& output,std::ostream& o,const Case* candidate=nullptr){int positiveInk=-1;Bitmap diagnostic(input.c_str(),FALSE);Status constructor=diagnostic.GetLastStatus();Bitmap image(input.c_str(),FALSE);GUID format{};Status raw=image.GetRawFormat(&format);Status load=image.GetLastStatus();o<<"{\"rawRGBA\":\""<<output.filename().string()<<"\",\"constructorDiagnosticStatus\":"<<constructor<<",\"rawFormatStatus\":"<<raw<<",\"loadStatusAfterRawFormat\":"<<load;
 if(load==Ok){UINT w=image.GetWidth(),h=image.GetHeight();o<<",\"width\":"<<w<<",\"height\":"<<h<<",\"rawFormatData1\":"<<format.Data1<<",\"dpiX\":"<<image.GetHorizontalResolution()<<",\"dpiY\":"<<image.GetVerticalResolution();
  if(!w||!h||w>256||h>256)throw std::runtime_error("Picture intrinsic dimension budget");
  Bitmap final(w,h,PixelFormat32bppARGB);final.SetResolution(96,96);Status draw;{Graphics g(&final);g.Clear(Color(0,0,0,0));g.SetInterpolationMode(InterpolationModeDefault);g.SetPixelOffsetMode(PixelOffsetModeHighQuality);g.SetPixelOffsetMode(PixelOffsetModeHalf);ImageAttributes a;a.SetWrapMode(WrapModeTileFlipXY);draw=g.DrawImage(&image,Rect(0,0,w,h),0,0,w,h,UnitPixel,&a);}
  Bytes rgba;int errors=0,intrinsicErrors=0,mismatches=0,destinationInk=0,nonzeroAlpha=0;for(UINT y=0;y<h;y++)for(UINT x=0;x<w;x++){Color c,intrinsic;Status s=final.GetPixel(x,y,&c);if(s!=Ok)errors++;if(c.GetA())nonzeroAlpha++;if(candidate&&x>=UINT(candidate->dx())&&x<UINT(candidate->dx()+candidate->dw()+1)&&y>=UINT(candidate->dy())&&y<UINT(candidate->dy()+candidate->dh()+1)&&c.GetA()&&(c.GetR()!=64||c.GetG()!=64||c.GetB()!=64))destinationInk++;if(image.GetPixel(x,y,&intrinsic)!=Ok)intrinsicErrors++;else if(c.GetValue()!=intrinsic.GetValue())mismatches++;rgba.insert(rgba.end(),{c.GetR(),c.GetG(),c.GetB(),c.GetA()});}write(output,rgba);o<<",\"drawStatus\":"<<draw<<",\"getPixelErrors\":"<<errors<<",\"intrinsicGetPixelErrors\":"<<intrinsicErrors<<",\"intrinsicNaturalRGBAMismatches\":"<<mismatches<<",\"nonzeroAlphaPixels\":"<<nonzeroAlpha<<",\"destinationNonBackgroundPixels\":"<<destinationInk;
  if(draw==Ok&&errors==0&&intrinsicErrors==0&&nonzeroAlpha>0)positiveInk=destinationInk;
 }o<<"}";return positiveInk;
}
static void direct(const Case& c,HDC dc,int origin,std::ostream& o){HBRUSH brush=CreateSolidBrush(RGB(64,64,64));RECT r{0,0,W,H};FillRect(dc,&r,brush);DeleteObject(brush);
 auto data=bitmap(c);HDC source=c.self?dc:CreateCompatibleDC(nullptr);HBITMAP b=nullptr;HGDIOBJ old=nullptr;
 if(c.self){for(int y=0;y<c.height();y++)for(int x=0;x<c.width();x++){BYTE g=BYTE(c.sample(x,y));SetPixelV(dc,2+x,2+y,RGB(g,g,g));}}
 else {b=CreateBitmap(c.width(),c.height(),1,32,data.data()+10);if(!b)throw std::runtime_error("CreateBitmap");old=SelectObject(source,b);}
 int previous=SetStretchBltMode(dc,c.state==1||c.state==3?COLORONCOLOR:HALFTONE);BOOL set=FALSE;POINT before{},after{};GetBrushOrgEx(dc,&before);if(origin>=0)set=SetBrushOrgEx(dc,origin==2?1:0,origin==3?1:0,nullptr);GetBrushOrgEx(dc,&after);
 if(c.state>=2){SaveDC(dc);SetStretchBltMode(dc,c.state==2?COLORONCOLOR:HALFTONE);RestoreDC(dc,-1);}
 SetMapMode(dc,MM_ANISOTROPIC);SetWindowExtEx(dc,W*4,H*4,nullptr);SetViewportExtEx(dc,W,H,nullptr);SetWindowOrgEx(dc,c.vertical?0:-c.quarter,c.vertical?-c.quarter:0,nullptr);
 if(c.clipped)IntersectClipRect(dc,(c.dx()+(c.vertical?0:1))*4,(c.dy()+(c.vertical?1:0))*4,(c.dx()+c.dw())*4,(c.dy()+c.dh())*4);
 SetLastError(0);BOOL ok=StretchBlt(dc,c.dx()*4,c.dy()*4,c.dw()*4,c.dh()*4,source,(c.sx()+(c.self?2:0))*(c.self?4:1),(c.sy()+(c.self?2:0))*(c.self?4:1),c.sw()*(c.self?4:1),c.sh()*(c.self?4:1),SRCCOPY);DWORD error=GetLastError();
 o<<"{\"draw\":"<<(ok?"true":"false")<<",\"lastError\":"<<error<<",\"previousMode\":"<<previous<<",\"modeAtDraw\":"<<GetStretchBltMode(dc)<<",\"brushOriginRequested\":"<<origin<<",\"brushOriginCall\":"<<(set?"true":"false")<<",\"brushBefore\":["<<before.x<<","<<before.y<<"],\"brushAfter\":["<<after.x<<","<<after.y<<"]";SIZE window{},viewport{};POINT wo{},vo{};GetWindowExtEx(dc,&window);GetViewportExtEx(dc,&viewport);GetWindowOrgEx(dc,&wo);GetViewportOrgEx(dc,&vo);o<<",\"mapMode\":"<<GetMapMode(dc)<<",\"actualWindowExtent\":["<<window.cx<<","<<window.cy<<"],\"actualViewportExtent\":["<<viewport.cx<<","<<viewport.cy<<"],\"actualWindowOrigin\":["<<wo.x<<","<<wo.y<<"],\"actualViewportOrigin\":["<<vo.x<<","<<vo.y<<"]}";
 if(old)SelectObject(source,old);if(b)DeleteObject(b);if(!c.self)DeleteDC(source);
}
struct Enum{std::ostream* out;bool first=true;};
static int CALLBACK record(HDC dc,HANDLETABLE* handles,METARECORD* r,int n,LPARAM parameter){auto& e=*reinterpret_cast<Enum*>(parameter);BOOL ok=PlayMetaFileRecord(dc,handles,r,n);if(!e.first)*e.out<<",";e.first=false;*e.out<<"{\"function\":"<<r->rdFunction<<",\"words\":"<<r->rdSize<<",\"played\":"<<(ok?"true":"false");if(r->rdFunction==META_STRETCHBLT){SIZE w{},v{};POINT origin{},brush{};GetWindowExtEx(dc,&w);GetViewportExtEx(dc,&v);GetWindowOrgEx(dc,&origin);GetBrushOrgEx(dc,&brush);*e.out<<",\"stretchMode\":"<<GetStretchBltMode(dc)<<",\"windowExtent\":["<<w.cx<<","<<w.cy<<"],\"viewportExtent\":["<<v.cx<<","<<v.cy<<"],\"windowOrigin\":["<<origin.x<<","<<origin.y<<"],\"brushOrigin\":["<<brush.x<<","<<brush.y<<"]";}*e.out<<"}";return 1;}
int main(int argc,char** argv){if(argc!=3)return 2;ULONG_PTR token=0;GdiplusStartupInput startup;if(GdiplusStartup(&token,&startup,nullptr)!=Ok)return 3;int exit=0;
 try{fs::path out=argv[1];if(fs::exists(out)&&!fs::is_empty(out))throw std::runtime_error("output directory must be fresh");fs::create_directories(out);auto matrix=cases();
 // Validate every matched geometry before collecting unknown impulse output.
 // Stable case names/inventory are retained; a failed control ends this run
 // with a valid partial observation report and no diagnostic-kernel captures.
 std::stable_sort(matrix.begin(),matrix.end(),[](const Case& a,const Case& b){auto rank=[](const Case& c){return c.group=="matched-constant128"?(c.pattern==4?0:1):2;};return rank(a)<rank(b);});
 bool positivePreflight=true;size_t positiveCount=0,capturedCount=0;
 std::ofstream json(out/"observations.json");json<<"{\"schema\":1,\"width\":"<<W<<",\"height\":"<<H<<",\"diagnosticCount\":328,\"caseCount\":"<<matrix.size()<<",\"picturePolicy\":\"Bitmap(file,FALSE), hand-authored intrinsic64x40, default interpolation, PixelOffsetHalf, TileFlipXY, natural DrawImage; raw alpha retained\",\"directAlpha\":\"unmodified native DIB alpha (GDI RGB operations do not define alpha)\",\"cases\":[";bool first=true;
 for(const auto& c:matrix){if(!first)json<<",";first=false;auto file=out/(c.name+".wmf");auto bytes=wmf(c);write(file,bytes);json<<"{\"name\":\""<<c.name<<"\",\"group\":\""<<c.group<<"\",\"baselineKey\":\""<<c.key()<<"\",\"vertical\":"<<(c.vertical?"true":"false")<<",\"self\":"<<(c.self?"true":"false")<<",\"mixed\":"<<(c.mixed?"true":"false")<<",\"mixedIntegral\":"<<(c.mixedIntegral?"true":"false")<<",\"destinationClipped\":"<<(c.clipped?"true":"false")<<",\"length\":"<<c.length<<",\"destinationLength\":"<<c.destination<<",\"pattern\":"<<c.pattern<<",\"pointY\":"<<c.pointY<<",\"impulseIndex\":"<<c.position<<",\"amplitude\":"<<c.amplitude<<",\"requestedQuarterPhase\":"<<c.quarter<<",\"cropGuard\":"<<c.crop<<",\"translation\":"<<c.translation<<",\"state\":"<<c.state<<",\"bitmapSize\":["<<c.width()<<","<<c.height()<<"],\"sourceBitmapPixelRect\":["<<c.sx()<<","<<c.sy()<<","<<c.sw()<<","<<c.sh()<<"],\"recordedSourceLogicalRect\":["<<(c.sx()+(c.self?2:0))*(c.self?4:1)<<","<<(c.sy()+(c.self?2:0))*(c.self?4:1)<<","<<c.sw()*(c.self?4:1)<<","<<c.sh()*(c.self?4:1)<<"],\"destinationLogicalRect\":["<<c.dx()*4<<","<<c.dy()*4<<","<<c.dw()*4<<","<<c.dh()*4<<"],\"mapWindowExtent\":[256,160],\"mapViewportExtent\":[64,40],\"picture\":";int positive=picture(file,out/(c.name+"-picture.rgba"),json,&c);if(c.group=="matched-constant128"){positiveCount++;if(positive<=0)positivePreflight=false;}capturedCount++;
  Surface surface;json<<",\"direct\":";direct(c,surface.dc,-1,json);surfaceRaw(surface,out/(c.name+"-direct.rgba"));
  auto payload=bytes.data()+22;HMETAFILE mf=SetMetaFileBitsEx(UINT(bytes.size()-22),payload);json<<",\"records\":[";if(mf){Surface playback;SetMapMode(playback.dc,MM_ANISOTROPIC);SetWindowExtEx(playback.dc,W,H,nullptr);SetViewportExtEx(playback.dc,W,H,nullptr);Enum e{&json};EnumMetaFile(playback.dc,mf,record,reinterpret_cast<LPARAM>(&e));DeleteMetaFile(mf);}json<<"]}";if(!positivePreflight)break;
 }
 json<<"],\"capturedCaseCount\":"<<capturedCount<<",\"positiveBaselinePreflightPassed\":"<<(positivePreflight?"true":"false")<<",\"positiveBaselineCount\":"<<positiveCount<<",\"brushControls\":[";first=true;
 for(bool emf:{false,true})for(int origin:{-1,0,2,3}){if(!first)json<<",";first=false;Case c;c.name="brush-"+std::string(emf?"emf":"wmf")+"-"+std::to_string(origin);c.length=8;c.destination=3;auto path=out/(c.name+(emf?".emf":".wmf"));HDC recording=emf?CreateEnhMetaFileW(nullptr,path.c_str(),nullptr,L"Independent HALFTONE\0brush origin\0\0"):CreateMetaFileW(path.c_str());if(!recording)throw std::runtime_error("recording");json<<"{\"name\":\""<<c.name<<"\",\"format\":\""<<(emf?"emf":"wmf")<<"\",\"recording\":";
  direct(c,recording,origin,json);
  if(emf){HENHMETAFILE m=CloseEnhMetaFile(recording);if(!m)throw std::runtime_error("close EMF");DeleteEnhMetaFile(m);}else{HMETAFILE m=CloseMetaFile(recording);if(!m)throw std::runtime_error("close WMF");DeleteMetaFile(m);std::ifstream f(path,std::ios::binary);Bytes b((std::istreambuf_iterator<char>(f)),{});f.close();auto place=wmf(c);place.resize(22);place.insert(place.end(),b.begin(),b.end());write(path,place);}
  json<<",\"recordTypes\":[";if(!emf){std::ifstream f(path,std::ios::binary);Bytes b((std::istreambuf_iterator<char>(f)),{});size_t offset=40;bool comma=false;while(offset+6<=b.size()){DWORD words=DWORD(b[offset])|(DWORD(b[offset+1])<<8)|(DWORD(b[offset+2])<<16)|(DWORD(b[offset+3])<<24);if(words<3||offset+words*2>b.size())throw std::runtime_error("recorded WMF framing");if(comma)json<<",";comma=true;json<<(b[offset+4]|b[offset+5]<<8);offset+=words*2;}}else{std::ifstream f(path,std::ios::binary);Bytes b((std::istreambuf_iterator<char>(f)),{});size_t offset=0;bool comma=false;while(offset+8<=b.size()){auto u=[&](size_t i){return DWORD(b[i])|(DWORD(b[i+1])<<8)|(DWORD(b[i+2])<<16)|(DWORD(b[i+3])<<24);};DWORD type=u(offset),size=u(offset+4);if(size<8||offset+size>b.size())throw std::runtime_error("recorded EMF framing");if(comma)json<<",";comma=true;json<<type;offset+=size;}}json<<"],\"picture\":";picture(path,out/(c.name+"-picture.rgba"),json,&c);Surface s;json<<",\"direct\":";direct(c,s.dc,origin,json);surfaceRaw(s,out/(c.name+"-direct.rgba"));json<<"}";
 }json<<"],\"continuity\":";auto retained=out/"continuity.wmf";fs::copy_file(fs::path(argv[2]),retained,fs::copy_options::overwrite_existing);picture(retained,out/"continuity-picture.rgba",json);json<<"}";json.close();if(!json)throw std::runtime_error("JSON write");if(!positivePreflight)throw std::runtime_error("matched baseline did not paint; diagnostic matrix was not captured");uintmax_t total=0;for(const auto& f:fs::directory_iterator(out))if(f.is_regular_file())total+=f.file_size();if(total>10*1024*1024)throw std::runtime_error("observation output exceeds10MiB");std::cout<<"Observed "<<matrix.size()<<" WMFs and8 brush controls; bytes="<<total<<"\n";
 }catch(const std::exception& e){std::cerr<<e.what()<<"\n";exit=1;}GdiplusShutdown(token);return exit;
}
