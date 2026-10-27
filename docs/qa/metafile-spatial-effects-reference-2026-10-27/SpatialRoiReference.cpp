// Twelve independent ROI observations; no earlier corpus recapture.
#define main unusedPointwiseReferenceMain
#include "../metafile-pointwise-effects-reference-2026-10-27/PointwiseEffectsReference.cpp"
#undef main
#include <sstream>
struct CoefficientCase {
    std::string name;REAL x,y,w,h;bool expand;
    int width=32,height=32;
    RECT roi()const{return RECT{LONG(std::floor(x)),LONG(std::floor(y)),LONG(std::ceil(x+w)+1),LONG(std::ceil(y+h)+1)};}
    void describe(std::ostream& out)const {
        auto r=roi();out<<",\"source\":\"asymmetric\",\"family\":\"blur\",\"emf\":"<<json(name+".emf")<<",\"sourceWidth\":32,\"sourceHeight\":32,\"parameters\":{\"radius\":2,\"expandEdge\":"<<(expand?"true":"false")<<"},\"recordSourceRect\":["<<x<<','<<y<<','<<w<<','<<h<<"],\"recordImageMatrix\":[1,0,0,1,16,16],\"recordFrameWidth\":64,\"recordFrameHeight\":64,\"directROI\":["<<r.left<<','<<r.top<<','<<r.right<<','<<r.bottom<<"],\"directROIPolicy\":\"floorXY-ceilRightBottomPlusOne; explicit SDK RECT hypothesis, independent of original floating DrawImage sourceRect\"";
    }
};
static std::vector<CoefficientCase> verticalCases(){std::vector<CoefficientCase> result;
    for(bool expand:{false,true}) {
        const std::string suffix=expand?"-e1":"-e0";
        result.push_back({"roi-full"+suffix,0,0,32,32,expand});
        result.push_back({"roi-fractional"+suffix,4.25f,6.5f,17.5f,18.25f,expand});
        result.push_back({"roi-near-origin"+suffix,.25f,.5f,17.5f,18.25f,expand});
        result.push_back({"roi-far-fraction"+suffix,4.75f,6.75f,17.5f,18.25f,expand});
        result.push_back({"roi-integer"+suffix,4,6,17,19,expand});
        result.push_back({"roi-shifted-integer"+suffix,1,1,17,19,expand});
    }return result;
}
static Color boundaryColor(const CoefficientCase&,UINT x,UINT y){return Color(255,BYTE(11*x+53*y),BYTE(43*x+7*y),BYTE(19*x+37*y));}
static std::unique_ptr<Bitmap> boundaryAtlas(const CoefficientCase& c){auto image=std::make_unique<Bitmap>(c.width,c.height,PixelFormat32bppARGB);check(image->GetLastStatus(),"source allocation");check(image->SetResolution(96,96),"source DPI");for(UINT y=0;y<UINT(c.height);++y)for(UINT x=0;x<UINT(c.width);++x)check(image->SetPixel(x,y,boundaryColor(c,x,y)),"source pixel");return image;}
static void verticalPixels(Bitmap& image, const fs::path& dir, const std::string& name, std::ostream& report) {
    UINT width = image.GetWidth(), height = image.GetHeight();
    check(image.GetLastStatus(), "image dimensions");
    if (!width || !height || width > 512 || height > 512) throw std::runtime_error("unexpected image dimensions");
    check(image.Save((dir / (name + ".png")).c_str(), &pngEncoder, nullptr), "save PNG");
    auto out = file(dir / (name + ".rgba"), true);
    for (UINT y = 0; y < height; ++y) for (UINT x = 0; x < width; ++x) {
        Color color; check(image.GetPixel(x,y,&color), "read pixel");
        const BYTE sample[] = {color.GetR(),color.GetG(),color.GetB(),color.GetA()};
        out.write(reinterpret_cast<const char*>(sample), 4);
    }
    report << ",\"width\":" << width << ",\"height\":" << height
           << ",\"rgba\":" << json(name + ".rgba") << ",\"png\":" << json(name + ".png");
}
template<class Body>static void boundaryEffect(const CoefficientCase& c,Body&& body){BlurParams p{2,c.expand?TRUE:FALSE};Blur e;body(e,e.SetParameters(&p));}
static void boundaryAux(Effect& effect,const fs::path& dir,const std::string& stem,std::ostream& out){UINT size=effect.GetAuxDataSize();out<<",\"auxBytes\":"<<size;if(size>1024*1024)throw std::runtime_error("auxiliary bound");if(size&&effect.GetAuxData()){auto data=file(dir/(stem+".aux"),true);data.write(static_cast<const char*>(effect.GetAuxData()),size);out<<",\"aux\":"<<json(stem+".aux");}}
static void boundaryRecord(const CoefficientCase& c,Effect& e,const fs::path& dir,std::ostream& out){ScreenDC screen;Metafile image((dir/(c.name+".emf")).c_str(),screen.value,RectF(0,0,64,64),MetafileFrameUnitPixel,EmfTypeEmfPlusOnly,L"Original SDK source ROI diagnostic");Status s=image.GetLastStatus();out<<",\"recordCreateStatus\":"<<s;if(s!=Ok)return;Graphics g(&image);check(g.GetLastStatus(),"record graphics");check(g.SetPageUnit(UnitPixel),"record units");check(g.SetCompositingMode(CompositingModeSourceCopy),"record compositing");check(g.Clear(Color(0,0,0,0)),"record clear");auto input=boundaryAtlas(c);RectF source(c.x,c.y,c.w,c.h);Matrix transform(1,0,0,1,16,16);check(transform.GetLastStatus(),"record matrix");s=g.DrawImage(input.get(),&source,&transform,&e,nullptr,UnitPixel);out<<",\"recordStatus\":"<<s;}
static void boundaryDirect(const CoefficientCase& c,Effect& effect,const fs::path& dir,const std::string& stem,bool create,std::ostream& out){auto input=boundaryAtlas(c);auto roi=c.roi();effect.UseAuxData(TRUE);if(!create){Status s=input->ApplyEffect(&effect,&roi);out<<",\"applyStatus\":"<<s;boundaryAux(effect,dir,stem,out);if(s==Ok)verticalPixels(*input,dir,stem,out);}else{Bitmap* source=input.get();Bitmap* raw=nullptr;RECT bounds{};Status s=Bitmap::ApplyEffect(&source,1,&effect,&roi,&bounds,&raw);std::unique_ptr<Bitmap> result(raw);out<<",\"applyStatus\":"<<s<<",\"outputRect\":["<<bounds.left<<','<<bounds.top<<','<<bounds.right<<','<<bounds.bottom<<']';boundaryAux(effect,dir,stem,out);if(s==Ok){if(!result)throw std::runtime_error("null successful output");verticalPixels(*result,dir,stem,out);}}}
static void boundaryReplay(const CoefficientCase& c,const fs::path& dir,const std::string& prefix,std::ostream& out){Bitmap image((dir/(c.name+".emf")).c_str(),FALSE);Status s=image.GetLastStatus();out<<",\"bitmapLoadStatus\":"<<s;if(s!=Ok)return;UINT w=image.GetWidth(),h=image.GetHeight();check(image.GetLastStatus(),"intrinsic dimensions");if(!w||!h||w>512||h>512)throw std::runtime_error("replay dimension bound");out<<",\"intrinsicWidth\":"<<w<<",\"intrinsicHeight\":"<<h<<",\"expectedSize\":"<<(w==64&&h==64?"true":"false")<<",\"intrinsic\":{\"name\":"<<json(prefix+c.name+"-intrinsic");verticalPixels(image,dir,prefix+c.name+"-intrinsic",out);out<<'}';Bitmap target(w,h,PixelFormat32bppARGB);check(target.GetLastStatus(),"replay allocation");check(target.SetResolution(96,96),"replay DPI");{Graphics g(&target);check(g.Clear(Color(0,0,0,0)),"replay clear");check(g.SetCompositingMode(CompositingModeSourceCopy),"replay compositing");check(g.SetInterpolationMode(InterpolationModeDefault),"Picture interpolation");check(g.SetPixelOffsetMode(PixelOffsetModeHalf),"Picture pixel offset");ImageAttributes attributes;check(attributes.SetWrapMode(WrapModeTileFlipXY),"Picture wrap");s=g.DrawImage(&image,Rect(0,0,INT(w),INT(h)),0,0,INT(w),INT(h),UnitPixel,&attributes);}out<<",\"drawStatus\":"<<s;if(s==Ok)verticalPixels(target,dir,prefix+c.name,out);}
int main(int argc,char** argv){if(argc!=3)return 2;try{const std::string mode=argv[1];if(mode!="generate"&&mode!="direct-v1"&&mode!="replay"&&mode!="replay-v1")return 2;bool v1=mode=="direct-v1"||mode=="replay-v1";Startup startup(v1?1:2);findPNGEncoder();fs::path dir=fs::absolute(argv[2]);fs::create_directories(dir);auto inventory=verticalCases();if(inventory.size()!=12)throw std::runtime_error("ROI inventory changed");auto out=file(dir/(mode+".json"));wchar_t module[32768]{};DWORD length=GetModuleFileNameW(GetModuleHandleW(L"gdiplus.dll"),module,32768);if(!length||length>=32768)throw std::runtime_error("cannot identify GDI+");out<<"{\"platform\":\"native Windows GDI+\",\"startupVersion\":"<<(v1?1:2)<<",\"gdiplusModule\":"<<json(fs::path(module).u8string())<<",\"mode\":"<<json(mode)<<",\"caseCount\":12,\"format\":\"straight RGBA row-major top-left\",\"atlases\":[";bool first=true;
for(const auto& c:inventory){if(!first)out<<',';first=false;out<<"{\"name\":"<<json(c.name);if(mode=="generate"||mode=="direct-v1"){const std::string inputPrefix=mode=="generate"?"":mode+"-";auto image=boundaryAtlas(c);verticalPixels(*image,dir,inputPrefix+"atlas-"+c.name,out);auto data=file(dir/(inputPrefix+"atlas-"+c.name+"-requested.rgba"),true);for(UINT y=0;y<UINT(c.height);++y)for(UINT x=0;x<UINT(c.width);++x){Color sample=boundaryColor(c,x,y);BYTE p[]={sample.GetR(),sample.GetG(),sample.GetB(),sample.GetA()};data.write(reinterpret_cast<const char*>(p),4);}}out<<'}';}out<<"],\"cases\":[";first=true;bool failed=false;
for(const auto& c:inventory){if(!first)out<<',';first=false;std::string prefix=mode=="generate"?"":mode+"-";out<<"{\"name\":"<<json(prefix+c.name);c.describe(out);std::ostringstream detail;try{if(mode=="generate"||mode=="direct-v1"){if(mode=="generate")boundaryEffect(c,[&](auto& e,Status s){detail<<",\"recordSetParametersStatus\":"<<s;if(s==Ok)boundaryRecord(c,e,dir,detail);});detail<<",\"direct\":{\"name\":"<<json(prefix+c.name);boundaryEffect(c,[&](auto& e,Status s){detail<<",\"setParametersStatus\":"<<s;if(s==Ok)boundaryDirect(c,e,dir,prefix+c.name,false,detail);});detail<<"},\"created\":{\"name\":"<<json(prefix+"created-"+c.name);boundaryEffect(c,[&](auto& e,Status s){detail<<",\"setParametersStatus\":"<<s;if(s==Ok)boundaryDirect(c,e,dir,prefix+"created-"+c.name,true,detail);});detail<<'}';}else boundaryReplay(c,dir,prefix,detail);}catch(const std::exception& error){detail.str("");detail.clear();detail<<",\"error\":"<<json(error.what());failed=true;}out<<detail.str()<<'}';out.flush();}out<<"]}\n";out.close();return failed?1:0;
}catch(const std::exception& error){std::cerr<<error.what()<<'\n';return 1;}}
