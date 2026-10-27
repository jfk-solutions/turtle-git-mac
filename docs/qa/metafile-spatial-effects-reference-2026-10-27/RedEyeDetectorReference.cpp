// Original bounded RedEye general-detector discriminator,43 entirely new cases.
// Requested/actual sources and independent SDK/file-consumer observations only.
#ifndef NOMINMAX
#define NOMINMAX
#endif
#define main unusedPointwiseReferenceMain
#include "../metafile-pointwise-effects-reference-2026-10-27/PointwiseEffectsReference.cpp"
#undef main
#include <cstring>
#include <sstream>

struct DetectorRGBA {BYTE r,g,b,a;};
struct DetectorHole {INT x,y;DetectorRGBA color;};
struct DetectorCase {
    std::string name,group;
    UINT width,height;
    DetectorRGBA background;
    std::vector<RECT> areas;
    std::vector<DetectorHole> holes;
    std::vector<RECT> foreground;
    DetectorRGBA foregroundColor;
    void describe(std::ostream& out)const {
        auto rgba=[&](const DetectorRGBA& c){out<<'['<<int(c.r)<<','<<int(c.g)<<','<<int(c.b)<<','<<int(c.a)<<']';};
        auto rects=[&](const std::vector<RECT>& values){out<<'[';bool first=true;for(const auto& r:values){if(!first)out<<',';first=false;out<<'['<<r.left<<','<<r.top<<','<<r.right<<','<<r.bottom<<']';}out<<']';};
        out<<",\"family\":\"redEyeCorrection\",\"group\":"<<json(group)<<",\"atlas\":"<<json(name)
           <<",\"emf\":"<<json(name+".emf")<<",\"sourceWidth\":"<<width<<",\"sourceHeight\":"<<height
           <<",\"parameters\":{\"numberOfAreas\":"<<areas.size()<<",\"areas\":";rects(areas);out<<'}'
           <<",\"sourceDefinition\":{\"width\":"<<width<<",\"height\":"<<height<<",\"backgroundRGBA\":";rgba(background);
        out<<",\"foregroundRectangles\":";rects(foreground);out<<",\"foregroundRGBA\":";rgba(foregroundColor);
        out<<",\"holes\":[";bool first=true;for(const auto& h:holes){if(!first)out<<',';first=false;out<<'['<<h.x<<','<<h.y<<','<<int(h.color.r)<<','<<int(h.color.g)<<','<<int(h.color.b)<<','<<int(h.color.a)<<']';}out<<"]}"
           <<",\"recordBackgroundRGBA\":[17,61,173,255],\"recordSourceRect\":[0,0,"<<width<<','<<height<<"],\"recordImageMatrix\":[1,0,0,1,0,0]"
           <<",\"recordFrameWidth\":"<<width<<",\"recordFrameHeight\":"<<height;
    }
};
static std::vector<DetectorCase> detectorCases(){return {
    {"scale-16-center","geometry-scale",16,16,{240,20,10,255},{{0,0,16,16}},{{7,7,{96,96,96,255}}},{},{240,20,10,255}},
    {"scale-16-edge","geometry-scale",16,16,{240,20,10,255},{{0,0,16,16}},{{1,7,{96,96,96,255}}},{},{240,20,10,255}},
    {"scale-24-center","geometry-scale",24,24,{240,20,10,255},{{0,0,24,24}},{{11,11,{96,96,96,255}}},{},{240,20,10,255}},
    {"scale-24-edge","geometry-scale",24,24,{240,20,10,255},{{0,0,24,24}},{{2,11,{96,96,96,255}}},{},{240,20,10,255}},
    {"scale-33-center","geometry-scale",33,33,{240,20,10,255},{{0,0,33,33}},{{16,16,{96,96,96,255}}},{},{240,20,10,255}},
    {"scale-33-edge","geometry-scale",33,33,{240,20,10,255},{{0,0,33,33}},{{6,13,{96,96,96,255}}},{},{240,20,10,255}},
    {"roi16-in-source32","roi-scale",32,32,{240,20,10,255},{{8,8,24,24}},{{15,15,{96,96,96,255}}},{},{240,20,10,255}},
    {"partial-roi-glint","roi-scale",32,32,{240,20,10,255},{{-4,-4,20,20}},{{2,9,{96,96,96,255}}},{},{240,20,10,255}},
    {"color-low-red","source-color",32,32,{128,20,10,255},{{0,0,32,32}},{{15,15,{96,96,96,255}}},{},{240,20,10,255}},
    {"color-high-green","source-color",32,32,{240,120,10,255},{{0,0,32,32}},{{15,15,{96,96,96,255}}},{},{240,20,10,255}},
    {"color-high-blue","source-color",32,32,{240,20,120,255},{{0,0,32,32}},{{15,15,{96,96,96,255}}},{},{240,20,10,255}},
    {"color-balanced","source-color",32,32,{120,60,60,255},{{0,0,32,32}},{{15,15,{96,96,96,255}}},{},{240,20,10,255}},
    {"color-pure-red","source-color",32,32,{255,0,0,255},{{0,0,32,32}},{{15,15,{96,96,96,255}}},{},{240,20,10,255}},
    {"color-skin","source-color",32,32,{180,145,120,255},{{0,0,32,32}},{{15,15,{96,96,96,255}}},{},{240,20,10,255}},
    {"neutral-0","neutral-glint-intensity",32,32,{240,20,10,255},{{0,0,32,32}},{{15,15,{0,0,0,255}}},{},{240,20,10,255}},
    {"neutral-255","neutral-glint-intensity",32,32,{240,20,10,255},{{0,0,32,32}},{{15,15,{255,255,255,255}}},{},{240,20,10,255}},
    {"single-9-9","first-min-vs-eligible",32,32,{240,20,10,255},{{0,0,32,32}},{{9,9,{96,96,96,255}}},{},{240,20,10,255}},
    {"far6-near15","first-min-vs-eligible",32,32,{240,20,10,255},{{0,0,32,32}},{{6,6,{96,96,96,255}},{15,15,{96,96,96,255}}},{},{240,20,10,255}},
    {"far4-near15","first-min-vs-eligible",32,32,{240,20,10,255},{{0,0,32,32}},{{4,4,{96,96,96,255}},{15,15,{96,96,96,255}}},{},{240,20,10,255}},
    {"far5-15-near15","first-min-vs-eligible",32,32,{240,20,10,255},{{0,0,32,32}},{{5,15,{96,96,96,255}},{15,15,{96,96,96,255}}},{},{240,20,10,255}},
    {"bright-first-dark-later","first-min-vs-eligible",32,32,{240,20,10,255},{{0,0,32,32}},{{12,12,{192,192,192,255}},{15,15,{64,64,64,255}}},{},{240,20,10,255}},
    {"weak-red-first-neutral-later","first-min-vs-eligible",32,32,{240,20,10,255},{{0,0,32,32}},{{6,6,{128,20,10,255}},{15,15,{96,96,96,255}}},{},{240,20,10,255}},
    {"eligibility-7-10","eligibility-direction",32,32,{240,20,10,255},{{0,0,32,32}},{{7,10,{96,96,96,255}}},{},{240,20,10,255}},
    {"eligibility-6-11","eligibility-direction",32,32,{240,20,10,255},{{0,0,32,32}},{{6,11,{96,96,96,255}}},{},{240,20,10,255}},
    {"eligibility-25-12","eligibility-direction",32,32,{240,20,10,255},{{0,0,32,32}},{{25,12,{96,96,96,255}}},{},{240,20,10,255}},
    {"eligibility-15-5","eligibility-direction",32,32,{240,20,10,255},{{0,0,32,32}},{{15,5,{96,96,96,255}}},{},{240,20,10,255}},
    {"glint-redness-1","activation-redness",32,32,{240,20,10,255},{{0,0,32,32}},{{15,15,{97,96,96,255}}},{},{240,20,10,255}},
    {"glint-redness-4","activation-redness",32,32,{240,20,10,255},{{0,0,32,32}},{{15,15,{100,96,96,255}}},{},{240,20,10,255}},
    {"glint-redness-12","activation-redness",32,32,{240,20,10,255},{{0,0,32,32}},{{15,15,{108,96,96,255}}},{},{240,20,10,255}},
    {"glint-redness-32","activation-redness",32,32,{240,20,10,255},{{0,0,32,32}},{{15,15,{128,96,96,255}}},{},{240,20,10,255}},
    {"shape-L","foreground-center",32,32,{96,96,96,255},{{0,0,32,32}},{},{{4,4,8,20},{8,16,20,20}},{240,20,10,255}},
    {"shape-L-shift","foreground-center",32,32,{96,96,96,255},{{0,0,32,32}},{},{{12,4,16,20},{16,16,28,20}},{240,20,10,255}},
    {"shape-L-partial","foreground-center",32,32,{96,96,96,255},{{8,0,24,24}},{},{{4,4,8,20},{8,16,20,20}},{240,20,10,255}},
    {"shape-two-lobes-left-small","foreground-center",32,32,{96,96,96,255},{{0,0,32,32}},{},{{4,4,8,8},{20,20,28,28}},{240,20,10,255}},
    {"shape-two-lobes-right-small","foreground-center",32,32,{96,96,96,255},{{0,0,32,32}},{},{{4,4,12,12},{24,24,28,28}},{240,20,10,255}},
    {"shape-L-tight","foreground-center",32,32,{96,96,96,255},{{4,4,20,20}},{},{{4,4,8,20},{8,16,20,20}},{240,20,10,255}},
    {"nonsquare-16x32-center","nonsquare-scale",16,32,{240,20,10,255},{{0,0,16,32}},{{7,15,{96,96,96,255}}},{},{240,20,10,255}},
    {"nonsquare-16x32-off-axis","nonsquare-scale",16,32,{240,20,10,255},{{0,0,16,32}},{{1,15,{96,96,96,255}}},{},{240,20,10,255}},
    {"nonsquare-32x16-center","nonsquare-scale",32,16,{240,20,10,255},{{0,0,32,16}},{{15,7,{96,96,96,255}}},{},{240,20,10,255}},
    {"nonsquare-32x16-off-axis","nonsquare-scale",32,16,{240,20,10,255},{{0,0,32,16}},{{15,1,{96,96,96,255}}},{},{240,20,10,255}},
    {"both-alpha128","source-alpha",32,32,{240,20,10,128},{{0,0,32,32}},{{15,15,{96,96,96,128}}},{},{240,20,10,255}},
    {"opaque-red-transparent-glint","source-alpha",32,32,{240,20,10,255},{{0,0,32,32}},{{15,15,{96,96,96,0}}},{},{240,20,10,255}},
    {"alpha128-red-opaque-glint","source-alpha",32,32,{240,20,10,128},{{0,0,32,32}},{{15,15,{96,96,96,255}}},{},{240,20,10,255}}
};}
static Color detectorColor(const DetectorCase& item,UINT x,UINT y){
    DetectorRGBA c=item.background;
    for(const auto& r:item.foreground)if(INT(x)>=r.left&&INT(x)<r.right&&INT(y)>=r.top&&INT(y)<r.bottom)c=item.foregroundColor;
    for(const auto& h:item.holes)if(INT(x)==h.x&&INT(y)==h.y)c=h.color;
    return Color(c.a,c.r,c.g,c.b);
}
static std::unique_ptr<Bitmap> detectorAtlas(const DetectorCase& item){
    auto image=std::make_unique<Bitmap>(item.width,item.height,PixelFormat32bppARGB);
    check(image->GetLastStatus(),"source allocation");check(image->SetResolution(96,96),"source DPI");
    for(UINT y=0;y<item.height;++y)for(UINT x=0;x<item.width;++x)check(image->SetPixel(x,y,detectorColor(item,x,y)),"source pixel");
    return image;
}
static void detectorPixels(Bitmap& image,const fs::path& dir,const std::string& name,std::ostream& out){
    UINT width=image.GetWidth(),height=image.GetHeight();check(image.GetLastStatus(),"observed dimensions");
    if(!width||!height||width>128||height>128)throw std::runtime_error("detector observation dimensions exceed bound");
    check(image.Save((dir/(name+".png")).c_str(),&pngEncoder,nullptr),"save native PNG");
    auto bytes=file(dir/(name+".rgba"),true);
    for(UINT y=0;y<height;++y)for(UINT x=0;x<width;++x){Color c;check(image.GetPixel(x,y,&c),"read native pixel");BYTE rgba[]={c.GetR(),c.GetG(),c.GetB(),c.GetA()};bytes.write(reinterpret_cast<const char*>(rgba),4);}
    out<<",\"width\":"<<width<<",\"height\":"<<height<<",\"rgba\":"<<json(name+".rgba")<<",\"png\":"<<json(name+".png");
}
template<class Body>static void detectorEffect(const DetectorCase& item,Body&& body){
    auto areas=item.areas;
    const size_t size=sizeof(RedEyeCorrectionParams)+areas.size()*sizeof(RECT);
    auto storage=std::make_unique<BYTE[]>(size);std::memset(storage.get(),0,size);
    auto params=new(storage.get())RedEyeCorrectionParams{UINT(areas.size()),areas.data()};
    std::memcpy(storage.get()+sizeof(RedEyeCorrectionParams),areas.data(),areas.size()*sizeof(RECT));
    RedEyeCorrection effect;body(effect,effect.SetParameters(params));
}
static void detectorRecord(const DetectorCase& item,Effect& effect,const fs::path& dir,std::ostream& out){
    ScreenDC screen;Metafile image((dir/(item.name+".emf")).c_str(),screen.value,RectF(0,0,REAL(item.width),REAL(item.height)),MetafileFrameUnitPixel,EmfTypeEmfPlusOnly,L"Original SDK general-detector RedEye reference");
    auto status=image.GetLastStatus();out<<",\"recordCreateStatus\":"<<status;if(status!=Ok)return;
    Graphics g(&image);check(g.GetLastStatus(),"record graphics");check(g.SetPageUnit(UnitPixel),"record units");
    check(g.SetCompositingMode(CompositingModeSourceCopy),"record compositing");check(g.Clear(Color(255,17,61,173)),"record opaque sentinel clear");
    auto input=detectorAtlas(item);RectF source(0,0,REAL(item.width),REAL(item.height));Matrix identity;
    status=g.DrawImage(input.get(),&source,&identity,&effect,nullptr,UnitPixel);out<<",\"recordStatus\":"<<status;
}
static void detectorDirect(const DetectorCase& item,Effect& effect,const fs::path& dir,const std::string& name,bool created,std::ostream& out){
    auto input=detectorAtlas(item);
    if(!created){auto status=input->ApplyEffect(&effect,nullptr);out<<",\"applyStatus\":"<<status;if(status==Ok)detectorPixels(*input,dir,name,out);}
    else {Bitmap* source=input.get();Bitmap* raw=nullptr;RECT bounds{};auto status=Bitmap::ApplyEffect(&source,1,&effect,nullptr,&bounds,&raw);std::unique_ptr<Bitmap> image(raw);out<<",\"applyStatus\":"<<status<<",\"outputRect\":["<<bounds.left<<','<<bounds.top<<','<<bounds.right<<','<<bounds.bottom<<']';if(status==Ok){if(!image)throw std::runtime_error("successful create returned no image");detectorPixels(*image,dir,name,out);}}
}
static void detectorReplay(const DetectorCase& item,const fs::path& dir,const std::string& name,std::ostream& out){
    Bitmap image((dir/(item.name+".emf")).c_str(),FALSE);auto status=image.GetLastStatus();out<<",\"bitmapLoadStatus\":"<<status;if(status!=Ok)return;
    UINT width=image.GetWidth(),height=image.GetHeight();check(image.GetLastStatus(),"intrinsic dimensions");
    if(!width||!height||width>128||height>128)throw std::runtime_error("intrinsic dimensions exceed bound");
    out<<",\"intrinsicWidth\":"<<width<<",\"intrinsicHeight\":"<<height<<",\"expectedSize\":"<<(width==item.width&&height==item.height?"true":"false")<<",\"intrinsic\":{\"name\":"<<json(name+"-intrinsic");detectorPixels(image,dir,name+"-intrinsic",out);out<<'}';
    Bitmap output(width,height,PixelFormat32bppARGB);check(output.GetLastStatus(),"replay allocation");check(output.SetResolution(96,96),"replay DPI");
    {Graphics g(&output);check(g.Clear(Color(0,0,0,0)),"replay clear");check(g.SetCompositingMode(CompositingModeSourceCopy),"Picture compositing");check(g.SetInterpolationMode(InterpolationModeDefault),"Picture interpolation");check(g.SetPixelOffsetMode(PixelOffsetModeHalf),"Picture offset");ImageAttributes attrs;check(attrs.SetWrapMode(WrapModeTileFlipXY),"Picture wrap");status=g.DrawImage(&image,Rect(0,0,INT(width),INT(height)),0,0,INT(width),INT(height),UnitPixel,&attrs);}
    out<<",\"drawStatus\":"<<status;if(status==Ok)detectorPixels(output,dir,name,out);
}
static bool detectorCase(const DetectorCase& item,const fs::path& dir,const std::string& mode,std::ostream& out){
    const std::string prefix=mode=="generate"?"":mode+"-";
    out<<"{\"name\":"<<json(prefix+item.name);item.describe(out);
    std::ostringstream detail;bool failed=false;
    try {
        if(mode=="generate"||mode=="direct-v1"){
            if(mode=="generate")detectorEffect(item,[&](auto& effect,Status status){detail<<",\"recordSetParametersStatus\":"<<status;if(status==Ok)detectorRecord(item,effect,dir,detail);});
            detail<<",\"direct\":{\"name\":"<<json(prefix+item.name);detectorEffect(item,[&](auto& effect,Status status){detail<<",\"setParametersStatus\":"<<status;if(status==Ok)detectorDirect(item,effect,dir,prefix+item.name,false,detail);});detail<<'}';
            detail<<",\"created\":{\"name\":"<<json(prefix+"created-"+item.name);detectorEffect(item,[&](auto& effect,Status status){detail<<",\"setParametersStatus\":"<<status;if(status==Ok)detectorDirect(item,effect,dir,prefix+"created-"+item.name,true,detail);});detail<<'}';
        }else detectorReplay(item,dir,prefix+item.name,detail);
    }catch(const std::exception& error){detail.str("");detail.clear();detail<<",\"error\":"<<json(error.what());failed=true;}
    out<<detail.str()<<'}';out.flush();return failed;
}
int main(int argc,char** argv){
    if(argc!=3)return 2;
    try {
        const std::string mode=argv[1];if(mode!="generate"&&mode!="direct-v1"&&mode!="replay"&&mode!="replay-v1")return 2;
        Startup startup(mode=="direct-v1"||mode=="replay-v1"?1:2);findPNGEncoder();
        const fs::path dir=fs::absolute(argv[2]);fs::create_directories(dir);auto out=file(dir/(mode+".json"));
        wchar_t path[32768]{};DWORD length=GetModuleFileNameW(GetModuleHandleW(L"gdiplus.dll"),path,32768);if(!length||length>=32768)throw std::runtime_error("cannot identify GDI+");
        auto cases=detectorCases();
        for(const auto& item:cases){if(!item.width||!item.height||item.width>128||item.height>128)throw std::runtime_error("source dimensions exceed bound");for(const auto& hole:item.holes)if(hole.x<0||hole.y<0||hole.x>=INT(item.width)||hole.y>=INT(item.height))throw std::runtime_error("source hole exceeds image");}
        out<<"{\"platform\":\"native Windows GDI+\",\"startupVersion\":"<<(mode=="direct-v1"||mode=="replay-v1"?1:2)<<",\"gdiplusModule\":"<<json(fs::path(path).u8string())<<",\"mode\":"<<json(mode)<<",\"caseCount\":"<<cases.size()<<",\"controlCount\":0,\"format\":\"straight RGBA row-major top-left\",\"atlases\":[";
        auto atlas=[&](const DetectorCase& item){out<<"{\"name\":"<<json(item.name);if(mode=="generate"||mode=="direct-v1"){const std::string sourcePrefix=mode=="generate"?"atlas-":"direct-v1-atlas-";auto image=detectorAtlas(item);out<<",\"requestedRGBA\":"<<json(sourcePrefix+item.name+"-requested.rgba");detectorPixels(*image,dir,sourcePrefix+item.name,out);auto requested=file(dir/(sourcePrefix+item.name+"-requested.rgba"),true);for(UINT y=0;y<item.height;++y)for(UINT x=0;x<item.width;++x){Color c=detectorColor(item,x,y);BYTE rgba[]={c.GetR(),c.GetG(),c.GetB(),c.GetA()};requested.write(reinterpret_cast<const char*>(rgba),4);}}out<<'}';};
        bool firstAtlas=true;for(const auto& item:cases){if(!firstAtlas)out<<',';firstAtlas=false;atlas(item);}out<<"],\"cases\":[";
        bool failed=false;bool first=true;
        for(const auto& item:cases){if(!first)out<<',';first=false;failed=detectorCase(item,dir,mode,out)||failed;}
        out<<"]}\n";out.close();return failed?1:0;
    }catch(const std::exception& error){std::cerr<<error.what()<<'\n';return 1;}
}
