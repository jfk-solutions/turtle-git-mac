// SPDX-License-Identifier: MIT
// Independent signed/cropped WMF geometry observer. No TurtleGit renderer math.
// Own retained-control helpers adapted from InterpolationIdentityReference.cpp.
// Full-frame outputs deliberately make no expected destination-bounds assertion.
// Original wires/retained target samples are immutable inputs.tsv entries.
// API names checked against Microsoft Learn gdiplusenums.h InterpolationMode,
// PixelOffsetMode and WrapMode pages and Gdipluspixelformats.h constants.
// No external interpolation implementation is copied.
#define NOMINMAX
#include <windows.h>
#include <gdiplus.h>
#include <filesystem>
#include <fstream>
#include <sstream>
#include <iterator>
#include <vector>
#include <string>
#include <memory>
#include <set>
#include <iostream>
#include <stdexcept>
#include <algorithm>
#include <utility>
using namespace Gdiplus;
namespace fs=std::filesystem;
using Bytes=std::vector<BYTE>;
static void require(bool value,const char* reason){if(!value)throw std::runtime_error(reason);}
static void need(const Bytes& b,size_t p,size_t n){require(p<=b.size()&&n<=b.size()-p,"wire bounds");}
static WORD u16(const Bytes& b,size_t p){need(b,p,2);return WORD(b[p]|b[p+1]<<8);}
static int s16(const Bytes& b,size_t p){return short(u16(b,p));}
static DWORD u32(const Bytes& b,size_t p){return DWORD(u16(b,p))|DWORD(u16(b,p+2))<<16;}
static void set16(Bytes& b,size_t p,unsigned n){need(b,p,2);b[p]=BYTE(n);b[p+1]=BYTE(n>>8);}
static void set32(Bytes& b,size_t p,DWORD n){set16(b,p,n);set16(b,p+2,n>>16);}
static Bytes read(const fs::path& path){std::ifstream f(path,std::ios::binary);require(bool(f),"read input");Bytes b((std::istreambuf_iterator<char>(f)),{});require(b.size()<=1024*1024,"input budget");return b;}
static void write(const fs::path& path,const Bytes& b){std::ofstream f(path,std::ios::binary);f.write(reinterpret_cast<const char*>(b.data()),std::streamsize(b.size()));require(bool(f),"write");}
static std::string hex(const Bytes& b){static const char* chars="0123456789abcdef";std::string s;s.reserve(b.size()*2);for(BYTE v:b){s+=chars[v>>4];s+=chars[v&15];}return s;}
static Bytes unhex(const std::string& s){require(s.size()%2==0,"hex length");auto nibble=[](char c){if(c>='0'&&c<='9')return c-'0';if(c>='a'&&c<='f')return c-'a'+10;throw std::runtime_error("hex digit");};Bytes b;for(size_t i=0;i<s.size();i+=2)b.push_back(BYTE(nibble(s[i])*16+nibble(s[i+1])));return b;}
static std::vector<std::string> split(const std::string& text){std::vector<std::string> v;std::stringstream s(text);std::string field;while(std::getline(s,field,'\t'))v.push_back(field);return v;}
struct Spec{std::string name,file,sha,run,commit;int width=0,height=0,x=0,y=0,dw=0,dh=0;Bytes expected,expectedPrepaint,expectedEvidence;std::vector<Point> evidence;std::string evidencePoints,evidenceRawSHA;};
static std::vector<Spec> specs(const fs::path& folder){std::ifstream file(folder/"inputs.tsv");require(bool(file),"manifest read");std::string line;std::getline(file,line);if(!line.empty()&&line.back()=='\r')line.pop_back();require(line=="name\tfile\tsha256\tcanvasWidth\tcanvasHeight\tx\ty\twidth\theight\ttargetRGBAHex\tsourceRun\tsourceCommit\tprepaintTargetRGBAHex\tbackgroundEvidencePoints\tbackgroundEvidenceRGBAHex\tbackgroundEvidenceRawSHA256","manifest schema");std::vector<Spec> result;std::set<std::string> names;
 while(std::getline(file,line)){if(!line.empty()&&line.back()=='\r')line.pop_back();auto v=split(line);require(v.size()==16,"manifest columns");require(std::set<std::string>{"b33","b66","b498","b528","b310","continuity"}.count(v[0])==1,"manifest identity");require(names.insert(v[0]).second&&v[1]==v[0]+".wmf","duplicate or unsafe input");Spec s;s.name=v[0];s.file=v[1];s.sha=v[2];s.width=std::stoi(v[3]);s.height=std::stoi(v[4]);s.x=std::stoi(v[5]);s.y=std::stoi(v[6]);s.dw=std::stoi(v[7]);s.dh=std::stoi(v[8]);s.expected=unhex(v[9]);s.run=v[10];s.commit=v[11];s.expectedPrepaint=unhex(v[12]);s.evidencePoints=v[13];s.expectedEvidence=unhex(v[14]);s.evidenceRawSHA=v[15];std::stringstream coordinates(s.evidencePoints);std::string point;while(std::getline(coordinates,point,';')){size_t comma=point.find(',');require(comma!=std::string::npos,"evidence point");int x=std::stoi(point.substr(0,comma)),y=std::stoi(point.substr(comma+1));require(x>=0&&x<s.width&&y>=0&&y<s.height&&!(x>=s.x&&x<s.x+s.dw&&y>=s.y&&y<s.y+s.dh),"evidence must be outside transfer");s.evidence.emplace_back(x,y);}require(s.evidence.size()==3&&s.expectedEvidence.size()==12&&unhex(s.evidenceRawSHA).size()==32,"background evidence manifest");require(unhex(s.sha).size()==32&&unhex(s.commit).size()==20,"manifest provenance");require(s.width>0&&s.width<=240&&s.height>0&&s.height<=160&&s.x>=0&&s.y>=0&&s.dw>0&&s.dh>0&&s.x+s.dw<=s.width&&s.y+s.dh<=s.height,"manifest geometry");require(s.expected.size()==size_t(s.dw*s.dh*4)&&s.expectedPrepaint.size()==s.expected.size(),"manifest target length");result.push_back(s);}
 require(result.size()==6,"manifest input count");return result;
}
struct Parsed{int sw=0,sh=0,stride=0,dx=0,dy=0,dw=0,dh=0;int wx=0,wy=0,ww=0,wh=0,vx=0,vy=0,vw=0,vh=0;bool viewportExplicit=false;size_t blitStart=0,blitEnd=0;Bytes bgrx,rgba;};
static Parsed parse(const Bytes& b,const Spec& s){
 need(b,0,40);require(u32(b,0)==0x9ac6cdd7&&u16(b,6)==0&&u16(b,8)==0&&u16(b,10)==s.width&&u16(b,12)==s.height&&u16(b,14)==96,"retained placeable geometry");WORD checksum=0;for(size_t p=0;p<20;p+=2)checksum^=u16(b,p);require(checksum==u16(b,20),"placeable checksum");require(u16(b,24)==9&&u16(b,26)==0x300&&u32(b,28)*2==b.size()-22,"WMF header");Parsed p;p.ww=s.width;p.wh=s.height;p.vw=s.width;p.vh=s.height;int mode=MM_ANISOTROPIC,blits=0;size_t at=40,maximum=0;bool eof=false;
 while(at<b.size()){need(b,at,6);DWORD words=u32(b,at);require(words>=3&&words<=(b.size()-at)/2,"record framing");maximum=std::max(maximum,size_t(words));WORD type=u16(b,at+4);size_t bytes=size_t(words)*2;
  if(p.blitEnd)require(type==0,"unexpected command after selected transfer");
  if(type==META_SETMAPMODE){require(words==4,"mapmode record");mode=s16(b,at+6);}
  if(type==META_SETWINDOWORG){require(words==5,"window origin");p.wy=s16(b,at+6);p.wx=s16(b,at+8);}
  if(type==META_SETWINDOWEXT){require(words==5,"window extent");p.wh=s16(b,at+6);p.ww=s16(b,at+8);}
  if(type==META_SETVIEWPORTORG){require(words==5,"viewport origin");p.vy=s16(b,at+6);p.vx=s16(b,at+8);}
  if(type==META_SETVIEWPORTEXT){require(words==5,"viewport extent");p.vh=s16(b,at+6);p.vw=s16(b,at+8);p.viewportExplicit=true;}
  if(type==META_STRETCHBLT){require(++blits==1&&mode==MM_ANISOTROPIC,"single anisotropic transfer");require(bytes>=36,"Bitmap16 transfer prefix");need(b,at,36);require(u32(b,at+6)==SRCCOPY,"selected ROP");int sh=s16(b,at+10),sw=s16(b,at+12),sy=s16(b,at+14),sx=s16(b,at+16),dh=s16(b,at+18),dw=s16(b,at+20),dy=s16(b,at+22),dx=s16(b,at+24);p.sw=s16(b,at+28);p.sh=s16(b,at+30);p.stride=s16(b,at+32);require(u16(b,at+26)==0&&p.sw>0&&p.sw<=8&&p.sh>0&&p.sh<=7&&p.stride==p.sw*4&&b[at+34]==1&&b[at+35]==32,"selected BGRX Bitmap16");require(sx==0&&sy==0&&sw==p.sw&&sh==p.sh&&dw>0&&dh>0,"selected source rectangle");require(bytes==36+size_t(p.stride*p.sh),"exact Bitmap16 payload size");require(p.ww>0&&p.wh>0&&p.vw>0&&p.vh>0,"mapping extents");auto mapped=[](int logical,int origin,int windowExtent,int viewportExtent,int viewportOrigin){long long numerator=(static_cast<long long>(logical)-origin)*viewportExtent;require(numerator%windowExtent==0,"selected mapping is not exact integer device geometry");return int(numerator/windowExtent)+viewportOrigin;};p.dx=mapped(dx,p.wx,p.ww,p.vw,p.vx);p.dy=mapped(dy,p.wy,p.wh,p.vh,p.vy);p.dw=mapped(dx+dw,p.wx,p.ww,p.vw,p.vx)-p.dx;p.dh=mapped(dy+dh,p.wy,p.wh,p.vh,p.vy)-p.dy;require(p.dx==s.x&&p.dy==s.y&&p.dw==s.dw&&p.dh==s.dh,"wire mapping differs from retained target");p.blitStart=at;p.blitEnd=at+bytes;p.bgrx.assign(b.begin()+at+36,b.begin()+at+bytes);for(size_t i=0;i<p.bgrx.size();i+=4)p.rgba.insert(p.rgba.end(),{p.bgrx[i+2],p.bgrx[i+1],p.bgrx[i],255});}
  if(type==0){require(words==3&&at+6==b.size(),"EOF");eof=true;}at+=bytes;
 }
 require(at==b.size()&&eof&&blits==1&&maximum<=u32(b,34),"complete selected wire");return p;
}
static Bytes prepaint(const Bytes& original,const Parsed& p){Bytes b(original.begin(),original.begin()+p.blitStart);b.insert(b.end(),original.begin()+p.blitEnd,original.end());set32(b,28,DWORD((b.size()-22)/2));size_t at=40,maximum=0;while(at<b.size()){DWORD words=u32(b,at);require(words>=3&&words<=(b.size()-at)/2,"prepaint framing");maximum=std::max(maximum,size_t(words));at+=size_t(words)*2;}require(at==b.size(),"prepaint EOF");set32(b,34,DWORD(maximum));return b;}
static std::unique_ptr<Bitmap> natural(Bitmap& image,Status& draw){UINT w=image.GetWidth(),h=image.GetHeight();auto result=std::make_unique<Bitmap>(w,h,PixelFormat32bppARGB);require(result->GetLastStatus()==Ok,"natural canvas");require(result->SetResolution(96,96)==Ok,"natural resolution");{Graphics g(result.get());require(g.Clear(Color(0,0,0,0))==Ok,"natural clear");g.SetInterpolationMode(InterpolationModeDefault);g.SetPixelOffsetMode(PixelOffsetModeHighQuality);g.SetPixelOffsetMode(PixelOffsetModeHalf);ImageAttributes a;a.SetWrapMode(WrapModeTileFlipXY);draw=g.DrawImage(&image,Rect(0,0,w,h),0,0,w,h,UnitPixel,&a);}return result;}
static Bytes target(Bitmap& image,const Spec& s,int& errors){Bytes b;errors=0;for(int y=0;y<s.dh;y++)for(int x=0;x<s.dw;x++){Color c;if(image.GetPixel(s.x+x,s.y+y,&c)!=Ok)errors++;b.insert(b.end(),{c.GetR(),c.GetG(),c.GetB(),c.GetA()});}return b;}
static int differences(const Bytes& a,const Bytes& b){if(a.size()!=b.size())return -1;int n=0;for(size_t i=0;i<a.size();i++)if(a[i]!=b[i])n++;return n;}
struct Input{Spec spec;Parsed parsed;Bytes background;std::string control;bool accepted=false;};
static Input prepare(const fs::path& folder,const fs::path& out,const Spec& s){Input r;r.spec=s;auto bytes=read(folder/s.file);r.parsed=parse(bytes,s);write(out/s.file,bytes);Bitmap diagnostic((folder/s.file).c_str(),FALSE);Status constructor=diagnostic.GetLastStatus();Bitmap image((folder/s.file).c_str(),FALSE);GUID format{};Status raw=image.GetRawFormat(&format),load=image.GetLastStatus();require(load==Ok&&raw==Ok&&image.GetWidth()==UINT(s.width)&&image.GetHeight()==UINT(s.height),"retained WMF load");Status draw;auto final=natural(image,draw);int errors=0,intrinsicErrors=0;auto rgba=target(*final,s,errors),intrinsic=target(image,s,intrinsicErrors);bool retainedAccepted=draw==Ok&&errors==0&&intrinsicErrors==0&&rgba==s.expected;r.accepted=retainedAccepted;
 auto beforePath=out/(s.name+"-prepaint.wmf");write(beforePath,prepaint(bytes,r.parsed));Bitmap before(beforePath.c_str(),FALSE);GUID beforeFormat{};Status beforeRaw=before.GetRawFormat(&beforeFormat),beforeLoad=before.GetLastStatus();require(beforeRaw==Ok&&beforeLoad==Ok&&before.GetWidth()==UINT(s.width)&&before.GetHeight()==UINT(s.height),"prepaint load");Status beforeDraw;auto background=natural(before,beforeDraw);require(beforeDraw==Ok,"prepaint draw");for(int y=0;y<s.height;y++)for(int x=0;x<s.width;x++){Color c;require(background->GetPixel(x,y,&c)==Ok,"prepaint pixel");r.background.insert(r.background.end(),{c.GetR(),c.GetG(),c.GetB(),c.GetA()});}int beforeErrors=0;auto beforeTarget=target(*background,s,beforeErrors);require(beforeErrors==0,"prepaint target");bool prepaintAccepted=beforeTarget==s.expectedPrepaint;Bytes evidenceRGBA;int evidenceErrors=0;for(const auto& point:s.evidence){Color c;if(final->GetPixel(point.X,point.Y,&c)!=Ok)evidenceErrors++;evidenceRGBA.insert(evidenceRGBA.end(),{c.GetR(),c.GetG(),c.GetB(),c.GetA()});}bool evidenceAccepted=evidenceErrors==0&&evidenceRGBA==s.expectedEvidence;r.accepted=r.accepted&&prepaintAccepted&&evidenceAccepted;
 std::ostringstream o;o<<"{\"name\":\""<<s.name<<"\",\"inputSHA256\":\""<<s.sha<<"\",\"retainedSourceRun\":\""<<s.run<<"\",\"retainedSourceCommit\":\""<<s.commit<<"\",\"canvas\":["<<s.width<<","<<s.height<<"],\"sourceBitmap\":["<<r.parsed.sw<<","<<r.parsed.sh<<"],\"sourceStride\":"<<r.parsed.stride<<",\"sourceBGRXHex\":\""<<hex(r.parsed.bgrx)<<"\",\"decodedOpaqueRGBAHex\":\""<<hex(r.parsed.rgba)<<"\",\"sourceXBytePolicy\":\"reserved, not alpha; direct variants use opaque RGB from identical BGRX bytes\",\"destinationDeviceRect\":["<<s.x<<","<<s.y<<","<<s.dw<<","<<s.dh<<"],\"windowOrigin\":["<<r.parsed.wx<<","<<r.parsed.wy<<"],\"windowExtent\":["<<r.parsed.ww<<","<<r.parsed.wh<<"],\"viewportOrigin\":["<<r.parsed.vx<<","<<r.parsed.vy<<"],\"viewportExtent\":["<<r.parsed.vw<<","<<r.parsed.vh<<"],\"viewportExplicit\":"<<(r.parsed.viewportExplicit?"true":"false")<<",\"constructorDiagnosticStatus\":"<<constructor<<",\"rawFormatStatus\":"<<raw<<",\"loadStatusAfterRawFormat\":"<<load<<",\"drawStatus\":"<<draw<<",\"targetReadErrors\":"<<errors<<",\"intrinsicTargetReadErrors\":"<<intrinsicErrors<<",\"targetRGBAHex\":\""<<hex(rgba)<<"\",\"intrinsicTargetRGBAHex\":\""<<hex(intrinsic)<<"\",\"intrinsicNaturalTargetDifferences\":"<<differences(intrinsic,rgba)<<",\"prepaintTargetRGBAHex\":\""<<hex(beforeTarget)<<"\",\"prepaintExpectedRGBAHex\":\""<<hex(s.expectedPrepaint)<<"\",\"prepaintTargetPassed\":"<<(prepaintAccepted?"true":"false")<<",\"backgroundEvidencePoints\":\""<<s.evidencePoints<<"\",\"backgroundEvidenceRGBAHex\":\""<<hex(evidenceRGBA)<<"\",\"backgroundEvidenceReadErrors\":"<<evidenceErrors<<",\"backgroundEvidenceRawSHA256\":\""<<s.evidenceRawSHA<<"\",\"backgroundEvidencePassed\":"<<(evidenceAccepted?"true":"false")<<",\"retainedTargetPassed\":"<<(retainedAccepted?"true":"false")<<"}";r.control=o.str();return r;}
