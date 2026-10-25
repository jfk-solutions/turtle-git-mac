// Original synthetic Windows GDI+ reference assay; no renderer implementation.
#include <windows.h>
#include <gdiplus.h>
#include <fstream>
#include <iostream>
#include <sstream>
#include <iomanip>
#include <vector>
#include <string>
#include <memory>
using namespace Gdiplus;
static CLSID pngEncoder;
static std::ofstream report;
static bool firstCase=true;
static std::wstring wide(const std::string& s){return std::wstring(s.begin(),s.end());}
static void status(Status s,const char* where){if(s!=Ok)throw std::string(where)+" status="+std::to_string((int)s);}
static void startCase(const std::string& name,const char* source){if(!firstCase)report<<",";firstCase=false;report<<"{\"file\":\""<<name<<"\",\"source\":\""<<source<<"\"";}
static void pixels(Bitmap& b,const std::string& output,const std::string& name){
 std::string stem=name.substr(0,name.find_last_of('.'));
 status(b.Save(wide(output+"/"+stem+".png").c_str(),&pngEncoder,NULL),"Save PNG");
 std::ofstream raw(output+"/"+stem+".rgba",std::ios::binary);
 int positions[]={0,4,8,12,16,20,24,28,32,36,40,44,48,52,56,60,63};
 report<<",\"samples\":[";bool first=true;
 for(int y=0;y<64;y++)for(int x=0;x<64;x++){Color c;status(b.GetPixel(x,y,&c),"GetPixel");unsigned char bytes[]={c.GetR(),c.GetG(),c.GetB(),c.GetA()};raw.write((char*)bytes,4);}
 for(int y:positions)for(int x:positions){Color c;status(b.GetPixel(x,y,&c),"GetPixel sample");if(!first)report<<",";first=false;report<<"{\"x\":"<<x<<",\"y\":"<<y<<",\"rgba\":["<<(int)c.GetR()<<","<<(int)c.GetG()<<","<<(int)c.GetB()<<","<<(int)c.GetA()<<"],\"tolerance\":3}";}
 report<<"],\"rgbaFile\":\""<<stem<<".rgba\",\"png\":\""<<stem<<".png\"";
}
static void error(const std::string& e){report<<",\"error\":\"";for(char c:e)report<<(c=='"'||c=='\\'?' ':c);report<<"\"";}
static void playback(const std::string& path,const std::string& output,const std::string& name,const char* source){
 startCase(name,source);try{Metafile image(wide(path).c_str());status(image.GetLastStatus(),"Load metafile");RectF bounds;Unit unit;status(image.GetBounds(&bounds,&unit),"Bounds");report<<",\"imageSize\":["<<image.GetWidth()<<","<<image.GetHeight()<<"],\"dpi\":["<<image.GetHorizontalResolution()<<","<<image.GetVerticalResolution()<<"],\"bounds\":["<<bounds.X<<","<<bounds.Y<<","<<bounds.Width<<","<<bounds.Height<<"],\"boundsUnit\":"<<(int)unit;Bitmap b(64,64,PixelFormat32bppARGB);status(b.SetResolution(96,96),"DPI");{Graphics g(&b);status(g.Clear(Color(0,0,0,0)),"Clear");status(g.SetPageUnit(UnitPixel),"Page unit");status(g.DrawImage(&image,Rect(0,0,64,64),0,0,64,64,UnitPixel),"Draw metafile");}pixels(b,output,name);}catch(const std::string& e){error(e);}report<<"}";
}
struct Spec{std::string name;int shape=0;PointF center=PointF(32.5f,32.5f);REAL fx=0,fy=0;bool focus=false,gamma=false,alpha=false;int colors=1,wrap=4,blend=0;bool points=false;};
static std::vector<PointF> points(int shape){if(shape==1)return {{8.5f,8.5f},{56.5f,8.5f},{32.5f,56.5f}};if(shape==2)return {{8.5f,8.5f},{56.5f,8.5f},{56.5f,24.5f},{24.5f,24.5f},{24.5f,56.5f},{8.5f,56.5f}};return {{8.5f,8.5f},{56.5f,8.5f},{56.5f,56.5f},{8.5f,56.5f}};}
static std::unique_ptr<PathGradientBrush> brush(const Spec& s){auto p=points(s.shape);GraphicsPath path;status(path.AddPolygon(p.data(),(INT)p.size()),"AddPolygon");std::unique_ptr<PathGradientBrush>b(s.points?new PathGradientBrush(p.data(),(INT)p.size(),(WrapMode)s.wrap):new PathGradientBrush(&path));status(b->GetLastStatus(),"Construct");status(b->SetWrapMode((WrapMode)s.wrap),"Wrap");status(b->SetCenterPoint(s.center),"Center");status(b->SetCenterColor(s.alpha?Color(128,255,0,0):Color(255,255,0,0)),"Center color");std::vector<Color>c;if(s.colors==1)c={s.alpha?Color(64,0,0,255):Color(255,0,0,255)};else{Color all[]={Color(255,255,0,0),Color(255,0,255,0),Color(255,0,0,255),Color(255,255,255,255),Color(255,255,0,255),Color(255,0,255,255)};for(int i=0;i<s.colors;i++)c.push_back(all[i]);}INT count=(INT)c.size();status(b->SetSurroundColors(c.data(),&count),"Surround");if(s.focus)status(b->SetFocusScales(s.fx,s.fy),"Focus");status(b->SetGammaCorrection(s.gamma),"Gamma");if(s.blend==1){REAL factors[]={0,0,1,1},pos[]={0,.25f,.75f,1};status(b->SetBlend(factors,pos,4),"Blend");}if(s.blend==2){Color colors[]={Color(255,0,0,255),Color(255,0,0,255),Color(255,255,0,0),Color(255,255,0,0)};REAL pos[]={0,.25f,.75f,1};status(b->SetInterpolationColors(colors,pos,4),"Preset");}return b;}
static void control(const Spec& s,const std::string& output){
 std::string name="native-control-"+s.name+".emf";startCase(name,"native-constructor");
 try{auto b=brush(s);Bitmap image(64,64,PixelFormat32bppARGB);status(image.SetResolution(96,96),"DPI");{Graphics g(&image);status(g.Clear(Color(0,0,0,0)),"Clear");status(g.SetPageUnit(UnitPixel),"Page unit");status(g.FillRectangle(b.get(),RectF(0,0,64,64)),"Fill");}PointF center;REAL fx,fy;status(b->GetCenterPoint(&center),"Read center");status(b->GetFocusScales(&fx,&fy),"Read focus");report<<",\"center\":["<<center.X<<","<<center.Y<<"],\"focus\":["<<fx<<","<<fy<<"],\"surroundCount\":"<<b->GetSurroundColorCount()<<",\"gamma\":"<<(b->GetGammaCorrection()?"true":"false");pixels(image,output,name);
  std::string recorded=output+"/"+name;Bitmap reference(64,64);Graphics rg(&reference);HDC hdc=rg.GetHDC();{Metafile emf(wide(recorded).c_str(),hdc,RectF(0,0,64,64),MetafileFrameUnitPixel,EmfTypeEmfPlusOnly);status(emf.GetLastStatus(),"Create recorded metafile");Graphics g(&emf);status(g.SetPageUnit(UnitPixel),"Recorder page");status(g.Clear(Color(0,0,0,0)),"Recorder clear");status(g.FillRectangle(b.get(),RectF(0,0,64,64)),"Record fill");}rg.ReleaseHDC(hdc);
 }catch(const std::string&e){error(e);}report<<"}";
 std::ifstream recorded(output+"/"+name,std::ios::binary);if(recorded.good())playback(output+"/"+name,output,"replay-"+name,"native-recorded-replay");
}
static void linearControl(int variant,const std::string& output){
 bool gamma=(variant%2)!=0;int kind=variant/2;
 Color begin=kind==2?Color(255,0,0,0):(kind==1?Color(128,255,0,0):Color(255,255,0,0));
 Color end=kind==2?Color(255,255,255,255):(kind==1?Color(64,0,0,255):Color(255,0,0,255));
 std::string name="native-linear-"+std::to_string(variant)+".emf";
 startCase(name,"native-linear-constructor");
 try{LinearGradientBrush brush(PointF(8.5f,32.5f),PointF(56.5f,32.5f),begin,end);status(brush.GetLastStatus(),"Linear constructor");status(brush.SetGammaCorrection(gamma),"Linear gamma");status(brush.SetWrapMode(WrapModeTile),"Linear wrap");
 Bitmap image(64,64,PixelFormat32bppARGB);status(image.SetResolution(96,96),"DPI");{Graphics g(&image);status(g.Clear(Color(0,0,0,0)),"Clear");status(g.SetPageUnit(UnitPixel),"Unit");status(g.FillRectangle(&brush,RectF(0,0,64,64)),"Linear fill");}pixels(image,output,name);
 Bitmap reference(64,64);Graphics rg(&reference);HDC hdc=rg.GetHDC();{Metafile emf(wide(output+"/"+name).c_str(),hdc,RectF(0,0,64,64),MetafileFrameUnitPixel,EmfTypeEmfPlusOnly);status(emf.GetLastStatus(),"Linear record");Graphics g(&emf);status(g.SetPageUnit(UnitPixel),"Linear record unit");status(g.Clear(Color(0,0,0,0)),"Clear record");status(g.FillRectangle(&brush,RectF(0,0,64,64)),"Linear record fill");}rg.ReleaseHDC(hdc);
 }catch(const std::string&e){error(e);}report<<"}";
 std::ifstream file(output+"/"+name,std::ios::binary);if(file.good())playback(output+"/"+name,output,"replay-"+name,"native-linear-recorded-replay");
}
int main(int argc,char**argv){if(argc!=3&&argc!=4)return 2;ULONG_PTR token;GdiplusStartupInput input;if(GdiplusStartup(&token,&input,NULL)!=Ok)return 3;UINT count,size;GetImageEncodersSize(&count,&size);std::vector<BYTE>storage(size);auto enc=(ImageCodecInfo*)storage.data();GetImageEncoders(count,size,enc);for(UINT i=0;i<count;i++)if(wcscmp(enc[i].MimeType,L"image/png")==0)pngEncoder=enc[i].Clsid;CreateDirectoryW(wide(argv[2]).c_str(),NULL);report.open(std::string(argv[2])+"/samples.json");report<<"{\"format\":\"straightRGBA, top-left, 64x64 96dpi; raw files row-major RGBA\",\"cases\":[";
 WIN32_FIND_DATAW data;HANDLE search=FindFirstFileW(wide(std::string(argv[1])+"/path-gradient-*.emf").c_str(),&data);int files=0;if(search!=INVALID_HANDLE_VALUE){do{std::string name;for(wchar_t*p=data.cFileName;*p;p++)name.push_back((char)*p);if(name.find("refused-")!=std::string::npos || (argc==4 && name.find(argv[3])==std::string::npos))continue;playback(std::string(argv[1])+"/"+name,argv[2],name,"authored-wire");files++;}while(FindNextFileW(search,&data));FindClose(search);}
 std::vector<Spec> specs;Spec s;s.name="square";specs.push_back(s);s.name="point-constructor";s.points=true;specs.push_back(s);s.points=false;s.name="offcenter";s.center=PointF(20.5f,24.5f);specs.push_back(s);s.name="offcenter-focus";s.focus=true;s.fx=.3f;s.fy=.7f;specs.push_back(s);s=Spec();s.name="triangle-offcenter-focus";s.shape=1;s.center=PointF(24.5f,20.5f);s.focus=true;s.fx=.3f;s.fy=.7f;specs.push_back(s);s=Spec();s.name="triangle-multicolor";s.shape=1;s.center=PointF(32.5f,24.5f);s.colors=3;specs.push_back(s);s=Spec();s.name="quad-multicolor";s.colors=4;specs.push_back(s);s.name="quad-preset-multicolor";s.blend=2;specs.push_back(s);s=Spec();s.name="surround-two";s.colors=2;specs.push_back(s);s=Spec();s.shape=2;s.colors=6;s.center=PointF(16.5f,16.5f);s.name="concave-kernel";specs.push_back(s);s.center=PointF(40.5f,16.5f);s.name="concave-outside-kernel";specs.push_back(s);s=Spec();s.center=PointF(64.5f,32.5f);s.name="outside-center";specs.push_back(s);
 for(int i=0;i<5;i++){s=Spec();s.wrap=i;s.name="wrap-"+std::to_string(i);specs.push_back(s);}for(int i=0;i<3;i++){s=Spec();s.focus=true;s.fx=i==0?0:(i==1?.3f:1);s.fy=i==0?0:(i==1?.7f:1);s.name="focus-"+std::to_string(i);specs.push_back(s);}for(int i=0;i<4;i++){s=Spec();s.gamma=(i&1)!=0;s.alpha=(i&2)!=0;s.name="gamma-alpha-"+std::to_string(i);specs.push_back(s);}for(int i=1;i<3;i++){s=Spec();s.blend=i;s.name="blend-"+std::to_string(i);specs.push_back(s);}if(argc==3)for(const Spec& spec:specs)control(spec,argv[2]);if(argc==4)for(int i=0;i<6;i++)linearControl(i,argv[2]);report<<"]}";report.close();std::cout<<"AUTHORED_WIRE_CASES "<<files<<" NATIVE_CONTROLS "<<(argc==3?specs.size():0)<<std::endl;GdiplusShutdown(token);return files?0:4;}
