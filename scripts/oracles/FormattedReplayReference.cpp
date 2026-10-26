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
static void formatObjects(std::ostream&o,const std::string&path){
 std::ifstream f(path,std::ios::binary|std::ios::ate);o<<"[";if(!f){o<<"]";return;}auto count=f.tellg();if(count<0||count>1024*1024*16){o<<"]";return;}std::vector<unsigned char>b((size_t)count);f.seekg(0);f.read((char*)b.data(),(std::streamsize)b.size());
 auto u16=[&](size_t p)->unsigned int{return b[p]|((unsigned int)b[p+1]<<8);};auto u32=[&](size_t p)->unsigned long{return b[p]|((unsigned long)b[p+1]<<8)|((unsigned long)b[p+2]<<16)|((unsigned long)b[p+3]<<24);};bool first=true;
 for(size_t e=0;e+8<=b.size();){size_t n=u32(e+4);if(n<8||n>b.size()-e)break;if(u32(e)==70&&n>=16&&u32(e+12)==0x2b464d45){for(size_t r=e+16;r+12<=e+n;){size_t z=u32(r+4);if(z<12||z>e+n-r)break;if(u16(r)==0x4008&&((u16(r+2)>>8)&0x7f)==7&&z>=72){if(!first)o<<",";first=false;auto language=u32(r+20),digits=u32(r+36);o<<"{\"offset\":"<<r<<",\"rawLanguage\":"<<language<<",\"effectiveLanguage\":"<<(language&0xffff)<<",\"rawDigitLanguage\":"<<digits<<",\"effectiveDigitLanguage\":"<<(digits&0xffff)<<"}";}r+=z;}}e+=n;}o<<"]";
}
static void replay(std::ostream&o,const std::string&path,const std::string&dir,const std::string&name){
 Metafile image(wide(path).c_str());Status loaded=image.GetLastStatus();o<<"{\"formatObjects\":";formatObjects(o,path);o<<",\"loadStatus\":"<<(int)loaded;
 if(loaded==Ok){RectF bounds;Unit unit;Status bs=image.GetBounds(&bounds,&unit);o<<",\"boundsStatus\":"<<(int)bs;if(bs==Ok){o<<",\"sourceBounds\":";rect(o,bounds);o<<",\"boundsUnit\":"<<(int)unit;}o<<",\"sourceSize\":["<<image.GetWidth()<<","<<image.GetHeight()<<"],\"sourceDPI\":["<<image.GetHorizontalResolution()<<","<<image.GetVerticalResolution()<<"]";
  Bitmap b(240,180,PixelFormat32bppARGB);ck(b.SetResolution(96,96));{Graphics g(&b);ck(g.Clear(Color(255,255,255,255)));configure(g);Status draw=g.DrawImage(&image,Rect(0,0,240,180),0,0,240,180,UnitPixel);o<<",\"drawImageStatus\":"<<(int)draw;}o<<",\"pixels\":";pixels(b,dir,name,o);
 }o<<"}";
}
static void draw(Graphics&g,const std::wstring&s,LANGID language,StringDigitSubstitute digits,INT extraFlags){
 configure(g);Font font(L"Arial",24,FontStyleRegular,UnitPixel);ck(font.GetLastStatus());StringFormat format(StringFormat::GenericTypographic());ck(format.SetFormatFlags(format.GetFormatFlags()|extraFlags));ck(format.SetDigitSubstitution(language,digits));SolidBrush ink(Color(255,0,0,0));ck(g.DrawString(s.c_str(),(INT)s.size(),&font,RectF(16,16,208,148),&format,&ink));
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
 struct DigitCase{std::string name;std::wstring text;LANGID language;StringDigitSubstitute method;INT flags;};std::vector<DigitCase>cases;
 const LANGID languages[]={0x041e,0x0401,0x0429};const char*languageNames[]={"thai","arabic","persian"};
 for(int i=0;i<3;i++)for(int method=2;method<=3;method++)for(int context=0;context<2;context++)cases.push_back({std::string(languageNames[i])+(method==2?"-national":"-traditional")+(context?"-arabic-rtl":"-plain"),context?L"\x0633\x0644\x0627\x0645 0123456789":L"0123456789",languages[i],(StringDigitSubstitute)method,context?StringFormatFlagsDirectionRightToLeft:0});
 const wchar_t*literals[]={L"0123456789",L"\x0e50\x0e51\x0e52\x0e53\x0e54\x0e55\x0e56\x0e57\x0e58\x0e59",L"\x0660\x0661\x0662\x0663\x0664\x0665\x0666\x0667\x0668\x0669",L"\x06f0\x06f1\x06f2\x06f3\x06f4\x06f5\x06f6\x06f7\x06f8\x06f9"};const char*literalNames[]={"ascii","thai","arabic","persian"};
 for(int i=0;i<4;i++)cases.push_back({std::string("literal-")+literalNames[i],literals[i],0,StringDigitSubstituteNone,0});
 cases.push_back({"literal-ascii-arabic-rtl",std::wstring(L"\x0633\x0644\x0627\x0645 ")+literals[0],0,StringDigitSubstituteNone,StringFormatFlagsDirectionRightToLeft});
 cases.push_back({"literal-arabic-arabic-rtl",std::wstring(L"\x0633\x0644\x0627\x0645 ")+literals[2],0,StringDigitSubstituteNone,StringFormatFlagsDirectionRightToLeft});
 bool first=true;for(const auto&c:cases){const auto&s=c.text;const auto&name=c.name;if(!first)o<<",";first=false;
  std::string path=output+"/"+name+".emf";
  Bitmap reference(240,180,PixelFormat32bppARGB);ck(reference.SetResolution(96,96));Graphics referenceGraphics(&reference);HDC dc=referenceGraphics.GetHDC();if(!dc)throw std::runtime_error("record HDC");
  {Metafile recording(wide(path).c_str(),dc,RectF(0,0,240,180),MetafileFrameUnitPixel,EmfTypeEmfPlusOnly);ck(recording.GetLastStatus());{Graphics g(&recording);draw(g,s,c.language,c.method,c.flags);}}
  referenceGraphics.ReleaseHDC(dc);ck(referenceGraphics.GetLastStatus());
  o<<"{\"name\":\""<<name<<"\",\"textUTF16\":";units(o,s);o<<",\"requestedLanguage\":"<<c.language<<",\"effectiveLanguage\":"<<(c.language&0xffff)<<",\"digitSubstitution\":"<<(int)c.method<<",\"extraFlags\":"<<c.flags<<",\"emf\":\""<<name<<".emf\",\"replay\":";replay(o,path,output,name+"-replay");o<<",\"direct\":";
  Bitmap direct(240,180,PixelFormat32bppARGB);ck(direct.SetResolution(96,96));{Graphics g(&direct);ck(g.Clear(Color(255,255,255,255)));draw(g,s,c.language,c.method,c.flags);}pixels(direct,output,name+"-direct",o);o<<"}";
 }
 o<<"]}";o.close();if(!o)throw std::runtime_error("report write");std::cout<<"Recorded 8 aligned serialized fixtures and 18 native digit EMF+Only/direct pairs.\n";
 }catch(const std::exception&e){std::cerr<<e.what()<<"\n";code=1;}GdiplusShutdown(token);return code;
}