static Bytes record(WORD type,std::initializer_list<int> values){Bytes b(6+values.size()*2);set32(b,0,DWORD(b.size()/2));set16(b,4,type);size_t at=6;for(int v:values){set16(b,at,unsigned(v));at+=2;}return b;}
static void repair(Bytes& b){set32(b,28,DWORD((b.size()-22)/2));size_t at=40,maximum=0;while(at<b.size()){DWORD words=u32(b,at);require(words>=3&&words<=(b.size()-at)/2,"derived record framing");maximum=std::max(maximum,size_t(words));at+=size_t(words)*2;}require(at==b.size(),"derived complete framing");set32(b,34,DWORD(maximum));WORD sum=0;for(size_t p=0;p<20;p+=2)sum^=u16(b,p);set16(b,20,sum);}
struct Mutation{const char* name;int sx,sy,sw,sh,dx,dy,dw,dh;int q=0;};
static std::vector<Mutation> mutations(const Bytes& wire,const Parsed& p){const size_t a=p.blitStart;int sx=s16(wire,a+16),sy=s16(wire,a+14),sw=s16(wire,a+12),sh=s16(wire,a+10),dx=s16(wire,a+24),dy=s16(wire,a+22),dw=s16(wire,a+20),dh=s16(wire,a+18);
 return {
 {"src-x-negative-zero-anchor",0,sy,-sw,sh,dx,dy,dw,dh},
 {"src-x-negative-inclusive-anchor",sw-1,sy,-sw,sh,dx,dy,dw,dh},
 {"src-x-negative-edge-anchor",sw,sy,-sw,sh,dx,dy,dw,dh},
 {"dst-x-negative-original-anchor",sx,sy,sw,sh,dx,dy,-dw,dh},
 {"dst-x-negative-edge-anchor",sx,sy,sw,sh,dx+dw,dy,-dw,dh},
 {"both-x-negative-edge-anchors",sw,sy,-sw,sh,dx+dw,dy,-dw,dh},
 {"src-y-negative-edge-anchor",sx,sh,sw,-sh,dx,dy,dw,dh},
 {"src-y-negative-inclusive-anchor",sx,sh-1,sw,-sh,dx,dy,dw,dh},
 {"dst-y-negative-edge-anchor",sx,sy,sw,sh,dx,dy+dh,dw,-dh},
 {"both-y-negative-edge-anchors",sx,sh,sw,-sh,dx,dy+dh,dw,-dh},
 {"both-xy-negative-edge-anchors",sw,sh,-sw,-sh,dx+dw,dy+dh,-dw,-dh},
 {"dst-offcanvas-minus-one",sx,sy,sw,sh,-p.ww/p.vw,-p.wh/p.vh,dw,dh},
 {"dst-plus-quarter-xy",sx,sy,sw,sh,dx,dy,dw,dh,1},
 {"dst-minus-quarter-xy",sx,sy,sw,sh,dx,dy,dw,dh,-1},
 {"src-outside-minus-one-xy",-1,-1,sw,sh,dx,dy,dw,dh},
 {"src-outside-plus-one-xy",1,1,sw,sh,dx,dy,dw,dh}
 };
}
static Bytes mutate(const Bytes& original,const Parsed& p,const Mutation& m){
 require(p.ww%p.vw==0&&p.wh%p.vh==0,"quarter mutation requires exact integral original mapping");
 Bytes b=original;const size_t a=p.blitStart;for(auto pair:{std::pair<size_t,int>{10,m.sh},{12,m.sw},{14,m.sy},{16,m.sx},{18,m.dh*4},{20,m.dw*4},{22,m.dy*4+m.q*(p.wh/p.vh)},{24,m.dx*4+m.q*(p.ww/p.vw)}}){require(pair.second>=-32768&&pair.second<=32767,"derived signed coordinate");set16(b,a+pair.first,unsigned(pair.second));}
 // Insert equivalent quarter-resolution mapping immediately before the one
 // selected blit. Every original prepaint command and Bitmap16 byte survives.
 Bytes mapping;for(const auto& r:{record(META_SETWINDOWORG,{p.wy*4,p.wx*4}),record(META_SETWINDOWEXT,{p.wh*4,p.ww*4}),record(META_SETVIEWPORTORG,{p.vy,p.vx}),record(META_SETVIEWPORTEXT,{p.vh,p.vw})})mapping.insert(mapping.end(),r.begin(),r.end());b.insert(b.begin()+a,mapping.begin(),mapping.end());repair(b);require(std::equal(original.begin()+40,original.begin()+a,b.begin()+40),"original prepaint changed");require(std::equal(original.begin()+a+26,original.end(),b.begin()+a+mapping.size()+26),"original Bitmap16 pixels/header or EOF changed");return b;
}
static void budget(const fs::path& folder){uintmax_t bytes=0;for(const auto& f:fs::directory_iterator(folder))if(f.is_regular_file())bytes+=f.file_size();require(bytes<=10*1024*1024,"geometry output exceeds10MiB");}
static std::string capture(const fs::path& wire,const fs::path& out,const std::string& name,const std::string& input,const std::string& mutation){
 Bitmap diagnostic(wire.c_str(),FALSE);Status constructor=diagnostic.GetLastStatus();Bitmap image(wire.c_str(),FALSE);GUID format{};Status rawStatus=image.GetRawFormat(&format),load=image.GetLastStatus();UINT w=load==Ok?image.GetWidth():0,h=load==Ok?image.GetHeight():0;Status draw=GenericError;int intrinsicErrors=0,naturalErrors=0,rgbaDifferences=0;size_t intrinsicInk=0,naturalInk=0;Bytes intrinsic,naturalRGBA;
 if(load==Ok&&rawStatus==Ok){require(w>0&&h>0&&w<=240&&h<=160,"full-frame canvas budget");auto rendered=natural(image,draw);for(UINT y=0;y<h;y++)for(UINT x=0;x<w;x++){Color a,b;if(image.GetPixel(x,y,&a)!=Ok)intrinsicErrors++;if(rendered->GetPixel(x,y,&b)!=Ok)naturalErrors++;intrinsic.insert(intrinsic.end(),{a.GetR(),a.GetG(),a.GetB(),a.GetA()});naturalRGBA.insert(naturalRGBA.end(),{b.GetR(),b.GetG(),b.GetB(),b.GetA()});intrinsicInk+=a.GetA()!=0;naturalInk+=b.GetA()!=0;}rgbaDifferences=differences(intrinsic,naturalRGBA);write(out/(name+"-intrinsic.rgba"),intrinsic);write(out/(name+"-natural.rgba"),naturalRGBA);}
 std::ostringstream o;o<<"{\"name\":\""<<name<<"\",\"input\":\""<<input<<"\",\"mutation\":\""<<mutation<<"\",\"wire\":\""<<wire.filename().string()<<"\",\"constructorDiagnosticStatus\":"<<constructor<<",\"rawFormatStatus\":"<<rawStatus<<",\"loadStatusAfterRawFormat\":"<<load<<",\"width\":"<<w<<",\"height\":"<<h<<",\"naturalDrawStatus\":"<<draw<<",\"intrinsicGetPixelErrors\":"<<intrinsicErrors<<",\"naturalGetPixelErrors\":"<<naturalErrors<<",\"intrinsicNaturalRGBADifferences\":"<<rgbaDifferences<<",\"intrinsicNonzeroAlphaPixels\":"<<intrinsicInk<<",\"naturalNonzeroAlphaPixels\":"<<naturalInk<<",\"intrinsicRGBA\":\""<<name<<"-intrinsic.rgba\",\"naturalRGBA\":\""<<name<<"-natural.rgba\",\"capturedBytes\":"<<intrinsic.size()+naturalRGBA.size()<<"}";budget(out);return o.str();
}
int main(int argc,char** argv){if(argc!=3)return 2;ULONG_PTR token=0;GdiplusStartupInput startup;if(GdiplusStartup(&token,&startup,nullptr)!=Ok)return 3;fs::path folder=argv[1],out=argv[2];std::vector<std::string> controls,captures;bool controlsPassed=false;int result=0;std::string failure;
 try{require(!fs::exists(out)||fs::is_empty(out),"output directory must be fresh");fs::create_directories(out);auto manifest=specs(folder);std::vector<Input> prepared;for(const auto& s:manifest){auto input=prepare(folder,out,s);controls.push_back(input.control);prepared.push_back(std::move(input));}controlsPassed=std::all_of(prepared.begin(),prepared.end(),[](const Input& input){return input.accepted;});require(controlsPassed,"positive retained target/background control failed before mutations");
 for(const auto& input:prepared)captures.push_back(capture(out/input.spec.file,out,input.spec.name,input.spec.name,"unchanged-retained-control"));
 // Historical integer-box wire is observed unchanged, without assuming the
 // obsolete DIB comparison had the same Windows HALFTONE pixels.
 auto historical=read(folder/"integer-box.wmf");write(out/"integer-box.wmf",historical);captures.push_back(capture(out/"integer-box.wmf",out,"integer-box","integer-box","unchanged-historical-fixture"));
 size_t count=0;for(const auto& input:prepared)if(input.spec.name=="b33"||input.spec.name=="b310"||input.spec.name=="continuity"){auto original=read(folder/input.spec.file);auto matrix=mutations(original,input.parsed);require(matrix.size()==16,"per-input mutation inventory");for(const auto& mutation:matrix){std::string name=input.spec.name+"-"+mutation.name;auto bytes=mutate(original,input.parsed,mutation);write(out/(name+".wmf"),bytes);captures.push_back(capture(out/(name+".wmf"),out,name,input.spec.name,mutation.name));count++;}}require(count==48&&captures.size()==55,"full geometry observation inventory");budget(out);
 }catch(const std::exception& error){failure=error.what();std::cerr<<failure<<"\n";result=1;}
 if(fs::exists(out)){std::ofstream report(out/"geometry-observations.json");report<<"{\"schema\":1,\"purpose\":\"independent whole-frame signed/source-boundary geometry observation; no target bounding-box or sampling prediction asserted\",\"requestedRetainedControls\":6,\"requestedDerivedCases\":48,\"requestedHistoricalCases\":1,\"allRetainedTargetsPassed\":"<<(controlsPassed?"true":"false")<<",\"failure\":\""<<failure<<"\",\"controls\":[";for(size_t i=0;i<controls.size();i++){if(i)report<<",";report<<controls[i];}report<<"],\"captures\":[";for(size_t i=0;i<captures.size();i++){if(i)report<<",";report<<captures[i];}report<<"],\"capturedCaseCount\":"<<captures.size()<<"}";report.close();if(!report)result=1;try{budget(out);}catch(...){result=1;}}
 GdiplusShutdown(token);return result;
}
