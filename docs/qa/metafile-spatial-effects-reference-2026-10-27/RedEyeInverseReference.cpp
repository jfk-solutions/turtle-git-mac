// Original bounded Windows SDK observations. No earlier assay inventory runs.
#ifndef NOMINMAX
#define NOMINMAX
#endif
#define main unusedPointwiseReferenceMain
#include "../metafile-pointwise-effects-reference-2026-10-27/PointwiseEffectsReference.cpp"
#undef main
#include <cstring>
#include <sstream>

struct InverseHole {UINT x,y;BYTE r,g,b;};
struct InverseCase {
    std::string name;
    std::vector<InverseHole> holes;
    void describe(std::ostream& out)const {
        out<<",\"family\":\"redEyeCorrection\",\"atlas\":"<<json(name)
           <<",\"emf\":"<<json(name+".emf")<<",\"parameters\":{\"numberOfAreas\":1,\"areas\":[[0,0,32,32]]}"
           <<",\"sourceDefinition\":{\"width\":32,\"height\":32,\"backgroundRGBA\":[240,20,10,255],\"holes\":[";
        bool first=true;for(const auto& h:holes){if(!first)out<<',';first=false;out<<'['<<h.x<<','<<h.y<<','<<int(h.r)<<','<<int(h.g)<<','<<int(h.b)<<",255]";}out<<"]}";
    }
};
static std::vector<InverseCase> inverseCases(){return {
    {"hole-gray-center",{{15,15,96,96,96}}},
    {"hole-gray-12",{{12,12,96,96,96}}},
    {"hole-gray-4",{{4,4,96,96,96}}},
    {"hole-low-red-center",{{15,15,128,20,10}}},
    {"holes-gray-diagonal",{{15,15,96,96,96},{16,16,96,96,96}}},
    {"holes-gray-horizontal",{{15,15,96,96,96},{16,15,96,96,96}}}
};}
static Color inverseColor(const InverseCase& item,UINT x,UINT y){
    for(const auto& h:item.holes)if(h.x==x&&h.y==y)return Color(255,h.r,h.g,h.b);
    return Color(255,240,20,10);
}
static std::unique_ptr<Bitmap> inverseAtlas(const InverseCase& item){
    auto image=std::make_unique<Bitmap>(32,32,PixelFormat32bppARGB);
    check(image->GetLastStatus(),"source allocation");check(image->SetResolution(96,96),"source DPI");
    for(UINT y=0;y<32;++y)for(UINT x=0;x<32;++x)check(image->SetPixel(x,y,inverseColor(item,x,y)),"source pixel");
    return image;
}
static void inversePixels(Bitmap& image,const fs::path& dir,const std::string& name,std::ostream& out){
    UINT width=image.GetWidth(),height=image.GetHeight();check(image.GetLastStatus(),"observed dimensions");
    if(!width||!height||width>128||height>128)throw std::runtime_error("inverse observation dimensions exceed bound");
    check(image.Save((dir/(name+".png")).c_str(),&pngEncoder,nullptr),"save native PNG");
    auto bytes=file(dir/(name+".rgba"),true);
    for(UINT y=0;y<height;++y)for(UINT x=0;x<width;++x){Color c;check(image.GetPixel(x,y,&c),"read native pixel");BYTE rgba[]={c.GetR(),c.GetG(),c.GetB(),c.GetA()};bytes.write(reinterpret_cast<const char*>(rgba),4);}
    out<<",\"width\":"<<width<<",\"height\":"<<height<<",\"rgba\":"<<json(name+".rgba")<<",\"png\":"<<json(name+".png");
}
template<class Body>static void inverseEffect(Body&& body){
    std::vector<RECT> areas{{0,0,32,32}};
    const size_t size=sizeof(RedEyeCorrectionParams)+areas.size()*sizeof(RECT);
    auto storage=std::make_unique<BYTE[]>(size);std::memset(storage.get(),0,size);
    auto params=new(storage.get())RedEyeCorrectionParams{UINT(areas.size()),areas.data()};
    std::memcpy(storage.get()+sizeof(RedEyeCorrectionParams),areas.data(),areas.size()*sizeof(RECT));
    RedEyeCorrection effect;body(effect,effect.SetParameters(params));
}
static void inverseRecord(const InverseCase& item,Effect& effect,const fs::path& dir,std::ostream& out){
    ScreenDC screen;Metafile image((dir/(item.name+".emf")).c_str(),screen.value,RectF(0,0,32,32),MetafileFrameUnitPixel,EmfTypeEmfPlusOnly,L"Original SDK inverse-hole RedEye reference");
    auto status=image.GetLastStatus();out<<",\"recordCreateStatus\":"<<status;if(status!=Ok)return;
    Graphics g(&image);check(g.GetLastStatus(),"record graphics");check(g.SetPageUnit(UnitPixel),"record units");
    check(g.SetCompositingMode(CompositingModeSourceCopy),"record compositing");check(g.Clear(Color(0,0,0,0)),"record clear");
    auto input=inverseAtlas(item);RectF source(0,0,32,32);Matrix identity;
    status=g.DrawImage(input.get(),&source,&identity,&effect,nullptr,UnitPixel);out<<",\"recordStatus\":"<<status;
}
static void inverseDirect(const InverseCase& item,Effect& effect,const fs::path& dir,const std::string& name,bool created,std::ostream& out){
    auto input=inverseAtlas(item);
    if(!created){auto status=input->ApplyEffect(&effect,nullptr);out<<",\"applyStatus\":"<<status;if(status==Ok)inversePixels(*input,dir,name,out);}
    else {Bitmap* source=input.get();Bitmap* raw=nullptr;RECT bounds{};auto status=Bitmap::ApplyEffect(&source,1,&effect,nullptr,&bounds,&raw);std::unique_ptr<Bitmap> image(raw);out<<",\"applyStatus\":"<<status<<",\"outputRect\":["<<bounds.left<<','<<bounds.top<<','<<bounds.right<<','<<bounds.bottom<<']';if(status==Ok){if(!image)throw std::runtime_error("successful create returned no image");inversePixels(*image,dir,name,out);}}
}
static void inverseReplay(const InverseCase& item,const fs::path& dir,const std::string& name,std::ostream& out){
    Bitmap image((dir/(item.name+".emf")).c_str(),FALSE);auto status=image.GetLastStatus();out<<",\"bitmapLoadStatus\":"<<status;if(status!=Ok)return;
    UINT width=image.GetWidth(),height=image.GetHeight();check(image.GetLastStatus(),"intrinsic dimensions");
    if(!width||!height||width>128||height>128)throw std::runtime_error("intrinsic dimensions exceed bound");
    out<<",\"intrinsicWidth\":"<<width<<",\"intrinsicHeight\":"<<height<<",\"expectedSize\":"<<(width==32&&height==32?"true":"false")<<",\"intrinsic\":{\"name\":"<<json(name+"-intrinsic");inversePixels(image,dir,name+"-intrinsic",out);out<<'}';
    Bitmap output(width,height,PixelFormat32bppARGB);check(output.GetLastStatus(),"replay allocation");check(output.SetResolution(96,96),"replay DPI");
    {Graphics g(&output);check(g.Clear(Color(0,0,0,0)),"replay clear");check(g.SetCompositingMode(CompositingModeSourceCopy),"Picture compositing");check(g.SetInterpolationMode(InterpolationModeDefault),"Picture interpolation");check(g.SetPixelOffsetMode(PixelOffsetModeHalf),"Picture offset");ImageAttributes attrs;check(attrs.SetWrapMode(WrapModeTileFlipXY),"Picture wrap");status=g.DrawImage(&image,Rect(0,0,INT(width),INT(height)),0,0,INT(width),INT(height),UnitPixel,&attrs);}
    out<<",\"drawStatus\":"<<status;if(status==Ok)inversePixels(output,dir,name,out);
}
static bool inverseCase(const InverseCase& item,const fs::path& dir,const std::string& mode,std::ostream& out){
    const std::string prefix=mode=="generate"?"":mode+"-";
    out<<"{\"name\":"<<json(prefix+item.name);item.describe(out);
    std::ostringstream detail;bool failed=false;
    try {
        if(mode=="generate"||mode=="direct-v1"){
            if(mode=="generate")inverseEffect([&](auto& effect,Status status){detail<<",\"recordSetParametersStatus\":"<<status;if(status==Ok)inverseRecord(item,effect,dir,detail);});
            detail<<",\"direct\":{\"name\":"<<json(prefix+item.name);inverseEffect([&](auto& effect,Status status){detail<<",\"setParametersStatus\":"<<status;if(status==Ok)inverseDirect(item,effect,dir,prefix+item.name,false,detail);});detail<<'}';
            detail<<",\"created\":{\"name\":"<<json(prefix+"created-"+item.name);inverseEffect([&](auto& effect,Status status){detail<<",\"setParametersStatus\":"<<status;if(status==Ok)inverseDirect(item,effect,dir,prefix+"created-"+item.name,true,detail);});detail<<'}';
        }else inverseReplay(item,dir,prefix+item.name,detail);
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
        auto cases=inverseCases();const InverseCase baseline{"solid-red-baseline",{}};
        out<<"{\"platform\":\"native Windows GDI+\",\"startupVersion\":"<<(mode=="direct-v1"||mode=="replay-v1"?1:2)<<",\"gdiplusModule\":"<<json(fs::path(path).u8string())<<",\"mode\":"<<json(mode)<<",\"caseCount\":"<<cases.size()<<",\"controlCount\":1,\"format\":\"straight RGBA row-major top-left\",\"atlases\":[";
        auto atlas=[&](const InverseCase& item){out<<"{\"name\":"<<json(item.name);if(mode=="generate"){auto image=inverseAtlas(item);inversePixels(*image,dir,"atlas-"+item.name,out);auto requested=file(dir/("atlas-"+item.name+"-requested.rgba"),true);for(UINT y=0;y<32;++y)for(UINT x=0;x<32;++x){Color c=inverseColor(item,x,y);BYTE rgba[]={c.GetR(),c.GetG(),c.GetB(),c.GetA()};requested.write(reinterpret_cast<const char*>(rgba),4);}}out<<'}';};
        atlas(baseline);for(const auto& item:cases){out<<',';atlas(item);}out<<"],\"baseline\":";
        bool failed=inverseCase(baseline,dir,mode,out);out<<",\"cases\":[";bool first=true;
        for(const auto& item:cases){if(!first)out<<',';first=false;failed=inverseCase(item,dir,mode,out)||failed;}
        out<<"]}\n";out.close();return failed?1:0;
    }catch(const std::exception& error){std::cerr<<error.what()<<'\n';return 1;}
}
