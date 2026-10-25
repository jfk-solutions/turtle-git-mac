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

struct GeneralSpec {const char* name;int shape;bool multi=false;int use=0;};
static std::unique_ptr<GraphicsPath> geometry(int shape){
 auto path=std::make_unique<GraphicsPath>(FillModeAlternate);
 if(shape==0){status(path->AddBezier(8.5f,32.5f,8.5f,0.5f,56.5f,8.5f,56.5f,32.5f),"Cubic1");status(path->AddBezier(56.5f,32.5f,56.5f,60.5f,8.5f,48.5f,8.5f,32.5f),"Cubic2");status(path->CloseFigure(),"Close cubic");}
 else if(shape==1||shape==2){PointF a[]={{6.5f,8.5f},{28.5f,8.5f},{28.5f,52.5f},{6.5f,52.5f}},b[]={{36.5f,16.5f},{58.5f,16.5f},{58.5f,48.5f},{36.5f,48.5f}};status(path->AddPolygon(shape==1?a:b,4),"Disjoint1");status(path->AddPolygon(shape==1?b:a,4),"Disjoint2");}
 else if(shape==3||shape==4){PointF a[]={{6.5f,6.5f},{58.5f,6.5f},{58.5f,58.5f},{6.5f,58.5f}},b[]={{20.5f,20.5f},{44.5f,20.5f},{44.5f,44.5f},{20.5f,44.5f}},c[]={{20.5f,20.5f},{20.5f,44.5f},{44.5f,44.5f},{44.5f,20.5f}};status(path->AddPolygon(a,4),"Outer");status(path->AddPolygon(shape==3?b:c,4),"Inner");}
 else {PointF a[]={{8.5f,8.5f},{56.5f,56.5f},{8.5f,56.5f},{56.5f,8.5f}},b[]={{56.5f,8.5f},{8.5f,56.5f},{56.5f,56.5f},{8.5f,8.5f}};status(path->AddPolygon(shape==5?a:b,4),"Crossing");}
 return path;
}
static void drawGeneral(Graphics&g,PathGradientBrush&b,int use){
 status(g.SetPageUnit(UnitPixel),"Page");status(g.Clear(use==2?Color(255,255,255,255):Color(0,0,0,0)),"Clear");
 if(use==1)status(g.SetClip(Rect(16,12,32,40)),"Clip");
 if(use==2)status(g.SetCompositingMode(CompositingModeSourceCopy),"SourceCopy");
 if(use==3){Pen pen(&b,8);status(g.DrawRectangle(&pen,RectF(12.5f,12.5f,40,40)),"Pen");}
 else if(use==4){FontFamily family(L"Arial");Font font(&family,42,FontStyleRegular,UnitPixel);status(g.DrawString(L"M",1,&font,PointF(9,6),&b),"Glyph");}
 else status(g.FillRectangle(&b,RectF(0,0,64,64)),"Fill");
}
static void general(const GeneralSpec&s,const std::string&output){
 std::string name=std::string("native-general-")+s.name+".emf";startCase(name,"native-GraphicsPath-constructor");
 try {auto path=geometry(s.shape);PathGradientBrush brush(path.get());status(brush.GetLastStatus(),"Construct");status(brush.SetCenterPoint(PointF(32.5f,28.5f)),"Center");status(brush.SetCenterColor(Color(255,255,0,0)),"CenterColor");
 INT n=s.multi?path->GetPointCount():1;std::vector<Color>colors;Color palette[]={Color(255,0,0,255),Color(255,0,255,0),Color(255,255,255,255),Color(255,255,255,0)};for(int i=0;i<n;i++)colors.push_back(palette[i%4]);status(brush.SetSurroundColors(colors.data(),&n),"Colors");
 report<<",\"originalPointCount\":"<<path->GetPointCount()<<",\"surroundCount\":"<<brush.GetSurroundColorCount();
 auto flat=std::unique_ptr<GraphicsPath>(path->Clone());status(flat->Flatten(NULL,.25f),"Flatten");INT count=flat->GetPointCount();std::vector<PointF>p(count);std::vector<BYTE>t(count);status(flat->GetPathPoints(p.data(),count),"FlattenPoints");status(flat->GetPathTypes(t.data(),count),"FlattenTypes");report<<",\"nativeFlatten025\":[";for(int i=0;i<count;i++){if(i)report<<",";report<<"["<<std::setprecision(9)<<p[i].X<<","<<p[i].Y<<","<<(int)t[i]<<"]";}report<<"]";
 Bitmap image(64,64,PixelFormat32bppARGB);status(image.SetResolution(96,96),"DPI");{Graphics g(&image);drawGeneral(g,brush,s.use);}pixels(image,output,name);
 Bitmap ref(64,64);Graphics rg(&ref);HDC hdc=rg.GetHDC();{Metafile emf(wide(output+"/"+name).c_str(),hdc,RectF(0,0,64,64),MetafileFrameUnitPixel,EmfTypeEmfPlusOnly);status(emf.GetLastStatus(),"Record");Graphics g(&emf);drawGeneral(g,brush,s.use);}rg.ReleaseHDC(hdc);
 }catch(const std::string&e){error(e);}report<<"}";
 std::ifstream file(output+"/"+name,std::ios::binary);if(file.good())playback(output+"/"+name,output,"replay-"+name,"native-recorded-replay");
}
int main(int argc,char**argv){if(argc!=2)return 2;ULONG_PTR token;GdiplusStartupInput in;if(GdiplusStartup(&token,&in,NULL)!=Ok)return 3;UINT n,size;GetImageEncodersSize(&n,&size);std::vector<BYTE>bytes(size);auto enc=(ImageCodecInfo*)bytes.data();GetImageEncoders(n,size,enc);for(UINT i=0;i<n;i++)if(wcscmp(enc[i].MimeType,L"image/png")==0)pngEncoder=enc[i].Clsid;CreateDirectoryW(wide(argv[1]).c_str(),NULL);report.open(std::string(argv[1])+"/samples.json");report<<"{\"format\":\"straightRGBA top-left 64x64 96dpi; original native recorded EMFs; no prior cases rerun\",\"cases\":[";
 GeneralSpec cases[]={{"cubic-uniform",0},{"cubic-multi",0,true},{"disjoint-ab",1,true},{"disjoint-ba",2,true},{"nested-same",3,true},{"nested-reversed",4,true},{"crossing",5,true},{"crossing-reversed",6,true},{"cubic-clip",0,false,1},{"cubic-sourcecopy",0,false,2},{"cubic-pen",0,false,3},{"cubic-glyph",0,false,4}};for(auto&s:cases)general(s,argv[1]);report<<"]}";report.close();GdiplusShutdown(token);return 0;}
