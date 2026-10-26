// Original synthetic EMF record playback measurement; no renderer code copied.
#include <windows.h>
#include <gdiplus.h>
#include <filesystem>
#include <fstream>
#include <vector>
#include <string>
#include <iostream>
#include <stdexcept>
using namespace Gdiplus;
namespace fs=std::filesystem;
static CLSID png;
struct Surface {
 HDC dc; HBITMAP bitmap; HGDIOBJ old; void* bits;
 Surface(){dc=CreateCompatibleDC(NULL);BITMAPINFO bi={};bi.bmiHeader.biSize=40;bi.bmiHeader.biWidth=96;bi.bmiHeader.biHeight=-64;bi.bmiHeader.biPlanes=1;bi.bmiHeader.biBitCount=32;bi.bmiHeader.biCompression=BI_RGB;bitmap=CreateDIBSection(dc,&bi,DIB_RGB_COLORS,&bits,NULL,0);if(!bitmap||!dc)throw std::runtime_error("DIB");old=SelectObject(dc,bitmap);PatBlt(dc,0,0,96,64,WHITENESS);}
 ~Surface(){SelectObject(dc,old);DeleteObject(bitmap);DeleteDC(dc);}
};
static void pixels(Bitmap&b,const fs::path&dir,const std::string&name,std::ostream&o){
 auto p=dir/(name+".png");Status status=b.Save(p.c_str(),&png,NULL);std::ofstream raw(dir/(name+".rgba"),std::ios::binary);int x0=96,y0=64,x1=-1,y1=-1,count=0;
 for(int y=0;y<64;y++)for(int x=0;x<96;x++){Color c;b.GetPixel(x,y,&c);unsigned char v[]={c.GetR(),c.GetG(),c.GetB(),255};raw.write((char*)v,4);if(v[0]!=255||v[1]!=255||v[2]!=255){x0=min(x0,x);y0=min(y0,y);x1=max(x1,x);y1=max(y1,y);count++;}}
 o<<"{\"png\":\""<<name<<".png\",\"saveStatus\":"<<status<<",\"nonwhitePixels\":"<<count<<",\"paintedBounds\":["<<x0<<","<<y0<<","<<x1<<","<<y1<<"]}";
}
static void surfacePixels(Surface&s,const fs::path&dir,const std::string&name,std::ostream&o){GdiFlush();Bitmap b(96,64,PixelFormat32bppARGB);for(int y=0;y<64;y++)for(int x=0;x<96;x++){auto p=((unsigned char*)s.bits)+(y*96+x)*4;b.SetPixel(x,y,Color(255,p[2],p[1],p[0]));}pixels(b,dir,name,o);}
struct EnumContext{std::ostream*o;bool first=true;};
static int CALLBACK record(HDC dc,HANDLETABLE*handles,const ENHMETARECORD*r,int n,LPARAM p){auto*c=(EnumContext*)p;SetLastError(0);BOOL ok=PlayEnhMetaFileRecord(dc,handles,r,n);DWORD error=GetLastError();if(r->iType==108||r->iType==96||r->iType==97||r->iType==83||r->iType==84){POINT pos={};GetCurrentPositionEx(dc,&pos);if(!c->first)*c->o<<",";c->first=false;*c->o<<"{\"type\":"<<r->iType<<",\"bytes\":"<<r->nSize<<",\"playRecord\":"<<(ok?"true":"false")<<",\"lastError\":"<<error<<",\"currentPosition\":["<<pos.x<<","<<pos.y<<"]}";}return 1;}
static void replay(const fs::path&input,const fs::path&dir,std::ostream&o,bool first){if(!first)o<<",";auto name=input.stem().string();o<<"{\"name\":\""<<name<<"\",\"emf\":\""<<input.filename().string()<<"\"";fs::copy_file(input,dir/input.filename(),fs::copy_options::overwrite_existing);
 HENHMETAFILE emf=GetEnhMetaFileW(input.c_str());o<<",\"getEnhMetaFile\":"<<(emf?"true":"false");if(emf){RECT dest={0,0,96,64};Surface s;SetLastError(0);BOOL ok=PlayEnhMetaFile(s.dc,emf,&dest);DWORD error=GetLastError();o<<",\"playEnhMetaFile\":"<<(ok?"true":"false")<<",\"playLastError\":"<<error<<",\"gdi\":";surfacePixels(s,dir,name+"-gdi",o);Surface e;EnumContext context{&o};o<<",\"records\":[";BOOL enumerated=EnumEnhMetaFile(e.dc,emf,record,&context,&dest);o<<"],\"enumEnhMetaFile\":"<<(enumerated?"true":"false")<<",\"enumerated\":";surfacePixels(e,dir,name+"-enum",o);DeleteEnhMetaFile(emf);}
 Metafile image(input.c_str());Status loaded=image.GetLastStatus();o<<",\"gdiplusLoadStatus\":"<<loaded;if(loaded==Ok){Bitmap b(96,64,PixelFormat32bppARGB);b.SetResolution(96,96);Status draw;{Graphics g(&b);g.Clear(Color::White);g.SetPageUnit(UnitPixel);draw=g.DrawImage(&image,Rect(0,0,96,64));}o<<",\"gdiplusDrawStatus\":"<<draw<<",\"gdiplus\":";pixels(b,dir,name+"-plus",o);}o<<"}";}
