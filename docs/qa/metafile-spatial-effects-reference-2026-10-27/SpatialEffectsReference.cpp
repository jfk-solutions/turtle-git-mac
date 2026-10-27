// Original SDK observations only. Reuse utility infrastructure, never its case inventory.
#define main unusedPointwiseReferenceMain
#include "../metafile-pointwise-effects-reference-2026-10-27/PointwiseEffectsReference.cpp"
#undef main
#include <cmath>
#include <sstream>
#include <cstring>

struct SpatialCase {
    std::string name, family, atlasName;
    REAL radius=0, amount=0;
    BOOL expand=FALSE;
    std::vector<RECT> areas;
    bool padded=false;
    bool cropped=false;
    void describe(std::ostream& out) const {
        out << ",\"source\":" << json(name) << ",\"family\":" << json(family)
            << ",\"atlas\":" << json(atlasName) << ",\"emf\":" << json(name+".emf")
            << ",\"parameters\":{";
        if(family=="redEyeCorrection") {
            out << "\"numberOfAreas\":" << areas.size() << ",\"areas\":[";
            bool first=true;for(const auto& r:areas){if(!first)out<<',';first=false;out<<'['<<r.left<<','<<r.top<<','<<r.right<<','<<r.bottom<<']';}out<<']';
        } else {out << "\"radius\":" << radius;if(family=="blur")out<<",\"expandEdge\":"<<(expand?"true":"false");else out<<",\"amount\":"<<amount;}
        out << "},\"paddedRecording\":" << (padded?"true":"false") << ",\"croppedScaledRecording\":" << (cropped?"true":"false");
    }
};
static UINT sourceWidth(const std::string& name){return name=="strip-impulse"||name=="strip-constant"?513:32;}
static UINT sourceHeight(const std::string& name){return name=="strip-impulse"||name=="strip-constant"?17:32;}
static Color spatialColor(const std::string& name,UINT x,UINT y) {
    if(name=="strip-constant")return Color(255,71,139,213);
    if(name=="strip-impulse")return Color(255,x==256?255:0,x==2?255:0,x==510?255:0);
    if(name=="impulse")return Color(255,x==15&&y==16?255:0,x==2&&y==3?255:0,x==31&&y==0?255:0);
    if(name=="step")return Color(255,x<16?0:255,y<11?31:223,(x+y)<23?240:17);
    if(name=="constant")return Color(255,71,139,213);
    if(name=="asymmetric")return Color(255,BYTE(11*x+53*y),BYTE(43*x+7*y),BYTE(19*x+37*y));
    if(name=="alpha") {
        static constexpr BYTE levels[]={0,1,2,3,7,15,31,63,127,128,191,254,255};
        return Color(levels[(x/3+y/7)%13],BYTE(17*x+3*y),BYTE(5*x+29*y),BYTE(251-7*x+11*y));
    }
    if(name=="eye") {
        // Left: solid red square on gray. Right: red disk on a skin-like surround.
        // Bottom: isolated and 2/4/8-pixel red disks; alpha bands cross active red.
        BYTE r=180,g=145,b=120,a=255;
        if(y<16&&x<16){r=g=b=96;if(x>=4&&x<12&&y>=4&&y<12){r=240;g=20;b=10;}}
        else if(y<16){int dx=int(x)-24,dy=int(y)-8;if(dx*dx+dy*dy<=25){r=240;g=10;b=20;}}
        else {int cell=int(x)/8,dx=int(x)%8-4,dy=int(y)%8-4;int radius=cell;bool red=cell==0?(dx==0&&dy==0):(dx*dx+dy*dy<=radius*radius);if(red){r=255;g=15;b=7;static constexpr BYTE alphas[]={0,1,127,254,255};a=alphas[(std::min)(UINT(4),(y-16)/3)];}}
        return Color(a,r,g,b);
    }
    if(name=="redeye-swapped"){Color c=spatialColor("redeye",x,y);return Color(c.GetA(),c.GetR(),c.GetB(),c.GetG());}
    // Threshold lattice with independent R/G/B and paired alpha rows. No guessed classification.
    static constexpr BYTE values[]={0,15,31,63,95,127,128,159,191,223,239,254,255};
    UINT i=x+32*(y%16);
    BYTE r=values[i%13],g=values[(i/13)%13],b=values[(i/169)%13];
    return Color(y<16?255:BYTE((x%4)*85),r,g,b);
}
static std::unique_ptr<Bitmap> spatialAtlas(const std::string& name) {
    auto image=std::make_unique<Bitmap>(sourceWidth(name),sourceHeight(name),PixelFormat32bppARGB);
    check(image->GetLastStatus(),"source allocation");check(image->SetResolution(96,96),"source DPI");
    for(UINT y=0;y<sourceHeight(name);++y)for(UINT x=0;x<sourceWidth(name);++x)check(image->SetPixel(x,y,spatialColor(name,x,y)),"source pixel");
    return image;
}
static void spatialPixels(Bitmap& image,const fs::path& dir,const std::string& name,std::ostream& out) {
    const UINT w=image.GetWidth(),h=image.GetHeight();check(image.GetLastStatus(),"pixel dimensions");
    if(!w||!h||w>1024||h>1024)throw std::runtime_error("spatial dimensions exceed1024 bound");
    check(image.Save((dir/(name+".png")).c_str(),&pngEncoder,nullptr),"save PNG");
    auto bytes=file(dir/(name+".rgba"),true);
    for(UINT y=0;y<h;++y)for(UINT x=0;x<w;++x){Color c;check(image.GetPixel(x,y,&c),"read pixel");BYTE p[]={c.GetR(),c.GetG(),c.GetB(),c.GetA()};bytes.write(reinterpret_cast<const char*>(p),4);}
    out<<",\"width\":"<<w<<",\"height\":"<<h<<",\"rgba\":"<<json(name+".rgba")<<",\"png\":"<<json(name+".png");
}
static std::vector<SpatialCase> spatialCases() {
    std::vector<SpatialCase> result;
    const REAL radii[]={0,.1f,.25f,.5f,1,1.5f,2,3,5,10,255};
    for(const auto& atlasName:{"impulse","step","constant","asymmetric","alpha"})for(UINT ri=0;ri<11;++ri) {
        for(BOOL expand:{FALSE,TRUE})result.push_back({std::string("blur-")+atlasName+"-r"+std::to_string(ri)+"-e"+std::to_string(expand),"blur",atlasName,radii[ri],0,expand,{},false});
        for(REAL amount:{0.f,25.f,50.f,100.f})result.push_back({std::string("sharpen-")+atlasName+"-r"+std::to_string(ri)+"-a"+std::to_string(int(amount)),"sharpen",atlasName,radii[ri],amount,FALSE,{},false});
    }
    // Padded native frames distinguish expanded DrawImage output from fixed-frame clipping.
    for(REAL radius:{.25f,1.f,2.f,5.f,255.f})result.push_back({"blur-alpha-expanded-"+std::to_string(int(radius*100)),"blur","alpha",radius,0,TRUE,{},true});
    const std::vector<std::vector<RECT>> regions={
        {},{{0,0,32,32}},{{0,0,16,32}},{{16,0,32,32}},{{3,5,27,21}},
        {{0,0,1,1}},{{31,31,32,32}},{{5,5,5,9}},{{5,5,9,5}},{{9,9,5,5}},
        {{-5,-3,12,17}},{{20,19,40,45}},{{-20,-20,-1,-1}},{{40,40,50,50}},
        {{0,0,24,24},{8,8,32,32}},{{8,8,32,32},{0,0,24,24}},
        {{0,0,32,32},{0,0,32,32}},{{1,1,15,15},{17,17,31,31}}
    };
    for(const auto& name:{"redeye","redeye-swapped","eye"})for(UINT i=0;i<regions.size();++i)result.push_back({std::string(name)+"-"+std::to_string(i),"redEyeCorrection",name,0,0,FALSE,regions[i],false});
    result.push_back({"blur-asymmetric-crop-scale","blur","asymmetric",2,0,TRUE,{},true,true});
    for(const auto& name:{"strip-impulse","strip-constant"})for(REAL radius:{1.f,1.5f,3.f,10.f,255.f})for(BOOL expand:{FALSE,TRUE})
        result.push_back({std::string("blur-")+name+"-r"+std::to_string(int(radius*100))+"-e"+std::to_string(expand),"blur",name,radius,0,expand,{},bool(expand),false});
    if(result.size()!=410)throw std::runtime_error("spatial inventory changed");
    return result;
}
template<class Body> static void spatialEffect(const SpatialCase& item,Body&& body) {
    if(item.family=="blur"){BlurParams p{item.radius,item.expand};Blur effect;body(effect,effect.SetParameters(&p));}
    else if(item.family=="sharpen"){SharpenParams p{item.radius,item.amount};Sharpen effect;body(effect,effect.SetParameters(&p));}
    else {
        auto areas=item.areas;
        // SDK wrapper passes struct-size + N*RECT bytes despite its pointer member.
        // Keep BOTH pointed areas and trailing readable storage alive for the call.
        const size_t size=sizeof(RedEyeCorrectionParams)+areas.size()*sizeof(RECT);
        auto storage=std::make_unique<BYTE[]>(size);std::memset(storage.get(),0,size);
        auto* p=new(storage.get()) RedEyeCorrectionParams{UINT(areas.size()),areas.empty()?nullptr:areas.data()};
        if(!areas.empty())std::memcpy(storage.get()+sizeof(RedEyeCorrectionParams),areas.data(),areas.size()*sizeof(RECT));
        RedEyeCorrection effect;body(effect,effect.SetParameters(p));
    }
}
static void spatialAux(Effect& effect,const fs::path& dir,const std::string& stem,std::ostream& out) {
    UINT count=effect.GetAuxDataSize();out<<",\"auxBytes\":"<<count;
    if(count>1024*1024)throw std::runtime_error("auxiliary data exceeds bound");
    if(count&&effect.GetAuxData()){auto bytes=file(dir/(stem+".aux"),true);bytes.write(static_cast<const char*>(effect.GetAuxData()),count);out<<",\"aux\":"<<json(stem+".aux");}
}
static int margin(const SpatialCase& item){return item.cropped?16:(item.padded?int(std::ceil(item.radius)):0);}
static void spatialRecord(const SpatialCase& item,Effect& effect,const fs::path& dir,std::ostream& out) {
    const int pad=margin(item),width=item.cropped?96:int(sourceWidth(item.atlasName))+2*pad,height=item.cropped?96:int(sourceHeight(item.atlasName))+2*pad;ScreenDC screen;
    Metafile emf((dir/(item.name+".emf")).c_str(),screen.value,RectF(0,0,REAL(width),REAL(height)),MetafileFrameUnitPixel,EmfTypeEmfPlusOnly,L"Original SDK spatial reference");
    auto status=emf.GetLastStatus();out<<",\"recordCreateStatus\":"<<status;if(status!=Ok)return;
    Graphics g(&emf);check(g.GetLastStatus(),"record graphics");check(g.SetPageUnit(UnitPixel),"record units");check(g.SetCompositingMode(CompositingModeSourceCopy),"record compositing");check(g.Clear(Color(0,0,0,0)),"record clear");
    auto input=spatialAtlas(item.atlasName);RectF source=item.cropped?RectF(4,6,17,19):RectF(0,0,REAL(sourceWidth(item.atlasName)),REAL(sourceHeight(item.atlasName)));Matrix transform(item.cropped?2.f:1.f,0,0,item.cropped?1.5f:1.f,REAL(pad),REAL(pad));check(transform.GetLastStatus(),"record placement");
    status=g.DrawImage(input.get(),&source,&transform,&effect,nullptr,UnitPixel);
    out<<",\"recordStatus\":"<<status<<",\"recordFrameWidth\":"<<width<<",\"recordFrameHeight\":"<<height<<",\"sourceOrigin\":["<<pad<<','<<pad<<"],\"sourceRect\":"<<(item.cropped?"[4,6,17,19]":("[0,0,"+std::to_string(sourceWidth(item.atlasName))+","+std::to_string(sourceHeight(item.atlasName))+"]"))<<",\"imageTransform\":["<<(item.cropped?"2,0,0,1.5":"1,0,0,1")<<','<<pad<<','<<pad<<']';
}
static void spatialDirect(const SpatialCase& item,Effect& effect,const fs::path& dir,const std::string& prefix,bool create,std::ostream& out) {
    auto input=spatialAtlas(item.atlasName);effect.UseAuxData(TRUE);
    if(!create){auto status=input->ApplyEffect(&effect,nullptr);out<<",\"applyStatus\":"<<status;spatialAux(effect,dir,prefix+item.name,out);if(status==Ok)spatialPixels(*input,dir,prefix+item.name,out);}
    else {Bitmap* rawInput=input.get();Bitmap* rawOutput=nullptr;RECT outputRect{};
        auto status=Bitmap::ApplyEffect(&rawInput,1,&effect,nullptr,&outputRect,&rawOutput);
        std::unique_ptr<Bitmap> output(rawOutput);out<<",\"applyStatus\":"<<status<<",\"outputRect\":["<<outputRect.left<<','<<outputRect.top<<','<<outputRect.right<<','<<outputRect.bottom<<']';
        spatialAux(effect,dir,prefix+item.name,out);if(status==Ok){if(!output)throw std::runtime_error("successful create returned null");spatialPixels(*output,dir,prefix+item.name,out);}}
}
static void spatialReplay(const SpatialCase& item,const fs::path& dir,const std::string& prefix,std::ostream& out) {
    Bitmap image((dir/(item.name+".emf")).c_str(),FALSE);auto status=image.GetLastStatus();out<<",\"bitmapLoadStatus\":"<<status;if(status!=Ok)return;
    UINT w=image.GetWidth(),h=image.GetHeight();check(image.GetLastStatus(),"intrinsic dimensions");const UINT expectedW=item.cropped?96:sourceWidth(item.atlasName)+2*margin(item),expectedH=item.cropped?96:sourceHeight(item.atlasName)+2*margin(item);
    out<<",\"intrinsicWidth\":"<<w<<",\"intrinsicHeight\":"<<h<<",\"expectedSize\":"<<(w==expectedW&&h==expectedH?"true":"false")<<",\"intrinsic\":{\"name\":"<<json(prefix+item.name+"-intrinsic");
    spatialPixels(image,dir,prefix+item.name+"-intrinsic",out);out<<'}';
    Bitmap output(w,h,PixelFormat32bppARGB);check(output.GetLastStatus(),"replay allocation");check(output.SetResolution(96,96),"replay DPI");
    {Graphics g(&output);check(g.Clear(Color(0,0,0,0)),"replay clear");check(g.SetCompositingMode(CompositingModeSourceCopy),"replay compositing");check(g.SetInterpolationMode(InterpolationModeDefault),"Picture interpolation");check(g.SetPixelOffsetMode(PixelOffsetModeHalf),"Picture pixel offset");ImageAttributes a;check(a.SetWrapMode(WrapModeTileFlipXY),"Picture wrap");status=g.DrawImage(&image,Rect(0,0,INT(w),INT(h)),0,0,INT(w),INT(h),UnitPixel,&a);}
    out<<",\"drawStatus\":"<<status;if(status==Ok)spatialPixels(output,dir,prefix+item.name,out);
}
int main(int argc,char** argv) {
    if(argc!=3)return 2;
    try {
        const std::string mode=argv[1];if(mode!="generate"&&mode!="direct-v1"&&mode!="replay"&&mode!="replay-v1")return 2;
        const bool v1=mode=="direct-v1"||mode=="replay-v1";Startup startup(v1?1:2);findPNGEncoder();const fs::path dir=fs::absolute(argv[2]);fs::create_directories(dir);
        const auto inventory=spatialCases();auto out=file(dir/(mode+".json"));wchar_t path[32768]{};DWORD n=GetModuleFileNameW(GetModuleHandleW(L"gdiplus.dll"),path,32768);if(!n||n>=32768)throw std::runtime_error("cannot identify GDI+");
        out<<"{\"platform\":\"native Windows GDI+\",\"startupVersion\":"<<(v1?1:2)<<",\"gdiplusModule\":"<<json(fs::path(path).u8string())<<",\"mode\":"<<json(mode)<<",\"caseCount\":"<<inventory.size()<<",\"format\":\"straight RGBA row-major top-left\",\"atlases\":[";
        bool first=true;for(const auto& name:{"impulse","step","constant","asymmetric","alpha","redeye","redeye-swapped","eye","strip-impulse","strip-constant"}){if(!first)out<<',';first=false;out<<"{\"name\":"<<json(name)<<",\"sourceWidth\":"<<sourceWidth(name)<<",\"sourceHeight\":"<<sourceHeight(name)<<",\"requestedRGBA\":"<<json(std::string("atlas-")+name+"-requested.rgba");if(mode=="generate"){auto image=spatialAtlas(name);spatialPixels(*image,dir,std::string("atlas-")+name,out);auto requested=file(dir/(std::string("atlas-")+name+"-requested.rgba"),true);for(UINT y=0;y<sourceHeight(name);++y)for(UINT x=0;x<sourceWidth(name);++x){auto c=spatialColor(name,x,y);BYTE p[]={c.GetR(),c.GetG(),c.GetB(),c.GetA()};requested.write(reinterpret_cast<const char*>(p),4);}}out<<'}';}out<<"],\"cases\":[";
        first=true;bool internalFailure=false;
        for(const auto& item:inventory){if(!first)out<<',';first=false;std::string prefix=mode=="generate"?"":mode+"-";out<<"{\"name\":"<<json(prefix+item.name);item.describe(out);
            std::ostringstream detail;try {if(mode=="generate"||mode=="direct-v1"){
                if(mode=="generate")spatialEffect(item,[&](auto& effect,Status s){detail<<",\"recordSetParametersStatus\":"<<s;if(s==Ok)spatialRecord(item,effect,dir,detail);});
                detail<<",\"direct\":{\"name\":"<<json(prefix+item.name);spatialEffect(item,[&](auto& effect,Status s){detail<<",\"setParametersStatus\":"<<s;if(s==Ok)spatialDirect(item,effect,dir,prefix,false,detail);});detail<<'}';
                detail<<",\"created\":{\"name\":"<<json(prefix+"created-"+item.name);spatialEffect(item,[&](auto& effect,Status s){detail<<",\"setParametersStatus\":"<<s;if(s==Ok)spatialDirect(item,effect,dir,prefix+"created-",true,detail);});detail<<'}';
            }else spatialReplay(item,dir,prefix,detail);
            }catch(const std::exception& error){detail.str("");detail.clear();detail<<",\"error\":"<<json(error.what());internalFailure=true;}
            out<<detail.str();
            out<<'}';out.flush();}
        out<<"]}\n";out.close();return internalFailure?1:0;
    }catch(const std::exception& error){std::cerr<<error.what()<<'\n';return 1;}
}
