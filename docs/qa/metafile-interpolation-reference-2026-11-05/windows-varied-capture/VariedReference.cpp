// SPDX-License-Identifier: MIT
// Independent Windows GDI+ interpolation and device-pixel phase observations.
#define NOMINMAX
#include <windows.h>
#include <gdiplus.h>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <vector>
#include <string>
#include <stdexcept>
#include <iomanip>
using namespace Gdiplus;
namespace fs=std::filesystem;
constexpr int W=32,H=24;
using Bytes=std::vector<BYTE>;
static void ok(Status s,const char* what){if(s!=Ok)throw std::runtime_error(std::string(what)+" status="+std::to_string(s));}
static void write(const fs::path& p,const Bytes& b){std::ofstream f(p,std::ios::binary);f.write((const char*)b.data(),b.size());if(!f)throw std::runtime_error("write");}
static Bytes pixels(Bitmap& b){Bytes out;for(int y=0;y<H;y++)for(int x=0;x<W;x++){Color c;ok(b.GetPixel(x,y,&c),"GetPixel");out.insert(out.end(),{c.GetR(),c.GetG(),c.GetB(),c.GetA()});}return out;}
struct Case {int mode,pixel;bool alpha;std::string scene,name;};
static void scene(Graphics& g,const Case& c,std::ostream* state){
 ok(g.Clear(Color(0,0,0,0)),"Clear");ok(g.SetPageUnit(UnitPixel),"page");ok(g.SetPageScale(1),"scale");
 ok(g.SetCompositingMode(CompositingModeSourceCopy),"SourceCopy");
 ok(g.SetPixelOffsetMode((PixelOffsetMode)c.pixel),"pixel offset");ok(g.SetInterpolationMode((InterpolationMode)c.mode),"interpolation");
 if(state)*state<<"{\"interpolation\":"<<int(g.GetInterpolationMode())<<",\"pixelOffset\":"<<int(g.GetPixelOffsetMode());
 Bitmap atlas(2,2,PixelFormat32bppARGB);ok(atlas.SetResolution(96,96),"atlas DPI");
 const BYTE alpha[]={248,127,7,64};const BYTE rgb[][3]={{70,140,210},{37,91,143},{197,63,121},{254,195,83}};
 for(int y=0;y<2;y++)for(int x=0;x<2;x++){int i=y*2+x;ok(atlas.SetPixel(x,y,Color(c.alpha?alpha[i]:255,rgb[i][0],rgb[i][1],rgb[i][2])),"atlas pixel");}
 if(state){*state<<",\"sourceRGBA\":[";for(int y=0;y<2;y++)for(int x=0;x<2;x++){Color v;ok(atlas.GetPixel(x,y,&v),"source GetPixel");if(x||y)*state<<",";*state<<"["<<int(v.GetR())<<","<<int(v.GetG())<<","<<int(v.GetB())<<","<<int(v.GetA())<<"]";}*state<<"]}";}
 float dx=4,dy=4,sx=0,sy=0,sw=2,sh=2;
 if(c.scene=="quarter"){dx+=.25f;dy+=.25f;}
 if(c.scene=="half"){dx+=.5f;dy+=.5f;}
 if(c.scene=="three-quarter"){dx+=.75f;dy+=.75f;}
 if(c.scene=="negative"){dx=-1.25f;dy=-.5f;}
 if(c.scene=="reflection"){Matrix m(-1,0,0,1,20,0);ok(g.SetTransform(&m),"reflection");}
 if(c.scene=="affine"){Matrix m(1,.25f,.25f,1,0,0);ok(g.SetTransform(&m),"affine");}
 if(c.scene=="crop"){sx=.25f;sy=.25f;sw=1.5f;sh=1.5f;}
 ok(g.DrawImage(&atlas,RectF(dx,dy,8,8),sx,sy,sw,sh,UnitPixel),"DrawImage");
}
static Bytes replay(const fs::path& path,bool picture){
 Bitmap canvas(W,H,PixelFormat32bppARGB);ok(canvas.SetResolution(96,96),"replay DPI");
 {Graphics g(&canvas);ok(g.Clear(Color(0,0,0,0)),"replay Clear");ok(g.SetPageUnit(UnitPixel),"replay UnitPixel");ok(g.SetCompositingMode(CompositingModeSourceCopy),"replay SourceCopy");
  if(picture){Bitmap image(path.c_str(),FALSE);GUID format{};ok(image.GetRawFormat(&format),"Picture raw format");ok(image.GetLastStatus(),"Picture load after format");ok(g.SetInterpolationMode(InterpolationModeDefault),"Picture interpolation");ok(g.SetPixelOffsetMode(PixelOffsetModeHalf),"Picture offset");ImageAttributes attrs;ok(attrs.SetWrapMode(WrapModeTileFlipXY),"Picture wrap");ok(g.DrawImage(&image,Rect(0,0,W,H),0,0,W,H,UnitPixel,&attrs),"Picture draw");}
  else {Metafile image(path.c_str());ok(image.GetLastStatus(),"Metafile load");ok(g.DrawImage(&image,Rect(0,0,W,H),0,0,W,H,UnitPixel),"natural draw");}
 }return pixels(canvas);
}
static WORD u16(const Bytes& b,size_t p){if(p+2>b.size())throw std::runtime_error("wire bounds");return b[p]|WORD(b[p+1])<<8;}
static DWORD u32(const Bytes& b,size_t p){return u16(b,p)|DWORD(u16(b,p+2))<<16;}
static void records(const fs::path& file,const fs::path& output){
 std::ifstream input(file,std::ios::binary);Bytes b((std::istreambuf_iterator<char>(input)),{});std::ofstream o(output);o<<"[";bool first=true;
 for(size_t p=0;p+8<=b.size();){DWORD type=u32(b,p),size=u32(b,p+4);if(size<8||size>b.size()-p)throw std::runtime_error("EMF size");
  if(type==70&&size>=16&&u32(b,p+12)==0x2b464d45){size_t n=u32(b,p+8);if(n>size-12)throw std::runtime_error("comment size");for(size_t q=p+16;q+12<=p+12+n;){DWORD count=u32(b,q+4),data=u32(b,q+8);if(count<12||count>p+12+n-q||data>count-12)throw std::runtime_error("plus size");if(!first)o<<",";first=false;o<<"{\"type\":"<<u16(b,q)<<",\"flags\":"<<u16(b,q+2)<<",\"size\":"<<count<<",\"dataSize\":"<<data<<",\"bodyHex\":\"";for(size_t k=q+12;k<q+12+data;k++)o<<std::hex<<std::setw(2)<<std::setfill('0')<<unsigned(b[k]);o<<std::dec<<"\"}";q+=count;}}
  p+=size;
 }o<<"]";
}
int wmain(int argc,wchar_t** argv){
 try {if(argc!=2)throw std::runtime_error("one output directory required");GdiplusStartupInput startup;ULONG_PTR token=0;ok(GdiplusStartup(&token,&startup,nullptr),"startup");
 {fs::path out(argv[1]);fs::create_directories(out);std::ofstream report(out/"interpolation-observations.json");report<<"{\"schema\":1,\"width\":"<<W<<",\"height\":"<<H<<",\"dpi\":96,\"sourcePixels\":\"2x2 varied RGBA; exact requested and native source values retained in each case\",\"destination\":[4,4,8,8],\"sourceRect\":[0,0,2,2],\"cases\":[";bool first=true;int count=0;
 for(bool alpha:{true})for(int mode:{0,5})for(int pixel:{0,4})for(const char* name:{"integer","quarter","half","three-quarter","negative","reflection","affine","crop"}){
  Case c{mode,pixel,alpha,name,std::string("varied")+"-i"+std::to_string(mode)+"-p"+std::to_string(pixel)+"-"+name};if(!first)report<<",";first=false;report<<"{\"name\":\""<<c.name<<"\",\"mode\":"<<mode<<",\"pixelOffset\":"<<pixel<<",\"alpha\":"<<(alpha?"true":"false")<<",\"scene\":\""<<name<<"\",\"directState\":";
  Bitmap direct(W,H,PixelFormat32bppARGB);ok(direct.SetResolution(96,96),"direct DPI");{Graphics g(&direct);scene(g,c,&report);}write(out/(c.name+"-direct.rgba"),pixels(direct));
  fs::path emf=out/(c.name+".emf");Bitmap reference(W,H,PixelFormat32bppARGB);ok(reference.SetResolution(96,96),"reference DPI");Graphics referenceGraphics(&reference);HDC hdc=referenceGraphics.GetHDC();if(!hdc)throw std::runtime_error("reference HDC");try{{Metafile recording(emf.c_str(),hdc,RectF(0,0,W,H),MetafileFrameUnitPixel,EmfTypeEmfPlusOnly,L"Independent interpolation phase");ok(recording.GetLastStatus(),"recording");{Graphics g(&recording);report<<",\"recordedState\":";scene(g,c,&report);}}}catch(...){referenceGraphics.ReleaseHDC(hdc);throw;}referenceGraphics.ReleaseHDC(hdc);ok(referenceGraphics.GetLastStatus(),"release reference HDC");
  records(emf,out/(c.name+"-records.json"));write(out/(c.name+"-natural.rgba"),replay(emf,false));write(out/(c.name+"-picture.rgba"),replay(emf,true));report<<"}";report.flush();count++;
 }report<<"],\"completedCaseCount\":"<<count<<"}";std::cout<<"Captured "<<count<<" native interpolation cases\n";}
 GdiplusShutdown(token);return 0;
 }catch(const std::exception& e){std::cerr<<e.what()<<"\n";return 1;}
}
