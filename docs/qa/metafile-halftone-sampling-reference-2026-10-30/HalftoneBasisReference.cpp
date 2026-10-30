// SPDX-License-Identifier: MIT
// Independent Windows Bitmap(FALSE) observer. No TurtleGit renderer code.
// Full 2D source basis and 1D boundary/base shifts distinguish kernel support
// from component arithmetic. Existing 400-case held-outs remain separate.
#define NOMINMAX
#include <windows.h>
#include <gdiplus.h>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <vector>
#include <string>
#include <sstream>
#include <iostream>
#include <stdexcept>
#include <map>
#include <set>
#include <algorithm>
using namespace Gdiplus;
namespace fs=std::filesystem;
using Bytes=std::vector<BYTE>;
constexpr int W=64,H=40,DX=30,DY=4;
static void word(Bytes& b,int n){b.push_back(BYTE(n));b.push_back(BYTE(unsigned(n)>>8));}
static void dword(Bytes& b,DWORD n){word(b,int(n));word(b,int(n>>16));}
static Bytes shorts(std::initializer_list<int> v){Bytes b;for(int n:v)word(b,n);return b;}
static Bytes record(WORD type,Bytes payload={}){if(payload.size()%2)payload.push_back(0);Bytes b;dword(b,DWORD(3+payload.size()/2));word(b,type);b.insert(b.end(),payload.begin(),payload.end());return b;}
static void write(const fs::path& path,const Bytes& bytes){std::ofstream f(path,std::ios::binary);f.write(reinterpret_cast<const char*>(bytes.data()),std::streamsize(bytes.size()));if(!f)throw std::runtime_error("write");}
struct Case{std::string name,group;int width=7,height=7,dw=4,dh=4,x=-1,y=-1,base=128,amplitude=0;};
static std::vector<Case> cases(){
 std::vector<Case> v;auto add=[&](Case c){if(c.width<=0||c.height<=0||c.dw<=0||c.dh<=0||c.base<0||c.base>255||c.base+c.amplitude<0||c.base+c.amplitude>255)throw std::runtime_error("case range");c.name="b"+std::to_string(v.size());v.push_back(c);};
 // All matched controls precede every diagnostic. Three independently painted
 // 128 controls establish observable transfer in each geometry. Other bases
 // retain exact-color controls without claiming base64 contrasts with backdrop.
 for(int geometry:{0,1,2}){Case c;c.group="uniform128-control";if(geometry==1){c.width=8;c.height=4;c.dw=3;c.dh=2;}if(geometry==2){c.height=1;c.dh=1;}add(c);}
 for(int base:{16,32,64,96,160,192,224,239}){Case c;c.group="shifted-base-control";c.height=1;c.dh=1;c.base=base;add(c);}
 if(v.size()!=11)throw std::runtime_error("control count");
 for(int geometry:{0,1}){Case c;c.group="full2d-source-basis";if(geometry){c.width=8;c.height=4;c.dw=3;c.dh=2;}for(int y=0;y<c.height;y++)for(int x=0;x<c.width;x++)for(int amplitude:{-127,-64,-16,16,64,127}){c.x=x;c.y=y;c.amplitude=amplitude;add(c);}}
 if(v.size()!=497)throw std::runtime_error("full 2D basis count");
 for(int x:{1,5})for(int amplitude:{-127,-126,-125,-65,-64,-63,-33,-32,-31,-17,-16,-15,-3,-2,-1,1,2,3,15,16,17,31,32,33,63,64,65,125,126,127}){Case c;c.group="dense1d-integer-boundary";c.height=1;c.dh=1;c.x=x;c.y=0;c.amplitude=amplitude;add(c);}
 if(v.size()!=557)throw std::runtime_error("dense boundary count");
 for(int base:{16,32,64,96,160,192,224,239})for(int x:{1,5})for(int amplitude:{-64,-16,16,64}){if(base+amplitude<0||base+amplitude>255)continue;Case c;c.group="shifted-base1d-boundary";c.height=1;c.dh=1;c.x=x;c.y=0;c.base=base;c.amplitude=amplitude;add(c);}
 if(v.size()!=611)throw std::runtime_error("complete basis count");
 std::set<std::string> identities;for(const auto& c:v){std::ostringstream s;s<<c.width<<","<<c.height<<","<<c.dw<<","<<c.dh<<","<<c.x<<","<<c.y<<","<<c.base<<","<<c.amplitude;if(!identities.insert(s.str()).second)throw std::runtime_error("duplicate logical input");}return v;
}
static Bytes wmf(const Case& c){
 std::vector<Bytes> records;auto emit=[&](WORD type,Bytes payload={}){records.push_back(record(type,payload));};
 // Preserve the positive retained wire's initial anisotropic identity mapping.
 // Never prepend MM_TEXT: the isolated nine-case run41019384262 showed that
 // prefix can blank the primary GDI+ metafile consumer before any transfer.
 emit(META_SETMAPMODE,shorts({MM_ANISOTROPIC}));emit(META_SETWINDOWEXT,shorts({H,W}));
 emit(META_CREATEPENINDIRECT,shorts({PS_NULL,0,0,0,0}));emit(META_SELECTOBJECT,shorts({0}));Bytes brush=shorts({BS_SOLID});dword(brush,RGB(64,64,64));word(brush,0);emit(META_CREATEBRUSHINDIRECT,brush);emit(META_SELECTOBJECT,shorts({1}));emit(META_RECTANGLE,shorts({H,W,0,0}));
 emit(META_SETSTRETCHBLTMODE,shorts({HALFTONE}));emit(META_SETMAPMODE,shorts({MM_ANISOTROPIC}));emit(META_SETWINDOWORG,shorts({0,0}));emit(META_SETWINDOWEXT,shorts({H*4,W*4}));emit(META_SETVIEWPORTEXT,shorts({H,W}));
 // The serialized Bitmap16 source rectangle remains in bitmap pixels;
 // multiply only destination logical coordinates by4 under quarter mapping.
 Bytes p;dword(p,SRCCOPY);word(p,c.height);word(p,c.width);word(p,0);word(p,0);word(p,c.dh*4);word(p,c.dw*4);word(p,DY*4);word(p,DX*4);
 auto bm=shorts({0,c.width,c.height,c.width*4});bm.push_back(1);bm.push_back(32);for(int y=0;y<c.height;y++)for(int x=0;x<c.width;x++){BYTE g=BYTE(c.base+((x==c.x&&y==c.y)?c.amplitude:0));bm.insert(bm.end(),{g,g,g,0});}p.insert(p.end(),bm.begin(),bm.end());emit(META_STRETCHBLT,p);emit(0x0000);
 Bytes b;dword(b,0x9ac6cdd7);word(b,0);word(b,0);word(b,0);word(b,W);word(b,H);word(b,96);dword(b,0);WORD check=0;for(size_t i=0;i<b.size();i+=2)check^=WORD(b[i]|b[i+1]<<8);word(b,check);size_t words=9,maximum=0;for(const auto& r:records){words+=r.size()/2;maximum=std::max(maximum,r.size()/2);}word(b,1);word(b,9);word(b,0x300);dword(b,DWORD(words));word(b,2);dword(b,DWORD(maximum));word(b,0);for(const auto& r:records)b.insert(b.end(),r.begin(),r.end());return b;
}
struct Capture{bool observable=false,constantExact=false,continuityExact=false;std::string json;};
static Capture capture(const fs::path& input,const fs::path& output,const Case* candidate=nullptr){
 std::ostringstream o;Bitmap diagnostic(input.c_str(),FALSE);Status constructor=diagnostic.GetLastStatus();Bitmap image(input.c_str(),FALSE);GUID format{};Status raw=image.GetRawFormat(&format),load=image.GetLastStatus();o<<"{\"rawRGBA\":\""<<output.filename().string()<<"\",\"constructorDiagnosticStatus\":"<<constructor<<",\"rawFormatStatus\":"<<raw<<",\"loadStatusAfterRawFormat\":"<<load;Capture result;
 if(load==Ok){UINT w=image.GetWidth(),h=image.GetHeight();o<<",\"width\":"<<w<<",\"height\":"<<h<<",\"rawFormatData1\":"<<format.Data1;if(w!=(candidate?W:240)||h!=(candidate?H:160))throw std::runtime_error("intrinsic dimensions differ from retained geometry");
  Bitmap canvas(w,h,PixelFormat32bppARGB);canvas.SetResolution(96,96);Status draw;{Graphics g(&canvas);g.Clear(Color(0,0,0,0));g.SetInterpolationMode(InterpolationModeDefault);g.SetPixelOffsetMode(PixelOffsetModeHighQuality);g.SetPixelOffsetMode(PixelOffsetModeHalf);ImageAttributes attributes;attributes.SetWrapMode(WrapModeTileFlipXY);draw=g.DrawImage(&image,Rect(0,0,w,h),0,0,w,h,UnitPixel,&attributes);}
  Bytes rgba;int errors=0,intrinsicErrors=0,mismatches=0,nonzeroAlpha=0,ink=0;for(UINT y=0;y<h;y++)for(UINT x=0;x<w;x++){Color c,intrinsic;if(canvas.GetPixel(x,y,&c)!=Ok)errors++;if(image.GetPixel(x,y,&intrinsic)!=Ok)intrinsicErrors++;else if(c.GetValue()!=intrinsic.GetValue())mismatches++;if(c.GetA())nonzeroAlpha++;if(candidate&&x>=DX&&x<UINT(DX+candidate->dw)&&y>=DY&&y<UINT(DY+candidate->dh)&&c.GetA()&&(c.GetR()!=64||c.GetG()!=64||c.GetB()!=64))ink++;rgba.insert(rgba.end(),{c.GetR(),c.GetG(),c.GetB(),c.GetA()});}
  write(output,rgba);result.observable=raw==Ok&&draw==Ok&&errors==0&&intrinsicErrors==0&&nonzeroAlpha>0;o<<",\"drawStatus\":"<<draw<<",\"getPixelErrors\":"<<errors<<",\"intrinsicGetPixelErrors\":"<<intrinsicErrors<<",\"intrinsicNaturalRGBAMismatches\":"<<mismatches<<",\"nonzeroAlphaPixels\":"<<nonzeroAlpha<<",\"destinationNonBackgroundPixels\":"<<ink;
  if(candidate){result.constantExact=result.observable;o<<",\"destinationRGBA\":[";bool first=true;for(int y=0;y<candidate->dh;y++)for(int x=0;x<candidate->dw;x++){if(!first)o<<",";first=false;size_t p=((DY+y)*w+DX+x)*4;o<<"[";for(int k=0;k<4;k++){if(k)o<<",";o<<int(rgba[p+k]);if(rgba[p+k]!=(k==3?255:candidate->base))result.constantExact=false;}o<<"]";}o<<"]";}
  else{const int expected[6][3]={{19,25,20},{52,176,76},{83,62,131},{152,43,112},{184,194,168},{216,80,223}};result.continuityExact=result.observable;for(int i=0;i<6;i++)for(int k=0;k<3;k++)if(rgba[((8+i/3)*w+8+i%3)*4+k]!=expected[i][k])result.continuityExact=false;o<<",\"originalSixRGBPassed\":"<<(result.continuityExact?"true":"false");}
 }o<<"}";result.json=o.str();return result;
}
int main(int argc,char** argv){if(argc!=3)return 2;ULONG_PTR token=0;GdiplusStartupInput startup;if(GdiplusStartup(&token,&startup,nullptr)!=Ok)return 3;int exitCode=0;
 try{fs::path out=argv[1];if(fs::exists(out)&&!fs::is_empty(out))throw std::runtime_error("output directory must be fresh");fs::create_directories(out);auto matrix=cases();auto retained=out/"continuity.wmf";fs::copy_file(fs::path(argv[2]),retained,fs::copy_options::overwrite_existing);auto continuity=capture(retained,out/"continuity-picture.rgba");std::ofstream report(out/"basis-observations.json");report<<"{\"schema\":1,\"purpose\":\"distinguish full 2D support and boundary/base component arithmetic; no inferred expected kernel\",\"requestedCaseCount\":611,\"diagnosticCount\":600,\"requestedUniformControlCount\":11,\"serializedFourthByte\":0,\"bitmapPlanes\":1,\"bitmapBitsPerPixel\":32,\"sourceComponentPolicy\":\"base plus signed amplitude is validated within0..255 before wire construction; no clipping or normalization\",\"width\":64,\"height\":40,\"consumer\":\"Bitmap(file,FALSE), GetRawFormat then GetLastStatus; default interpolation PixelOffsetHalf TileFlipXY natural DrawImage; unmodified RGBA; intrinsic/natural compared; no direct GDI captures\",\"continuity\":"<<continuity.json<<",\"cases\":[";
 bool first=true,controlsPassed=continuity.continuityExact,observable=controlsPassed;size_t captured=0,controls=0,positive128=0;
 if(controlsPassed)for(const auto& c:matrix){auto path=out/(c.name+".wmf");write(path,wmf(c));auto image=capture(path,out/(c.name+"-picture.rgba"),&c);if(!first)report<<",";first=false;report<<"{\"name\":\""<<c.name<<"\",\"group\":\""<<c.group<<"\",\"bitmapSize\":["<<c.width<<","<<c.height<<"],\"sourceBitmapPixelRect\":[0,0,"<<c.width<<","<<c.height<<"],\"destinationLogicalRect\":[120,16,"<<c.dw*4<<","<<c.dh*4<<"],\"destinationDeviceRect\":[30,4,"<<c.dw<<","<<c.dh<<"],\"sourcePoint\":["<<c.x<<","<<c.y<<"],\"base\":"<<c.base<<",\"amplitude\":"<<c.amplitude<<",\"stretchMode\":4,\"picture\":"<<image.json<<"}";report.flush();captured++;observable=observable&&image.observable;if(c.x<0){controls++;controlsPassed=controlsPassed&&image.constantExact;if(c.base==128)positive128++;}if(!observable||!controlsPassed)break;}
 report<<"],\"capturedCaseCount\":"<<captured<<",\"uniformControlCount\":"<<controls<<",\"positive128ControlCount\":"<<positive128<<",\"uniformControlsPassed\":"<<(controlsPassed?"true":"false")<<",\"allCapturedObservable\":"<<(observable?"true":"false")<<"}";report.close();if(!report)throw std::runtime_error("observation JSON write");if(!controlsPassed||controls!=11||positive128!=3||!observable||captured!=611)throw std::runtime_error("positive controls or observation completeness failed; preserve partial data");uintmax_t total=0;for(const auto& f:fs::directory_iterator(out))if(f.is_regular_file())total+=f.file_size();if(total>=10*1024*1024)throw std::runtime_error("basis artifact budget exceeds10MiB");std::cout<<"Observed611 primary captures (11 controls,600 diagnostics); bytes="<<total<<"\n";
 }catch(const std::exception& error){std::cerr<<error.what()<<"\n";exitCode=1;}GdiplusShutdown(token);return exitCode;
}
