// Original bounded RedEye no-paint versus transparent-source discriminator.
// Independent native SDK recording/direct/create and actual Bitmap file playback.
// Only these six new area lists are captured; no prior corpus is rerun.
#ifndef NOMINMAX
#define NOMINMAX
#endif
#define main unusedPointwiseReferenceMain
#include "../metafile-pointwise-effects-reference-2026-10-27/PointwiseEffectsReference.cpp"
#undef main
#include <cstring>
#include <sstream>

struct PaintCase {
    std::string name;
    std::vector<RECT> areas;
    void describe(std::ostream& out)const {
        out<<",\"family\":\"redEyeCorrection\",\"atlas\":"<<json(name)
           <<",\"emf\":"<<json(name+".emf")<<",\"parameters\":{\"numberOfAreas\":"<<areas.size()<<",\"areas\":[";
        bool first=true;for(const auto& r:areas){if(!first)out<<',';first=false;out<<'['<<r.left<<','<<r.top<<','<<r.right<<','<<r.bottom<<']';}out<<"]}"
           <<",\"sourceDefinition\":{\"width\":32,\"height\":32,\"uniformRGBA\":[240,20,10,255]}"
           <<",\"recordBackgroundRGBA\":[17,61,173,255],\"recordSourceRect\":[0,0,32,32],\"recordImageMatrix\":[1,0,0,1,0,0]"
           <<",\"recordFrameWidth\":32,\"recordFrameHeight\":32,\"expectedDirectApplyStatusPolicy\":\"retain native status including InvalidParameter=2; do not infer file outcome from direct API\"";
    }
};
static std::vector<PaintCase> paintCases(){return {
    {"outside-negative",{{-20,-20,-1,-1}}},
    {"outside-positive",{{40,40,50,50}}},
    {"valid-then-outside",{{0,0,32,32},{40,40,50,50}}},
    {"outside-then-valid",{{40,40,50,50},{0,0,32,32}}},
    {"partial-outside",{{-5,-3,12,17}}},
    {"full-control",{{0,0,32,32}}}
};}
static Color paintColor(const PaintCase&,UINT,UINT){return Color(255,240,20,10);}
static std::unique_ptr<Bitmap> paintAtlas(const PaintCase& item){
    auto image=std::make_unique<Bitmap>(32,32,PixelFormat32bppARGB);
    check(image->GetLastStatus(),"source allocation");check(image->SetResolution(96,96),"source DPI");
    for(UINT y=0;y<32;++y)for(UINT x=0;x<32;++x)check(image->SetPixel(x,y,paintColor(item,x,y)),"source pixel");
    return image;
}
static void paintPixels(Bitmap& image,const fs::path& dir,const std::string& name,std::ostream& out){
    UINT width=image.GetWidth(),height=image.GetHeight();check(image.GetLastStatus(),"observed dimensions");
    if(!width||!height||width>128||height>128)throw std::runtime_error("paint observation dimensions exceed bound");
    check(image.Save((dir/(name+".png")).c_str(),&pngEncoder,nullptr),"save native PNG");
    auto bytes=file(dir/(name+".rgba"),true);
    for(UINT y=0;y<height;++y)for(UINT x=0;x<width;++x){Color c;check(image.GetPixel(x,y,&c),"read native pixel");BYTE rgba[]={c.GetR(),c.GetG(),c.GetB(),c.GetA()};bytes.write(reinterpret_cast<const char*>(rgba),4);}
    out<<",\"width\":"<<width<<",\"height\":"<<height<<",\"rgba\":"<<json(name+".rgba")<<",\"png\":"<<json(name+".png");
}
template<class Body>static void paintEffect(const PaintCase& item,Body&& body){
    auto areas=item.areas;
    const size_t size=sizeof(RedEyeCorrectionParams)+areas.size()*sizeof(RECT);
    auto storage=std::make_unique<BYTE[]>(size);std::memset(storage.get(),0,size);
    auto params=new(storage.get())RedEyeCorrectionParams{UINT(areas.size()),const_cast<RECT*>(areas.data())};
    std::memcpy(storage.get()+sizeof(RedEyeCorrectionParams),areas.data(),areas.size()*sizeof(RECT));
    RedEyeCorrection effect;body(effect,effect.SetParameters(params));
}
static void paintRecord(const PaintCase& item,Effect& effect,const fs::path& dir,std::ostream& out){
    ScreenDC screen;Metafile image((dir/(item.name+".emf")).c_str(),screen.value,RectF(0,0,32,32),MetafileFrameUnitPixel,EmfTypeEmfPlusOnly,L"Original SDK opaque-background RedEye paint reference");
    auto status=image.GetLastStatus();out<<",\"recordCreateStatus\":"<<status;if(status!=Ok)return;
    Graphics g(&image);check(g.GetLastStatus(),"record graphics");check(g.SetPageUnit(UnitPixel),"record units");
    check(g.SetCompositingMode(CompositingModeSourceCopy),"record compositing");check(g.Clear(Color(255,17,61,173)),"record opaque sentinel clear");
    auto input=paintAtlas(item);RectF source(0,0,32,32);Matrix identity;
    status=g.DrawImage(input.get(),&source,&identity,&effect,nullptr,UnitPixel);out<<",\"recordStatus\":"<<status;
}
static void paintDirect(const PaintCase& item,Effect& effect,const fs::path& dir,const std::string& name,bool created,std::ostream& out){
    auto input=paintAtlas(item);
    if(!created){auto status=input->ApplyEffect(&effect,nullptr);out<<",\"applyStatus\":"<<status;if(status==Ok)paintPixels(*input,dir,name,out);}
    else {Bitmap* source=input.get();Bitmap* raw=nullptr;RECT bounds{};auto status=Bitmap::ApplyEffect(&source,1,&effect,nullptr,&bounds,&raw);std::unique_ptr<Bitmap> image(raw);out<<",\"applyStatus\":"<<status<<",\"outputRect\":["<<bounds.left<<','<<bounds.top<<','<<bounds.right<<','<<bounds.bottom<<']';if(status==Ok){if(!image)throw std::runtime_error("successful create returned no image");paintPixels(*image,dir,name,out);}}
}
static void paintReplay(const PaintCase& item,const fs::path& dir,const std::string& name,std::ostream& out){
    Bitmap image((dir/(item.name+".emf")).c_str(),FALSE);auto status=image.GetLastStatus();out<<",\"bitmapLoadStatus\":"<<status;if(status!=Ok)return;
    UINT width=image.GetWidth(),height=image.GetHeight();check(image.GetLastStatus(),"intrinsic dimensions");
    if(!width||!height||width>128||height>128)throw std::runtime_error("intrinsic dimensions exceed bound");
    out<<",\"intrinsicWidth\":"<<width<<",\"intrinsicHeight\":"<<height<<",\"expectedSize\":"<<(width==32&&height==32?"true":"false")<<",\"intrinsic\":{\"name\":"<<json(name+"-intrinsic");paintPixels(image,dir,name+"-intrinsic",out);out<<'}';
    Bitmap output(width,height,PixelFormat32bppARGB);check(output.GetLastStatus(),"replay allocation");check(output.SetResolution(96,96),"replay DPI");
    {Graphics g(&output);check(g.Clear(Color(0,0,0,0)),"replay clear");check(g.SetCompositingMode(CompositingModeSourceCopy),"Picture compositing");check(g.SetInterpolationMode(InterpolationModeDefault),"Picture interpolation");check(g.SetPixelOffsetMode(PixelOffsetModeHalf),"Picture offset");ImageAttributes attrs;check(attrs.SetWrapMode(WrapModeTileFlipXY),"Picture wrap");status=g.DrawImage(&image,Rect(0,0,INT(width),INT(height)),0,0,INT(width),INT(height),UnitPixel,&attrs);}
    out<<",\"drawStatus\":"<<status;if(status==Ok)paintPixels(output,dir,name,out);
}
static bool paintCase(const PaintCase& item,const fs::path& dir,const std::string& mode,std::ostream& out){
    const std::string prefix=mode=="generate"?"":mode+"-";
    out<<"{\"name\":"<<json(prefix+item.name);item.describe(out);
    std::ostringstream detail;bool failed=false;
    try {
        if(mode=="generate"||mode=="direct-v1"){
            if(mode=="generate")paintEffect(item,[&](auto& effect,Status status){detail<<",\"recordSetParametersStatus\":"<<status;if(status==Ok)paintRecord(item,effect,dir,detail);});
            detail<<",\"direct\":{\"name\":"<<json(prefix+item.name);paintEffect(item,[&](auto& effect,Status status){detail<<",\"setParametersStatus\":"<<status;if(status==Ok)paintDirect(item,effect,dir,prefix+item.name,false,detail);});detail<<'}';
            detail<<",\"created\":{\"name\":"<<json(prefix+"created-"+item.name);paintEffect(item,[&](auto& effect,Status status){detail<<",\"setParametersStatus\":"<<status;if(status==Ok)paintDirect(item,effect,dir,prefix+"created-"+item.name,true,detail);});detail<<'}';
        }else paintReplay(item,dir,prefix+item.name,detail);
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
        auto cases=paintCases();
        out<<"{\"platform\":\"native Windows GDI+\",\"startupVersion\":"<<(mode=="direct-v1"||mode=="replay-v1"?1:2)<<",\"gdiplusModule\":"<<json(fs::path(path).u8string())<<",\"mode\":"<<json(mode)<<",\"caseCount\":"<<cases.size()<<",\"controlCount\":0,\"format\":\"straight RGBA row-major top-left\",\"atlases\":[";
        auto atlas=[&](const PaintCase& item){out<<"{\"name\":"<<json(item.name);if(mode=="generate"){auto image=paintAtlas(item);paintPixels(*image,dir,"atlas-"+item.name,out);auto requested=file(dir/("atlas-"+item.name+"-requested.rgba"),true);for(UINT y=0;y<32;++y)for(UINT x=0;x<32;++x){Color c=paintColor(item,x,y);BYTE rgba[]={c.GetR(),c.GetG(),c.GetB(),c.GetA()};requested.write(reinterpret_cast<const char*>(rgba),4);}}out<<'}';};
        bool firstAtlas=true;for(const auto& item:cases){if(!firstAtlas)out<<',';firstAtlas=false;atlas(item);}out<<"],\"cases\":[";
        bool failed=false;bool first=true;
        for(const auto& item:cases){if(!first)out<<',';first=false;failed=paintCase(item,dir,mode,out)||failed;}
        out<<"]}\n";out.close();return failed?1:0;
    }catch(const std::exception& error){std::cerr<<error.what()<<'\n';return 1;}
}
