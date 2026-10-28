// Original bounded axis-isolated Blur quantization discriminator.
// Same reviewed four-process transport; four new cases plus one constant control.
// No earlier inventory is recaptured; no candidate algorithm or expected pixels.
#ifndef NOMINMAX
#define NOMINMAX
#endif
#define main unusedPointwiseReferenceMain
#include "../metafile-pointwise-effects-reference-2026-10-27/PointwiseEffectsReference.cpp"
#undef main
#include <sstream>
#include <utility>

static bool modelUnexpectedStatus=false;
static Status modelStatus(Status status){if(status!=Ok)modelUnexpectedStatus=true;return status;}

struct ModelCase {
    std::string name,group,definition;
    std::vector<Color> pixels;
    void describe(std::ostream& out)const {
        out<<",\"family\":\"blur\",\"sourceWidth\":32,\"sourceHeight\":32,\"atlas\":"<<json(name)
           <<",\"emf\":"<<json(name+".emf")<<",\"parameters\":{\"radius\":255,\"expandEdge\":false}"
           <<",\"recordSourceRect\":[0,0,32,32],\"recordImageMatrix\":[1,0,0,1,0,0],\"recordFrameWidth\":32,\"recordFrameHeight\":32,\"directROI\":null"
           <<",\"sourceDefinition\":{\"width\":32,\"height\":32,\"group\":"<<json(group)
           <<",\"description\":"<<json(definition)<<'}';
    }
};
static ModelCase modelFlat(const std::string& name,const std::string& group,Color color,const std::string& description){
    return {name,group,description,std::vector<Color>(1024,color)};
}
static std::vector<ModelCase> modelCases(){
    std::vector<ModelCase> cases;
    struct Packet {const char* name;BYTE r,g,b;};
    for(const Packet packet:std::vector<Packet>{{"a1-63-128",1,63,128},{"a97-200-255",97,200,255}}){
        for(bool vertical:{false,true}){
            const std::string orientation=vertical?"vertical":"horizontal";
            const std::string definition="Opaque halfplane: "+std::string(vertical?"y":"x")+"<16 has RGB("+std::to_string(packet.r)+","+std::to_string(packet.g)+","+std::to_string(packet.b)+"); other half has RGB(0,0,0); alpha255. Source32x32,radius255,fullROI,noexpansion.";
            auto item=modelFlat("blur-axis-"+orientation+"-"+packet.name,"axis-halfplane",Color(255,0,0,0),definition);
            for(UINT y=0;y<32;++y)for(UINT x=0;x<32;++x)if((vertical?y:x)<16)item.pixels[y*32+x]=Color(255,packet.r,packet.g,packet.b);
            cases.push_back(std::move(item));
        }
    }
    if(cases.size()!=4)throw std::runtime_error("authored inventory count defect");
    return cases;
}
static Color modelColor(const ModelCase& item,UINT x,UINT y){return item.pixels.at(y*32+x);}
static std::unique_ptr<Bitmap> modelAtlas(const ModelCase& item){
    if(item.pixels.size()!=1024)throw std::runtime_error("authored source size defect");
    auto image=std::make_unique<Bitmap>(32,32,PixelFormat32bppARGB);
    check(image->GetLastStatus(),"source allocation");check(image->SetResolution(96,96),"source DPI");
    for(UINT y=0;y<32;++y)for(UINT x=0;x<32;++x)check(image->SetPixel(x,y,modelColor(item,x,y)),"source pixel");
    return image;
}
static void modelPixels(Bitmap& image,const fs::path& dir,const std::string& name,std::ostream& out){
    UINT width=image.GetWidth(),height=image.GetHeight();check(image.GetLastStatus(),"observed dimensions");
    if(!width||!height||width>128||height>128)throw std::runtime_error("model observation dimensions exceed bound");
    check(image.Save((dir/(name+".png")).c_str(),&pngEncoder,nullptr),"save native PNG");
    auto bytes=file(dir/(name+".rgba"),true);
    for(UINT y=0;y<height;++y)for(UINT x=0;x<width;++x){Color c;check(image.GetPixel(x,y,&c),"read native pixel");BYTE rgba[]={c.GetR(),c.GetG(),c.GetB(),c.GetA()};bytes.write(reinterpret_cast<const char*>(rgba),4);}
    out<<",\"width\":"<<width<<",\"height\":"<<height<<",\"rgba\":"<<json(name+".rgba")<<",\"png\":"<<json(name+".png");
}
template<class Body>static void modelEffect(Body&& body){
    BlurParams parameters{255.f,FALSE};Blur effect;
    body(effect,modelStatus(effect.SetParameters(&parameters)));
}
static void modelRecord(const ModelCase& item,Effect& effect,const fs::path& dir,std::ostream& out){
    ScreenDC screen;Metafile image((dir/(item.name+".emf")).c_str(),screen.value,RectF(0,0,32,32),MetafileFrameUnitPixel,EmfTypeEmfPlusOnly,L"Original SDK axis-isolated large Blur reference");
    auto status=modelStatus(image.GetLastStatus());out<<",\"recordCreateStatus\":"<<status;if(status!=Ok)return;
    Graphics g(&image);check(g.GetLastStatus(),"record graphics");check(g.SetPageUnit(UnitPixel),"record units");
    check(g.SetCompositingMode(CompositingModeSourceCopy),"record compositing");check(g.Clear(Color(0,0,0,0)),"record clear");
    auto input=modelAtlas(item);RectF source(0,0,32,32);Matrix identity;
    status=modelStatus(g.DrawImage(input.get(),&source,&identity,&effect,nullptr,UnitPixel));out<<",\"recordStatus\":"<<status;
}
static void modelDirect(const ModelCase& item,Effect& effect,const fs::path& dir,const std::string& name,bool created,std::ostream& out){
    auto input=modelAtlas(item);
    if(!created){auto status=modelStatus(input->ApplyEffect(&effect,nullptr));out<<",\"applyStatus\":"<<status;if(status==Ok)modelPixels(*input,dir,name,out);}
    else {Bitmap* source=input.get();Bitmap* raw=nullptr;RECT bounds{};auto status=modelStatus(Bitmap::ApplyEffect(&source,1,&effect,nullptr,&bounds,&raw));std::unique_ptr<Bitmap> image(raw);out<<",\"applyStatus\":"<<status<<",\"outputRect\":["<<bounds.left<<','<<bounds.top<<','<<bounds.right<<','<<bounds.bottom<<']';if(status==Ok){if(!image)throw std::runtime_error("successful create returned no image");modelPixels(*image,dir,name,out);}}
}
static void modelReplay(const ModelCase& item,const fs::path& dir,const std::string& name,std::ostream& out){
    Bitmap image((dir/(item.name+".emf")).c_str(),FALSE);auto status=modelStatus(image.GetLastStatus());out<<",\"bitmapLoadStatus\":"<<status;if(status!=Ok)return;
    UINT width=image.GetWidth(),height=image.GetHeight();check(image.GetLastStatus(),"intrinsic dimensions");
    if(!width||!height||width>128||height>128)throw std::runtime_error("intrinsic dimensions exceed bound");
    if(width!=32||height!=32)modelUnexpectedStatus=true;
    out<<",\"intrinsicWidth\":"<<width<<",\"intrinsicHeight\":"<<height<<",\"expectedSize\":"<<(width==32&&height==32?"true":"false")<<",\"intrinsic\":{\"name\":"<<json(name+"-intrinsic");modelPixels(image,dir,name+"-intrinsic",out);out<<'}';
    Bitmap output(width,height,PixelFormat32bppARGB);check(output.GetLastStatus(),"replay allocation");check(output.SetResolution(96,96),"replay DPI");
    {Graphics g(&output);check(g.Clear(Color(0,0,0,0)),"replay clear");check(g.SetCompositingMode(CompositingModeSourceCopy),"Picture compositing");check(g.SetInterpolationMode(InterpolationModeDefault),"Picture interpolation");check(g.SetPixelOffsetMode(PixelOffsetModeHalf),"Picture offset");ImageAttributes attrs;check(attrs.SetWrapMode(WrapModeTileFlipXY),"Picture wrap");status=modelStatus(g.DrawImage(&image,Rect(0,0,INT(width),INT(height)),0,0,INT(width),INT(height),UnitPixel,&attrs));}
    out<<",\"drawStatus\":"<<status;if(status==Ok)modelPixels(output,dir,name,out);
}
static bool modelCase(const ModelCase& item,const fs::path& dir,const std::string& mode,std::ostream& out){
    const std::string prefix=mode=="generate"?"":mode+"-";
    out<<"{\"name\":"<<json(prefix+item.name);item.describe(out);
    std::ostringstream detail;bool failed=false;
    try {
        if(mode=="generate"||mode=="direct-v1"){
            if(mode=="generate")modelEffect([&](auto& effect,Status status){detail<<",\"recordSetParametersStatus\":"<<status;if(status==Ok)modelRecord(item,effect,dir,detail);});
            detail<<",\"direct\":{\"name\":"<<json(prefix+item.name);modelEffect([&](auto& effect,Status status){detail<<",\"setParametersStatus\":"<<status;if(status==Ok)modelDirect(item,effect,dir,prefix+item.name,false,detail);});detail<<'}';
            detail<<",\"created\":{\"name\":"<<json(prefix+"created-"+item.name);modelEffect([&](auto& effect,Status status){detail<<",\"setParametersStatus\":"<<status;if(status==Ok)modelDirect(item,effect,dir,prefix+"created-"+item.name,true,detail);});detail<<'}';
        }else modelReplay(item,dir,prefix+item.name,detail);
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
        auto cases=modelCases();cases.insert(cases.begin(),modelFlat("blur-axis-control-constant","same-job-control",Color(255,91,157,223),"Opaque constant RGB(91,157,223),alpha255; same radius255/fullROI/noexpansion transport control."));
        out<<"{\"platform\":\"native Windows GDI+\",\"startupVersion\":"<<(mode=="direct-v1"||mode=="replay-v1"?1:2)<<",\"gdiplusModule\":"<<json(fs::path(path).u8string())<<",\"mode\":"<<json(mode)<<",\"caseCount\":"<<cases.size()<<",\"plannedCaseCount\":4,\"controlCount\":1,\"format\":\"straight RGBA row-major top-left\",\"atlases\":[";
        auto atlas=[&](const ModelCase& item){out<<"{\"name\":"<<json(item.name);if(mode=="generate"||mode=="direct-v1"){const std::string prefix=mode=="generate"?"atlas-":"atlas-direct-v1-";auto image=modelAtlas(item);modelPixels(*image,dir,prefix+item.name,out);auto requested=file(dir/(prefix+item.name+"-requested.rgba"),true);bool same=true;for(UINT y=0;y<32;++y)for(UINT x=0;x<32;++x){Color c=modelColor(item,x,y),actual;check(image->GetPixel(x,y,&actual),"source comparison");same=same&&actual.GetValue()==c.GetValue();BYTE rgba[]={c.GetR(),c.GetG(),c.GetB(),c.GetA()};requested.write(reinterpret_cast<const char*>(rgba),4);}out<<",\"requestedRGBA\":"<<json(prefix+item.name+"-requested.rgba")<<",\"requestedMatchesObserved\":"<<(same?"true":"false");if(!same)modelUnexpectedStatus=true;}out<<'}';};
        bool first=true;for(const auto& item:cases){if(!first)out<<',';first=false;atlas(item);}out<<"],\"cases\":[";
        bool failed=false;first=true;
        for(const auto& item:cases){if(!first)out<<',';first=false;failed=modelCase(item,dir,mode,out)||failed;}
        out<<"]}\n";out.close();return failed||modelUnexpectedStatus?1:0;
    }catch(const std::exception& error){std::cerr<<error.what()<<'\n';return 1;}
}
