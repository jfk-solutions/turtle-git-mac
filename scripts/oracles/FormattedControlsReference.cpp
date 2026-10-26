// Original bounded Windows GDI+/Uniscribe observation utility; no renderer.
#include <windows.h>
#include <gdiplus.h>
#include <usp10.h>
#include <fstream>
#include <iostream>
#include <iomanip>
#include <vector>
#include <string>
#include <stdexcept>
using namespace Gdiplus;
static CLSID encoder;
static void ck(Status s){if(s!=Ok)throw std::runtime_error("GDI+ status "+std::to_string((int)s));}
static std::wstring wide(const std::string&s){return std::wstring(s.begin(),s.end());}
static void units(std::ostream&o,const std::wstring&s){o<<"[";for(size_t i=0;i<s.size();i++){if(i)o<<",";o<<(unsigned short)s[i];}o<<"]";}
static void rectangle(std::ostream&o,const RectF&r){o<<"["<<r.X<<","<<r.Y<<","<<r.Width<<","<<r.Height<<"]";}
static void shape(std::ostream&o,const std::wstring&s,bool display){
 HDC dc=CreateCompatibleDC(NULL);if(!dc)throw std::runtime_error("DC");
 HFONT font=CreateFontW(-24,0,0,0,FW_NORMAL,0,0,0,DEFAULT_CHARSET,OUT_TT_PRECIS,CLIP_DEFAULT_PRECIS,ANTIALIASED_QUALITY,DEFAULT_PITCH,L"Arial");
 if(!font){DeleteDC(dc);throw std::runtime_error("font");}auto old=SelectObject(dc,font);
 wchar_t actual[256]={};GetTextFaceW(dc,256,actual);
 std::vector<SCRIPT_ITEM>items(s.size()+2);SCRIPT_CONTROL control={};SCRIPT_STATE state={};state.fDisplayZWG=display;int n=0;
 HRESULT hr=ScriptItemize(s.c_str(),(int)s.size(),(int)items.size()-1,&control,&state,items.data(),&n);
 o<<"{\"fontFaceUTF16\":";units(o,actual);o<<",\"itemizeHRESULT\":"<<(long)hr<<",\"runs\":[";
 if(SUCCEEDED(hr))for(int i=0;i<n;i++){
  if(i)o<<",";int begin=items[i].iCharPos,len=items[i+1].iCharPos-begin,cap=len*4+64,ng=0;
  auto a=items[i].a;a.s.fDisplayZWG=display;SCRIPT_CACHE cache=NULL;
  std::vector<WORD>glyphs(cap),clusters(len);std::vector<SCRIPT_VISATTR>vis(cap);
  HRESULT sh=ScriptShape(dc,&cache,s.c_str()+begin,len,cap,&a,glyphs.data(),clusters.data(),vis.data(),&ng);
  o<<"{\"start\":"<<begin<<",\"length\":"<<len<<",\"script\":"<<a.eScript<<",\"rtl\":"<<a.fRTL<<",\"bidiLevel\":"<<a.s.uBidiLevel<<",\"shapeHRESULT\":"<<(long)sh;
  if(SUCCEEDED(sh)){
   std::vector<int>adv(ng);std::vector<GOFFSET>off(ng);ABC abc={};
   HRESULT placed=ScriptPlace(dc,&cache,glyphs.data(),ng,vis.data(),&a,adv.data(),off.data(),&abc);
   o<<",\"placeHRESULT\":"<<(long)placed<<",\"clusters\":[";for(int j=0;j<len;j++){if(j)o<<",";o<<clusters[j];}o<<"],\"glyphs\":[";
   long long total=0;for(int j=0;j<ng;j++){if(j)o<<",";o<<"{\"id\":"<<glyphs[j]<<",\"clusterStart\":"<<vis[j].fClusterStart<<",\"zeroWidth\":"<<vis[j].fZeroWidth;
    if(SUCCEEDED(placed)){total+=adv[j];o<<",\"advance\":"<<adv[j]<<",\"offset\":["<<off[j].du<<","<<off[j].dv<<"]";}o<<"}";}
   o<<"]";if(SUCCEEDED(placed))o<<",\"advance\":"<<total<<",\"abc\":["<<abc.abcA<<","<<abc.abcB<<","<<abc.abcC<<"]";
  }o<<"}";ScriptFreeCache(&cache);
 }o<<"]}";SelectObject(dc,old);DeleteObject(font);DeleteDC(dc);
}
static void assay(std::ostream&o,Graphics&g,const std::wstring&s,RectF box,StringFormat&fmt,Font&font,FontFamily&family,bool display){
 o<<"{\"textUTF16\":";units(o,s);o<<",\"layout\":";rectangle(o,box);
 RectF bounds;INT fitted=0,lines=0;Status m=g.MeasureString(s.c_str(),(INT)s.size(),&font,box,&fmt,&bounds,&fitted,&lines);
 o<<",\"measureStatus\":"<<(int)m;if(m==Ok){o<<",\"measuredBounds\":";rectangle(o,bounds);o<<",\"charactersFitted\":"<<fitted<<",\"linesFilled\":"<<lines;}
 SolidBrush ink(Color(255,0,0,0));o<<",\"drawStatus\":"<<(int)g.DrawString(s.c_str(),(INT)s.size(),&font,box,&fmt,&ink);
 GraphicsPath path;Status added=path.AddString(s.c_str(),(INT)s.size(),&family,FontStyleRegular,24,box,&fmt);o<<",\"addStringStatus\":"<<(int)added;
 if(added==Ok){int n=path.GetPointCount();o<<",\"path\":{\"count\":"<<n<<",\"points\":[";if(n){std::vector<PointF>p(n);std::vector<BYTE>t(n);ck(path.GetPathPoints(p.data(),n));ck(path.GetPathTypes(t.data(),n));for(int i=0;i<n;i++){if(i)o<<",";o<<"["<<p[i].X<<","<<p[i].Y<<","<<(int)t[i]<<"]";}}o<<"]}";}
 o<<",\"uniscribe\":";shape(o,s,display);o<<"}";
}
struct Case{std::string name;std::wstring text;bool pair;LANGID lang=0;StringDigitSubstitute digits=StringDigitSubstituteNone;INT extraFlags=0;INT clearFlags=0;HotkeyPrefix hotkey=HotkeyPrefixNone;StringTrimming trimming=StringTrimmingNone;REAL boxWidth=480;REAL boxHeight=70;};
int main(int argc,char**argv){
 if(argc!=2)return 2;ULONG_PTR token=0;GdiplusStartupInput startup;if(GdiplusStartup(&token,&startup,NULL)!=Ok)return 3;int code=0;
 try{
 UINT n=0,size=0;ck(GetImageEncodersSize(&n,&size));std::vector<BYTE>data(size);ck(GetImageEncoders(n,size,(ImageCodecInfo*)data.data()));bool found=false;
 for(UINT i=0;i<n;i++){auto&e=((ImageCodecInfo*)data.data())[i];if(wcscmp(e.MimeType,L"image/png")==0){encoder=e.Clsid;found=true;}}if(!found)throw std::runtime_error("PNG encoder");
 std::string dir=argv[1];CreateDirectoryW(wide(dir).c_str(),NULL);std::ofstream out(dir+"/formatted-controls.json");if(!out)throw std::runtime_error("Report open");out<<std::setprecision(9);
 std::vector<Case>cases;struct Control{const char*name;wchar_t c;};
 const Control controls[]={{"lrm",0x200e},{"rlm",0x200f},{"zwj",0x200d},{"zwnj",0x200c},{"zwsp",0x200b},{"lre",0x202a},{"rle",0x202b},{"lro",0x202d},{"rlo",0x202e},{"pdf",0x202c},{"lri",0x2066},{"rli",0x2067},{"fsi",0x2068},{"pdi",0x2069},{"alm",0x061c},{"word-joiner",0x2060},{"bom",0xfeff},{"soft-hyphen",0x00ad},{"tab",9},{"newline",10},{"carriage-return",13}};
 for(auto c:controls)cases.push_back({c.name,std::wstring(1,c.c),true});
 cases.push_back({"arabic-zwj",L"\x0628\x200d\x0628",false});cases.push_back({"arabic-zwnj",L"\x0628\x200c\x0628",false});
 cases.push_back({"mixed-bidi",L"A (\x05d0\x05d1) \x200f 12 B",false});
 cases.push_back({"embedding-paired",L"A \x202b\x05d0\x05d1 12\x202c B",false});
 cases.push_back({"isolate-paired",L"A \x2067\x05d0\x05d1 12\x2069 B",false});
 cases.push_back({"arabic-salaam",L"\x0633\x0644\x0627\x0645",false});
 cases.push_back({"arabic-salaamat",L"\x0633\x0644\x0627\x0645\x062a",false});
 cases.push_back({"arabic-s-rlm-laam",L"\x0633\x200f\x0644\x0627\x0645",false});
 // Each option profile is paired with its own hidden/display observation.
 Case vertical={"vertical-lrm",L"A\x200e" L"B",false};vertical.extraFlags=StringFormatFlagsDirectionVertical;vertical.boxHeight=150;cases.push_back(vertical);
 Case wrap={"wrap-lrm",L"Alpha \x200e Beta \x200e Gamma Delta",false};wrap.clearFlags=StringFormatFlagsNoWrap;wrap.boxWidth=100;wrap.boxHeight=150;cases.push_back(wrap);
 Case trim={"trim-lrm",L"Alpha \x200e Beta Gamma Delta",false};trim.extraFlags=StringFormatFlagsNoWrap;trim.trimming=StringTrimmingEllipsisCharacter;trim.boxWidth=100;trim.boxHeight=40;cases.push_back(trim);
 Case hotkey={"hotkey-lrm",L"A&\x200e" L"B",false};hotkey.hotkey=HotkeyPrefixShow;cases.push_back(hotkey);
 out<<"{\"schema\":1,\"width\":512,\"height\":192,\"dpi\":96,\"pixelFormat\":\"straight RGBA, top-left row-major\",\"font\":\"Arial\",\"emSizePixels\":24,\"formatBase\":\"GenericTypographic controls; both GenericDefault and GenericTypographic digits; original flags except DisplayFormatControl\",\"note\":\"Uniscribe is an independent assay, not a claim that GDI+ uses identical runs. Measured bounds are not advance widths; per-run Uniscribe advances are recorded separately.\",\"cases\":[";
 bool first=true;
 auto run=[&](const Case&c,bool show,bool digit,bool typographic){
  std::string name=c.name+(digit?"":show?"-display":"-hidden");if(!first)out<<",";first=false;
  Bitmap bitmap(512,192,PixelFormat32bppARGB);ck(bitmap.SetResolution(96,96));
  {Graphics g(&bitmap);ck(g.Clear(Color(0,0,0,0)));ck(g.SetPageUnit(UnitPixel));ck(g.SetTextRenderingHint(TextRenderingHintAntiAliasGridFit));
   Font font(L"Arial",24,FontStyleRegular,UnitPixel);ck(font.GetLastStatus());FontFamily family(L"Arial");ck(family.GetLastStatus());
   StringFormat fmt(typographic?StringFormat::GenericTypographic():StringFormat::GenericDefault());INT flags=(fmt.GetFormatFlags()|c.extraFlags)&~c.clearFlags;flags=show?flags|StringFormatFlagsDisplayFormatControl:flags&~StringFormatFlagsDisplayFormatControl;ck(fmt.SetFormatFlags(flags));ck(fmt.SetDigitSubstitution(c.lang,c.digits));ck(fmt.SetHotkeyPrefix(c.hotkey));ck(fmt.SetTrimming(c.trimming));
   out<<"{\"name\":\""<<name<<"\",\"displayFormatControl\":"<<(show?"true":"false")<<",\"flags\":"<<(unsigned int)flags<<",\"genericTypographic\":"<<(typographic?"true":"false")<<",\"hotkey\":"<<(int)c.hotkey<<",\"trimming\":"<<(int)c.trimming<<",\"digitLanguage\":"<<c.lang<<",\"digitSubstitution\":"<<(int)c.digits<<",\"variants\":[";
   assay(out,g,c.text,RectF(16,16,c.boxWidth,c.boxHeight),fmt,font,family,show);
   if(c.pair){out<<",";assay(out,g,L"A"+c.text+L"B",RectF(16,102,480,70),fmt,font,family,show);}out<<"]";
  }
  ck(bitmap.Save(wide(dir+"/"+name+".png").c_str(),&encoder,NULL));std::ofstream raw(dir+"/"+name+".rgba",std::ios::binary);if(!raw)throw std::runtime_error("RGBA open");
  int minx=512,miny=192,maxx=-1,maxy=-1;unsigned long count=0;
  for(int y=0;y<192;y++)for(int x=0;x<512;x++){Color c;ck(bitmap.GetPixel(x,y,&c));unsigned char b[]={c.GetR(),c.GetG(),c.GetB(),c.GetA()};raw.write((char*)b,4);if(c.GetA()){if(x<minx)minx=x;if(y<miny)miny=y;if(x>maxx)maxx=x;if(y>maxy)maxy=y;count++;}}
  raw.close();if(!raw)throw std::runtime_error("RGBA write");
  out<<",\"paintedPixels\":"<<count<<",\"paintedBounds\":["<<minx<<","<<miny<<","<<maxx<<","<<maxy<<"],\"png\":\""<<name<<".png\",\"rgba\":\""<<name<<".rgba\"}";
 };
 for(const auto&c:cases){run(c,false,false,true);run(c,true,false,true);}
 const LANGID langs[]={0x041e,0x0401,0x0429};const char*names[]={"thai","arabic","persian"};
 for(int i=0;i<3;i++)for(int m=2;m<=3;m++)for(int profile=0;profile<2;profile++){Case c={std::string("digits-")+names[i]+(m==2?"-national":"-traditional")+(profile?"-typographic":"-default"),L"0123456789",false,langs[i],(StringDigitSubstitute)m};run(c,false,true,profile!=0);}
 const wchar_t*literalTexts[]={L"0123456789",L"\x0e50\x0e51\x0e52\x0e53\x0e54\x0e55\x0e56\x0e57\x0e58\x0e59",L"\x0660\x0661\x0662\x0663\x0664\x0665\x0666\x0667\x0668\x0669",L"\x06f0\x06f1\x06f2\x06f3\x06f4\x06f5\x06f6\x06f7\x06f8\x06f9"};
 const char*literalNames[]={"ascii","thai","arabic","persian"};
 for(int i=0;i<4;i++)for(int profile=0;profile<2;profile++){Case c={std::string("literal-")+literalNames[i]+(profile?"-typographic":"-default"),literalTexts[i],false,0,StringDigitSubstituteNone};run(c,false,true,profile!=0);}
 out<<"]}";out.close();if(!out)throw std::runtime_error("Report write");std::cout<<"Recorded "<<cases.size()*2+20<<" cases; no parity assertions.\n";
 }catch(const std::exception&e){std::cerr<<e.what()<<"\n";code=1;}GdiplusShutdown(token);return code;
}

