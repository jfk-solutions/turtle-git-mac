// SPDX-License-Identifier: MIT
// Independent, minimal Bitmap16 wire-state discriminator. No renderer code.
// Starting bytes: continuity.wmf SHA256
// 56587d45ceda1fd246523ca8e04c64bccbed942dbd2aca5c2815937d38555c37.
// This experiment does not identify a sampling kernel. Changed variants may
// legitimately draw nothing; those results remain observations.
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
#include <array>
#include <algorithm>
using namespace Gdiplus;
namespace fs=std::filesystem;
using Bytes=std::vector<BYTE>;
constexpr int W=240,H=160;
static void need(const Bytes& b,size_t p,size_t n){if(p>b.size()||n>b.size()-p)throw std::runtime_error("wire bounds");}
static WORD u16(const Bytes& b,size_t p){need(b,p,2);return WORD(b[p]|b[p+1]<<8);}
static DWORD u32(const Bytes& b,size_t p){return DWORD(u16(b,p))|DWORD(u16(b,p+2))<<16;}
static void set16(Bytes& b,size_t p,int n){need(b,p,2);b[p]=BYTE(n);b[p+1]=BYTE(unsigned(n)>>8);}
static void set32(Bytes& b,size_t p,DWORD n){set16(b,p,int(n));set16(b,p+2,int(n>>16));}
static void word(Bytes& b,int n){b.push_back(BYTE(n));b.push_back(BYTE(unsigned(n)>>8));}
static void dword(Bytes& b,DWORD n){word(b,int(n));word(b,int(n>>16));}
static Bytes read(const fs::path& p){std::ifstream f(p,std::ios::binary);if(!f)throw std::runtime_error("read");Bytes b((std::istreambuf_iterator<char>(f)),{});if(b.size()>1024*1024)throw std::runtime_error("input size");return b;}
static void write(const fs::path& p,const Bytes& b){std::ofstream f(p,std::ios::binary);f.write(reinterpret_cast<const char*>(b.data()),std::streamsize(b.size()));if(!f)throw std::runtime_error("write");}
static Bytes record(WORD type,std::initializer_list<int> args){Bytes b;dword(b,DWORD(3+args.size()));word(b,type);for(int n:args)word(b,n);return b;}
struct Layout{size_t blit=0,map=0,pixels=0;};
static Layout validate(const Bytes& b){
 need(b,0,40);if(u32(b,0)!=0x9ac6cdd7||u16(b,10)!=W||u16(b,12)!=H||u16(b,14)!=96)throw std::runtime_error("continuity placeable header");
 WORD check=0;for(size_t p=0;p<20;p+=2)check^=u16(b,p);if(check!=u16(b,20))throw std::runtime_error("placeable checksum");
 if(u16(b,24)!=9||u16(b,26)!=0x300||u32(b,28)*2!=b.size()-22)throw std::runtime_error("WMF framing");
 Layout l;int blits=0,maps=0;bool eof=false;size_t p=40;
 while(p<b.size()){need(b,p,6);DWORD words=u32(b,p);if(words<3||words>(b.size()-p)/2)throw std::runtime_error("WMF record bounds");WORD type=u16(b,p+4);
  if(type==META_SETMAPMODE){if(++maps!=1||words!=4||u16(b,p+6)!=MM_ANISOTROPIC)throw std::runtime_error("retained initial map");l.map=p;}
  if(type==META_STRETCHBLT){if(++blits!=1||words!=82||u32(b,p+6)!=SRCCOPY)throw std::runtime_error("retained blit framing");l.blit=p;
   const int expected[]={4,8,0,0,2,3,8,8};for(int i=0;i<8;i++)if(short(u16(b,p+10+i*2))!=expected[i])throw std::runtime_error("retained source/destination");
   size_t bm=p+26;if(u16(b,bm)!=0||u16(b,bm+2)!=8||u16(b,bm+4)!=4||u16(b,bm+6)!=32||b[bm+8]!=1||b[bm+9]!=32)throw std::runtime_error("retained Bitmap16");l.pixels=bm+10;need(b,l.pixels,128);
  }
  if(type==0){if(words!=3||p+6!=b.size())throw std::runtime_error("retained EOF");eof=true;}
  p+=size_t(words)*2;
 }
 if(p!=b.size()||blits!=1||maps!=1||!eof)throw std::runtime_error("retained record inventory");return l;
}
struct Variant{std::string name,change;Bytes bytes;};
static std::vector<Variant> variants(const Bytes& original){auto l=validate(original);std::vector<Variant> v;v.push_back({"baseline","byte-identical retained wire",original});
 for(int alpha:{0,255}){auto b=original;for(int pixel=0;pixel<32;pixel++)b[l.pixels+pixel*4+3]=BYTE(alpha);v.push_back({alpha?"alpha255-only":"alpha0-only","only Bitmap16 fourth-byte storage changes",b});}
 {auto b=original;set16(b,l.map+6,MM_TEXT);v.push_back({"initial-mm-text-only","only retained first map-mode value8 becomes1",b});}
 {auto b=original;auto prefix=record(META_SETMAPMODE,{MM_TEXT});b.insert(b.begin()+40,prefix.begin(),prefix.end());set32(b,28,DWORD((b.size()-22)/2));v.push_back({"prepend-mm-text-only","prepend MM_TEXT before retained MM_ANISOTROPIC; original records unchanged",b});}
 for(int mode=0;mode<4;mode++){
  auto b=original;Bytes prefix;auto append=[&](Bytes r){prefix.insert(prefix.end(),r.begin(),r.end());};
  append(record(META_SETMAPMODE,{MM_ANISOTROPIC}));append(record(META_SETWINDOWORG,{0,0}));append(record(META_SETWINDOWEXT,{H*(mode?4:1),W*(mode?4:1)}));append(record(META_SETVIEWPORTEXT,{H,W}));
  if(mode==1||mode==2)for(int i=4;i<8;i++)set16(b,l.blit+10+i*2,short(u16(b,l.blit+10+i*2))*4);
  if(mode==2)for(int i=0;i<4;i++)set16(b,l.blit+10+i*2,short(u16(b,l.blit+10+i*2))*4);
  b.insert(b.begin()+l.blit,prefix.begin(),prefix.end());set32(b,28,DWORD((b.size()-22)/2));
  const char* names[]={"identity-map-reassert","quarter-map-dst-only","quarter-map-src-and-dst","quarter-map-unscaled"};
  const char* changes[]={"insert explicit identity window+viewport before blit; original blit unchanged","insert1/4 mapping; multiply destination rectangle only by4","insert1/4 mapping; multiply source and destination rectangles by4; original Bitmap16 dimensions unchanged","insert1/4 mapping; original source and destination fields unchanged"};v.push_back({names[mode],changes[mode],b});
 }
 if(v.size()!=9)throw std::runtime_error("variant count");return v;
}
struct Capture{std::string json;bool baseline=false;};
static Bytes rgba(Bitmap& image,int& errors){UINT w=image.GetWidth(),h=image.GetHeight();Bytes b;errors=0;for(UINT y=0;y<h;y++)for(UINT x=0;x<w;x++){Color c;if(image.GetPixel(x,y,&c)!=Ok)errors++;b.insert(b.end(),{c.GetR(),c.GetG(),c.GetB(),c.GetA()});}return b;}
static Capture capture(const Variant& v,const fs::path& input,const fs::path& out){
 std::ostringstream o;o<<"{\"name\":\""<<v.name<<"\",\"change\":\""<<v.change<<"\",\"wireBytes\":"<<v.bytes.size();
 Bitmap diagnostic(input.c_str(),FALSE);Status constructor=diagnostic.GetLastStatus();Bitmap image(input.c_str(),FALSE);GUID format{};Status raw=image.GetRawFormat(&format),status=image.GetLastStatus();o<<",\"constructorDiagnosticStatus\":"<<constructor<<",\"rawFormatStatus\":"<<raw<<",\"loadStatusAfterRawFormat\":"<<status;
 bool baseline=false;
 if(status==Ok){UINT w=image.GetWidth(),h=image.GetHeight();o<<",\"width\":"<<w<<",\"height\":"<<h<<",\"rawFormatData1\":"<<format.Data1;if(w!=W||h!=H){o<<",\"captureSkipped\":\"intrinsic dimensions differ from retained control\"}";return{o.str(),false};}
  int intrinsicErrors=0,naturalErrors=0;auto intrinsic=rgba(image,intrinsicErrors);write(out/(v.name+"-intrinsic.rgba"),intrinsic);
  Bitmap canvas(W,H,PixelFormat32bppARGB);canvas.SetResolution(96,96);Status draw;{Graphics g(&canvas);g.Clear(Color(0,0,0,0));g.SetInterpolationMode(InterpolationModeDefault);g.SetPixelOffsetMode(PixelOffsetModeHighQuality);g.SetPixelOffsetMode(PixelOffsetModeHalf);ImageAttributes a;a.SetWrapMode(WrapModeTileFlipXY);draw=g.DrawImage(&image,Rect(0,0,W,H),0,0,W,H,UnitPixel,&a);}
  auto natural=rgba(canvas,naturalErrors);write(out/(v.name+"-picture.rgba"),natural);int differing=0,ink=0,minx=W,miny=H,maxx=-1,maxy=-1;
  for(int y=0;y<H;y++)for(int x=0;x<W;x++){int p=(y*W+x)*4;if(!std::equal(natural.begin()+p,natural.begin()+p+4,intrinsic.begin()+p))differing++;if(natural[p+3]&&(natural[p]!=70||natural[p+1]!=130||natural[p+2]!=80)){ink++;minx=std::min(minx,x);miny=std::min(miny,y);maxx=std::max(maxx,x);maxy=std::max(maxy,y);}}
  const int expected[6][3]={{19,25,20},{52,176,76},{83,62,131},{152,43,112},{184,194,168},{216,80,223}};baseline=draw==Ok&&intrinsicErrors==0&&naturalErrors==0;
  o<<",\"drawStatus\":"<<draw<<",\"intrinsicGetPixelErrors\":"<<intrinsicErrors<<",\"pictureGetPixelErrors\":"<<naturalErrors<<",\"intrinsicNaturalRGBAMismatches\":"<<differing<<",\"nonBackgroundInkPixels\":"<<ink<<",\"inkBounds\":["<<minx<<","<<miny<<","<<maxx<<","<<maxy<<"],\"originalSixRGBA\":[";
  for(int i=0;i<6;i++){if(i)o<<",";int p=((8+i/3)*W+8+i%3)*4;o<<"[";for(int k=0;k<4;k++){if(k)o<<",";o<<int(natural[p+k]);if(k<3&&natural[p+k]!=expected[i][k])baseline=false;}o<<"]";}o<<"]";
 }
 o<<"}";return{o.str(),baseline};
}
int main(int argc,char** argv){if(argc!=3)return 2;ULONG_PTR token;GdiplusStartupInput startup;if(GdiplusStartup(&token,&startup,nullptr)!=Ok)return 3;int result=0;
 try{auto original=read(fs::path(argv[1]));auto all=variants(original);fs::path out=argv[2];if(fs::exists(out)&&!fs::is_empty(out))throw std::runtime_error("output directory must be fresh");fs::create_directories(out);std::ofstream report(out/"wire-state-observations.json");report<<"{\"schema\":1,\"purpose\":\"isolate currently unknown Bitmap16 wire-state failure before any kernel inference\",\"requestedCaseCount\":9,\"consumer\":\"Bitmap(file,FALSE), GetRawFormat then GetLastStatus; intrinsic and natural transparent DrawImage default interpolation PixelOffsetHalf TileFlipXY; alpha unchanged\",\"cases\":[";
 bool first=true,positive=false;for(const auto& v:all){auto input=out/(v.name+".wmf");write(input,v.bytes);auto c=capture(v,input,out);if(!first)report<<",";first=false;report<<c.json;report.flush();if(v.name=="baseline"){positive=c.baseline;if(!positive)break;}}
 report<<"],\"positiveBaselineSixRGBPassed\":"<<(positive?"true":"false")<<"}";report.close();if(!positive)throw std::runtime_error("positive retained baseline failed; variants were not captured");uintmax_t bytes=0;for(auto& f:fs::directory_iterator(out))if(f.is_regular_file())bytes+=f.file_size();if(bytes>4*1024*1024)throw std::runtime_error("wire-state artifact budget");std::cout<<"Observed9 retained-wire variants; bytes="<<bytes<<"\n";
 }catch(const std::exception& e){std::cerr<<e.what()<<"\n";result=1;}GdiplusShutdown(token);return result;
}
