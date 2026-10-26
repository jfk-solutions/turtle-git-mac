// Original synthetic Windows serialized-EMF reference. No renderer implementation.
#include <windows.h>
#include <gdiplus.h>
#include <fstream>
#include <iostream>
#include <iomanip>
#include <vector>
#include <string>
#include <stdexcept>
using namespace Gdiplus;
static CLSID png;
static void ck(Status s){if(s!=Ok)throw std::runtime_error("GDI+ status "+std::to_string((int)s));}
static std::wstring wide(const std::string&s){return std::wstring(s.begin(),s.end());}
static void rect(std::ostream&o,const RectF&r){o<<"["<<r.X<<","<<r.Y<<","<<r.Width<<","<<r.Height<<"]";}
static void units(std::ostream&o,const std::wstring&s){o<<"[";for(size_t i=0;i<s.size();i++){if(i)o<<",";o<<(unsigned short)s[i];}o<<"]";}
static void pixels(Bitmap&b,const std::string&dir,const std::string&stem,std::ostream&o){
 ck(b.Save(wide(dir+"/"+stem+".png").c_str(),&png,NULL));std::ofstream raw(dir+"/"+stem+".rgba",std::ios::binary);if(!raw)throw std::runtime_error("RGBA open");
 int x0=240,y0=180,x1=-1,y1=-1;unsigned long count=0;
 for(int y=0;y<180;y++)for(int x=0;x<240;x++){Color c;ck(b.GetPixel(x,y,&c));unsigned char bytes[]={c.GetR(),c.GetG(),c.GetB(),c.GetA()};raw.write((char*)bytes,4);if(c.GetR()!=255||c.GetG()!=255||c.GetB()!=255){if(x<x0)x0=x;if(y<y0)y0=y;if(x>x1)x1=x;if(y>y1)y1=y;count++;}}
 raw.close();if(!raw)throw std::runtime_error("RGBA write");
 o<<"{\"png\":\""<<stem<<".png\",\"rgba\":\""<<stem<<".rgba\",\"nonwhitePixels\":"<<count<<",\"paintedBounds\":["<<x0<<","<<y0<<","<<x1<<","<<y1<<"]}";
}
static void configure(Graphics&g){ck(g.SetPageUnit(UnitPixel));ck(g.SetTextRenderingHint(TextRenderingHintAntiAliasGridFit));}
static void replay(std::ostream&o,const std::string&path,const std::string&dir,const std::string&name){
 Metafile image(wide(path).c_str());Status loaded=image.GetLastStatus();o<<"{\"loadStatus\":"<<(int)loaded;
 if(loaded==Ok){RectF bounds;Unit unit;Status bs=image.GetBounds(&bounds,&unit);o<<",\"boundsStatus\":"<<(int)bs;if(bs==Ok){o<<",\"sourceBounds\":";rect(o,bounds);o<<",\"boundsUnit\":"<<(int)unit;}o<<",\"sourceSize\":["<<image.GetWidth()<<","<<image.GetHeight()<<"],\"sourceDPI\":["<<image.GetHorizontalResolution()<<","<<image.GetVerticalResolution()<<"]";
  Bitmap b(240,180,PixelFormat32bppARGB);ck(b.SetResolution(96,96));{Graphics g(&b);ck(g.Clear(Color(255,255,255,255)));configure(g);Status draw=g.DrawImage(&image,Rect(0,0,240,180),0,0,240,180,UnitPixel);o<<",\"drawImageStatus\":"<<(int)draw;}o<<",\"pixels\":";pixels(b,dir,name,o);
 }o<<"}";
}
static void draw(Graphics&g,const std::wstring&s,bool display){
 configure(g);Font font(L"Arial",24,FontStyleRegular,UnitPixel);ck(font.GetLastStatus());StringFormat format(StringFormat::GenericTypographic());INT flags=format.GetFormatFlags();ck(format.SetFormatFlags(display?flags|StringFormatFlagsDisplayFormatControl:flags&~StringFormatFlagsDisplayFormatControl));ck(format.SetDigitSubstitution(0,StringDigitSubstituteNone));SolidBrush ink(Color(255,0,0,0));ck(g.DrawString(s.c_str(),(INT)s.size(),&font,RectF(16,16,208,148),&format,&ink));
}
static void cmap(std::ostream&o){
 HDC dc=CreateCompatibleDC(NULL);if(!dc)throw std::runtime_error("cmap DC");HFONT font=CreateFontW(-24,0,0,0,FW_NORMAL,0,0,0,DEFAULT_CHARSET,OUT_TT_PRECIS,CLIP_DEFAULT_PRECIS,ANTIALIASED_QUALITY,DEFAULT_PITCH,L"Arial");if(!font){DeleteDC(dc);throw std::runtime_error("cmap font");}auto old=SelectObject(dc,font);wchar_t face[256]={};GetTextFaceW(dc,256,face);
 o<<"{\"fontFaceUTF16\":";units(o,face);o<<",\"entries\":[";wchar_t controls[]={0x200e,0x200f,0x200d,0x200c};MAT2 matrix={{0,1},{0,0},{0,0},{0,1}};
 for(int i=0;i<4;i++){if(i)o<<",";WORD glyph=0;DWORD mapped=GetGlyphIndicesW(dc,&controls[i],1,&glyph,GGI_MARK_NONEXISTING_GLYPHS);o<<"{\"unicode\":"<<(unsigned short)controls[i]<<",\"getGlyphIndicesResult\":"<<mapped<<",\"glyph\":"<<glyph;
  if(mapped!=GDI_ERROR&&glyph!=0xffff){GLYPHMETRICS gm={};DWORD bytes=GetGlyphOutlineW(dc,glyph,GGO_NATIVE|GGO_GLYPH_INDEX,&gm,0,NULL,&matrix);o<<",\"nativeOutlineBytes\":"<<bytes;if(bytes!=GDI_ERROR)o<<",\"blackBox\":["<<gm.gmBlackBoxX<<","<<gm.gmBlackBoxY<<"],\"origin\":["<<gm.gmptGlyphOrigin.x<<","<<gm.gmptGlyphOrigin.y<<"],\"cellAdvance\":["<<gm.gmCellIncX<<","<<gm.gmCellIncY<<"]";}
  o<<"}";
 }o<<"]}";SelectObject(dc,old);DeleteObject(font);DeleteDC(dc);
}
int main(int argc,char**argv){
 if(argc!=3)return 2;ULONG_PTR token=0;GdiplusStartupInput start;if(GdiplusStartup(&token,&start,NULL)!=Ok)return 3;int code=0;
 try{
 UINT n=0,size=0;ck(GetImageEncodersSize(&n,&size));std::vector<BYTE>bytes(size);ck(GetImageEncoders(n,size,(ImageCodecInfo*)bytes.data()));bool found=false;for(UINT i=0;i<n;i++){auto&e=((ImageCodecInfo*)bytes.data())[i];if(wcscmp(e.MimeType,L"image/png")==0){png=e.Clsid;found=true;}}if(!found)throw std::runtime_error("PNG encoder");
 std::string input=argv[1],output=argv[2];CreateDirectoryW(wide(output).c_str(),NULL);std::ofstream o(output+"/formatted-replay.json");if(!o)throw std::runtime_error("report open");o<<std::setprecision(9);
 o<<"{\"schema\":1,\"width\":240,\"height\":180,\"dpi\":96,\"pixelFormat\":\"straight RGBA top-left row-major, opaque white background\",\"replay\":\"DrawImage destination 0,0,240,180 and source 0,0,240,180 UnitPixel\",\"cmap\":";cmap(o);o<<",\"fixtures\":[";
 const char*names[]={"thai-national","thai-traditional","arabic-national","persian-traditional","latin-control","thai-control","arabic-control","persian-control"};
 for(int i=0;i<8;i++){if(i)o<<",";std::string name=std::string("plus-formatted-digits-")+names[i];o<<"{\"file\":\""<<name<<".emf\",\"replay\":";replay(o,input+"/"+name+".emf",output,name);o<<"}";}
 o<<"],\"nativeRecorded\":[";
 const wchar_t controls[]={0x200e,0x200f,0x200d,0x200c};const char*controlNames[]={"lrm","rlm","zwj","zwnj"};const char*contextNames[]={"alone","latin","separated","arabic"};bool first=true;
 for(int i=0;i<4;i++)for(int context=0;context<4;context++)for(int display=0;display<2;display++){
  std::wstring c(1,controls[i]),s=context==0?c:context==1?L"A"+c+L"B":context==2?L"A ( "+c+L" ) B":L"\x0633"+c+L"\x0644\x0627\x0645";
  std::string name=std::string(controlNames[i])+"-"+contextNames[context]+(display?"-display":"-hidden");if(!first)o<<",";first=false;
  std::string path=output+"/"+name+".emf";
  Bitmap reference(240,180,PixelFormat32bppARGB);ck(reference.SetResolution(96,96));Graphics referenceGraphics(&reference);HDC dc=referenceGraphics.GetHDC();if(!dc)throw std::runtime_error("record HDC");
  {Metafile recording(wide(path).c_str(),dc,RectF(0,0,240,180),MetafileFrameUnitPixel,EmfTypeEmfPlusOnly);ck(recording.GetLastStatus());{Graphics g(&recording);draw(g,s,display!=0);}}
  referenceGraphics.ReleaseHDC(dc);ck(referenceGraphics.GetLastStatus());
  o<<"{\"name\":\""<<name<<"\",\"textUTF16\":";units(o,s);o<<",\"displayFormatControl\":"<<(display?"true":"false")<<",\"emf\":\""<<name<<".emf\",\"replay\":";replay(o,path,output,name+"-replay");o<<",\"direct\":";
  Bitmap direct(240,180,PixelFormat32bppARGB);ck(direct.SetResolution(96,96));{Graphics g(&direct);ck(g.Clear(Color(255,255,255,255)));draw(g,s,display!=0);}pixels(direct,output,name+"-direct",o);o<<"}";
 }
 o<<"]}";o.close();if(!o)throw std::runtime_error("report write");std::cout<<"Recorded 8 serialized fixtures and 32 native EMF+Only/direct pairs.\n";
 }catch(const std::exception&e){std::cerr<<e.what()<<"\n";code=1;}GdiplusShutdown(token);return code;
}