static void native(const fs::path&dir,std::ostream&o){Surface s;RECT frame={0,0,2540,1693};auto path=dir/L"native-poly-wide.emf";HDC dc=CreateEnhMetaFileW(s.dc,path.c_str(),&frame,L"Compact text oracle\0Native PolyTextOutW\0\0");HFONT font=CreateFontW(-18,0,0,0,400,0,0,0,DEFAULT_CHARSET,0,0,0,0,L"Arial");auto old=SelectObject(dc,font);SetTextAlign(dc,TA_BASELINE);SetBkMode(dc,TRANSPARENT);POLYTEXTW p[2]={};p[0].x=8;p[0].y=28;p[0].n=2;p[0].lpstr=L"HH";p[1].x=60;p[1].y=52;p[1].n=1;p[1].lpstr=L"H";SetLastError(0);BOOL result=PolyTextOutW(dc,p,2);DWORD error=GetLastError();SelectObject(dc,old);DeleteObject(font);auto emf=CloseEnhMetaFile(dc);if(emf)DeleteEnhMetaFile(emf);o<<"{\"polyTextOutW\":"<<(result?"true":"false")<<",\"lastError\":"<<error<<",\"file\":\"native-poly-wide.emf\"}";}
int main(int argc,char**argv){if(argc!=3)return 2;ULONG_PTR token;GdiplusStartupInput init;if(GdiplusStartup(&token,&init,NULL)!=Ok)return 3;int code=0;try{UINT count,size;GetImageEncodersSize(&count,&size);std::vector<BYTE>buf(size);GetImageEncoders(count,size,(ImageCodecInfo*)buf.data());bool found=false;for(UINT i=0;i<count;i++){auto&e=((ImageCodecInfo*)buf.data())[i];if(wcscmp(e.MimeType,L"image/png")==0){png=e.Clsid;found=true;}}if(!found)throw std::runtime_error("PNG encoder");fs::path input=argv[1],output=argv[2];fs::create_directories(output);std::ofstream o(output/"compact-text.json");o<<"{\"schema\":1,\"width\":96,\"height\":64,\"rgba\":\"straight RGBA top-left opaque white background\",\"nativeAPI\":";native(output,o);o<<",\"cases\":[";bool first=true;for(auto&e:fs::directory_iterator(input)){if(e.path().extension()==L".emf"){replay(e.path(),output,o,first);first=false;}}o<<"]}";if(!o)throw std::runtime_error("JSON write");}catch(const std::exception&e){std::cerr<<e.what()<<"\n";code=1;}GdiplusShutdown(token);return code;}
