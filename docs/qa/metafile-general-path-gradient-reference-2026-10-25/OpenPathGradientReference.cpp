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

int main(int argc,char**argv){if(argc!=3)return 2;ULONG_PTR token;GdiplusStartupInput in;if(GdiplusStartup(&token,&in,NULL)!=Ok)return 3;UINT n,size;GetImageEncodersSize(&n,&size);std::vector<BYTE>bytes(size);auto enc=(ImageCodecInfo*)bytes.data();GetImageEncoders(n,size,enc);for(UINT i=0;i<n;i++)if(wcscmp(enc[i].MimeType,L"image/png")==0)pngEncoder=enc[i].Clsid;CreateDirectoryW(wide(argv[2]).c_str(),NULL);report.open(std::string(argv[2])+"/samples.json");report<<"{\"format\":\"straightRGBA top-left64x64, open versus closed cubic boundary after original red paint\",\"cases\":[";const char*names[]={"open-cubic-after-paint.emf","closed-cubic-after-paint.emf"};for(auto name:names)playback(std::string(argv[1])+"/"+name,argv[2],name,"single-closebit-open-profile");report<<"]}";report.close();GdiplusShutdown(token);return 0;}
