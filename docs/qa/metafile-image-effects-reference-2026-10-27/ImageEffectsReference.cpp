// Original bounded Windows GDI+ assay. Pixels are observations, not renderer expectations.
#define GDIPVER 0x0110
#include <windows.h>
#include <gdiplus.h>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <vector>
#include <string>
#include <memory>
#include <stdexcept>
using namespace Gdiplus;
namespace fs=std::filesystem;
static CLSID png;
static std::ofstream report;
static bool first=true;
static void check(Status s,const char* op){if(s!=Ok)throw std::runtime_error(std::string(op)+":"+std::to_string(s));}
static void entry(const std::string& name){if(!first)report<<",";first=false;report<<"{\"name\":\""<<name<<"\"";}
static void pixels(Bitmap& b,const fs::path& dir,const std::string& name){
 check(b.Save((dir/(name+".png")).c_str(),&png,nullptr),"PNG");
 std::ofstream raw(dir/(name+".rgba"),std::ios::binary);
 for(UINT y=0;y<b.GetHeight();++y)for(UINT x=0;x<b.GetWidth();++x){Color c;check(b.GetPixel(x,y,&c),"pixel");BYTE p[]={c.GetR(),c.GetG(),c.GetB(),c.GetA()};raw.write((char*)p,4);}
 report<<",\"width\":"<<b.GetWidth()<<",\"height\":"<<b.GetHeight()<<",\"rgba\":\""<<name<<".rgba\",\"png\":\""<<name<<".png\"";
}
static std::unique_ptr<Bitmap> ramp(){auto b=std::make_unique<Bitmap>(256,4,PixelFormat32bppARGB);check(b->SetResolution(96,96),"DPI");for(int x=0;x<256;++x){check(b->SetPixel(x,0,Color(255,x,x,x)),"ramp");check(b->SetPixel(x,1,Color(255,x,255-x,(x*37)&255)),"rgb");check(b->SetPixel(x,2,Color(x,70,140,210)),"alpha");check(b->SetPixel(x,3,Color(0,x,255-x,100)),"zeroalpha");}return b;}
static Status fx(Graphics& g,Image& image,Effect* effect,int y,ImageAttributes* attrs=nullptr){RectF src(0,0,256,4);Matrix m(1,0,0,1,0,(REAL)y);return g.DrawImage(&image,&src,&m,effect,attrs,UnitPixel);}
static void direct(const fs::path& dir,const std::string& name,Effect& effect){entry(name);try{auto b=ramp();effect.UseAuxData(TRUE);Status s=b->ApplyEffect(&effect,nullptr);report<<",\"applyStatus\":"<<s<<",\"auxBytes\":"<<effect.GetAuxDataSize();if(effect.GetAuxData()&&effect.GetAuxDataSize()>0){std::ofstream aux(dir/(name+".lut"),std::ios::binary);aux.write((char*)effect.GetAuxData(),effect.GetAuxDataSize());}if(s==Ok)pixels(*b,dir,name);}catch(const std::exception&e){report<<",\"error\":\""<<e.what()<<"\"";}report<<"}";}
static ColorMatrix matrix(){ColorMatrix m={};m.m[0][2]=1;m.m[1][0]=.5f;m.m[2][1]=1;m.m[3][3]=.75f;m.m[4][0]=.125f;m.m[4][4]=1;return m;}
static ColorLUTParams lut(){ColorLUTParams p={};for(int i=0;i<256;i++){p.lutB[i]=(BYTE)(255-i);p.lutG[i]=(BYTE)(i/2);p.lutR[i]=(BYTE)((i+63)&255);p.lutA[i]=(BYTE)(255-i);}return p;}
static void generate(const fs::path& dir){
 ColorMatrix m=matrix();ColorMatrixEffect a;check(a.SetParameters(&m),"matrix");direct(dir,"matrix-channel-alpha-bias",a);
 auto lp=lut();ColorLUT b;check(b.SetParameters(&lp),"lut");direct(dir,"lut-channel-alpha",b);
 // All 256 source levels for endpoints and interior positive/negative brightness/contrast.
 const int bs[]={-255,-128,-30,-1,0,1,30,128,255};const int cs[]={-100,-75,-25,-1,0,1,25,75,100};
 for(int brightness:bs)for(int contrast:cs){BrightnessContrastParams p={brightness,contrast};BrightnessContrast e;check(e.SetParameters(&p),"brightness parameters");direct(dir,"bc-b"+std::to_string(brightness)+"-c"+std::to_string(contrast),e);}
 auto source=ramp();HDC dc=GetDC(nullptr);{
  Metafile file((dir/L"state-seed.emf").c_str(),dc,RectF(0,0,256,64),MetafileFrameUnitPixel,EmfTypeEmfPlusOnly,L"TurtleGit independent effect reference");check(file.GetLastStatus(),"metafile");Graphics g(&file);check(g.SetPageUnit(UnitPixel),"unit");check(g.SetCompositingMode(CompositingModeSourceCopy),"source copy");
  entry("state-seed-recording");report<<",\"drawStatuses\":[";
  auto draw=[&](Effect* e,int y,bool comma=true){if(comma)report<<",";report<<fx(g,*source,e,y);};
  draw(&a,0,false);report<<","<<g.DrawImage(source.get(),0,8,256,4);
  GraphicsState state=g.Save();draw(&b,16);check(g.Restore(state),"restore");draw(&a,24);
  GraphicsContainer container=g.BeginContainer();draw(&b,32);check(g.EndContainer(container),"container");draw(&a,40);
  ImageAttributes attrs;ColorMatrix attr={};for(int i=0;i<5;i++)attr.m[i][i]=1;attr.m[4][1]=.2f;check(attrs.SetColorMatrix(&attr),"attributes");report<<","<<fx(g,*source,&a,48,&attrs);
  check(g.SetClip(Rect(64,56,96,4)),"clip");draw(&a,56);report<<"]}";
 }ReleaseDC(nullptr,dc);
}
static void replay(const fs::path& path,const fs::path& dir){std::string name="replay-"+path.stem().string();entry(name);try{Bitmap image(path.c_str(),FALSE);Status load=image.GetLastStatus();report<<",\"bitmapLoadStatus\":"<<load<<",\"intrinsicWidth\":"<<image.GetWidth()<<",\"intrinsicHeight\":"<<image.GetHeight();Bitmap output(256,64,PixelFormat32bppARGB);check(output.SetResolution(96,96),"DPI");Status draw;{Graphics g(&output);check(g.Clear(Color(0,0,0,0)),"clear");check(g.SetCompositingMode(CompositingModeSourceCopy),"sourcecopy");draw=g.DrawImage(&image,Rect(0,0,256,64),0,0,256,64,UnitPixel);}report<<",\"drawStatus\":"<<draw;if(load==Ok&&draw==Ok)pixels(output,dir,name);}catch(const std::exception&e){report<<",\"error\":\""<<e.what()<<"\"";}report<<"}";}
int main(int argc,char**argv){if(argc!=3)return 2;try{GdiplusStartupInput input;input.GdiplusVersion=2;ULONG_PTR token;check(GdiplusStartup(&token,&input,nullptr),"startup");{UINT n,size;check(GetImageEncodersSize(&n,&size),"encoders");std::vector<BYTE>buf(size);auto codecs=(ImageCodecInfo*)buf.data();check(GetImageEncoders(n,size,codecs),"encoders");for(UINT i=0;i<n;++i)if(wcscmp(codecs[i].MimeType,L"image/png")==0)png=codecs[i].Clsid;
 fs::path dir=fs::absolute(argv[2]);fs::create_directories(dir);std::string mode=argv[1];report.open(dir/(mode+".json"));report<<"{\"platform\":\"native Windows GDI+ v2\",\"format\":\"straight RGBA row-major top-left; direct ramp 256x4; replay 256x64\",\"cases\":[";if(mode=="generate")generate(dir);else if(mode=="replay"){for(auto& p:fs::directory_iterator(dir))if(p.path().extension()==L".emf")replay(p.path(),dir);}else return 2;report<<"]}";report.close();}GdiplusShutdown(token);return 0;}catch(const std::exception&e){std::cerr<<e.what()<<"\n";return 1;}}
