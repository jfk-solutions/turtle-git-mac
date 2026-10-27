// Original bounded RGB-histogram/foreground/normalization discriminator.
// Native SDK transport retains the previously reviewed safe source pattern.
// No old inventory runs;27planned inputs plus2same-jobuniformcontrols.
#ifndef NOMINMAX
#define NOMINMAX
#endif
#define main unusedPointwiseReferenceMain
#include "../metafile-pointwise-effects-reference-2026-10-27/PointwiseEffectsReference.cpp"
#undef main
#include <cstring>
#include <sstream>
#include <map>
#include <utility>

static bool modelUnexpectedStatus=false;
static Status modelStatus(Status status){if(status!=Ok)modelUnexpectedStatus=true;return status;}

struct ModelCase {
    std::string name,group,definition,histogramGroup;
    std::vector<Color> pixels;
    void describe(std::ostream& out)const {
        out<<",\"family\":\"redEyeCorrection\",\"sourceWidth\":32,\"sourceHeight\":32,\"atlas\":"<<json(name)
           <<",\"emf\":"<<json(name+".emf")<<",\"parameters\":{\"numberOfAreas\":1,\"areas\":[[0,0,32,32]]}"
           <<",\"sourceDefinition\":{\"width\":32,\"height\":32,\"group\":"<<json(group)
           <<",\"description\":"<<json(definition)<<",\"matchedHistogramGroup\":"<<json(histogramGroup)<<'}';
    }
};
static ModelCase modelFlat(const std::string& name,const std::string& group,Color color,const std::string& description){
    return {name,group,description,"",std::vector<Color>(1024,color)};
}
static void modelRectangle(ModelCase& item,UINT left,UINT top,UINT right,UINT bottom,Color color){
    if(left>=right||top>=bottom||right>32||bottom>32)throw std::runtime_error("authored rectangle outside source");
    for(UINT y=top;y<bottom;++y)for(UINT x=left;x<right;++x)item.pixels[y*32+x]=color;
}
static std::map<ARGB,size_t> modelHistogram(const ModelCase& item){
    std::map<ARGB,size_t> result;for(const Color c:item.pixels)++result[c.GetValue()];return result;
}
static std::vector<ModelCase> modelCases(){
    const Color red(255,240,20,10),gray(255,96,96,96);std::vector<ModelCase> cases;
    auto matched=[&](ModelCase c){c.histogramGroup="576red448gray";cases.push_back(std::move(c));};
    auto c=modelFlat("model-hist-square24","matched-histogram",gray,"Red square[4,4,28,28],576red/448gray; same-job anchor to prior24-shape amplitude.");modelRectangle(c,4,4,28,28,red);matched(std::move(c));
    c=modelFlat("model-hist-permuted","matched-histogram",gray,"Red iff(73*linearIndex+19)mod1024<576; exact histogram, distributed extent32.");
    for(UINT i=0;i<1024;++i)if((73*i+19)%1024<576)c.pixels[i]=red;matched(std::move(c));
    c=modelFlat("model-hist-two-rectangles","matched-histogram",gray,"Red rectangles[0,4,12,28]and[20,4,32,28],exact576red/448gray.");modelRectangle(c,0,4,12,28,red);modelRectangle(c,20,4,32,28,red);matched(std::move(c));
    c=modelFlat("model-hist-center-rows","matched-histogram",gray,"Red rows7..<25,576red/448gray; centered32x18extent.");modelRectangle(c,0,7,32,25,red);matched(std::move(c));
    c=modelFlat("model-hist-center-gray","matched-histogram",red,"Gray rectangle[8,2,24,30],448gray/576red; red extent32.");modelRectangle(c,8,2,24,30,gray);matched(std::move(c));
    const auto expected=modelHistogram(cases.front());for(const auto& item:cases)if(modelHistogram(item)!=expected)throw std::runtime_error("matched source histogram defect");
    for(UINT size:{2u,4u,8u,16u}){
        const UINT left=(32-size)/2;c=modelFlat("model-gray-hole"+std::to_string(size),"holes-borders",red,"Centered gray square size"+std::to_string(size)+" on otherwise red source; full32ROI.");modelRectangle(c,left,left,left+size,left+size,gray);cases.push_back(std::move(c));
    }
    for(UINT size:{20u,22u,26u,28u,30u}){
        const UINT left=(32-size)/2;c=modelFlat("model-red-square"+std::to_string(size),"holes-borders",gray,"Centered red square size"+std::to_string(size)+" on gray source; full32ROI.");modelRectangle(c,left,left,left+size,left+size,red);cases.push_back(std::move(c));
    }
    struct ChannelControl {const char* name;BYTE r,g,b;};
    for(const ChannelControl control:std::vector<ChannelControl>{{"g0",240,0,10},{"b0",240,20,0},{"gb0",240,0,0},{"r255",255,20,10}}){
        for(bool hole:{false,true}){
            c=modelFlat(std::string("model-channel-")+control.name+(hole?"-gray-hole":"-uniform"),"zero-channel",Color(255,control.r,control.g,control.b),std::string("Uniform RGBA(")+std::to_string(control.r)+","+std::to_string(control.g)+","+std::to_string(control.b)+",255)"+(hole?" with gray96 at15,15.":"; no hole."));
            if(hole)c.pixels[15*32+15]=gray;cases.push_back(std::move(c));
        }
    }
    for(UINT kind=0;kind<5;++kind){
        const char* names[]={"red-x","red-y","green-x","blue-x","brightness-x"};
        const char* definitions[]={"R=32+floor(208*x/31),G20,B10.","R=32+floor(208*y/31),G20,B10; exact histogram match red-x.","R240,G=floor(96*x/31),B10.","R240,G20,B=floor(96*x/31).","R=7*(x+1),G=2*(x+1),B=x+1; exact fixed7:2:1chromaticity, allpositive."};
        c=modelFlat(std::string("model-gradient-")+names[kind],"continuous-gradient",red,definitions[kind]);
        for(UINT y=0;y<32;++y)for(UINT x=0;x<32;++x){
            BYTE r=240,g=20,b=10;
            if(kind<2)r=BYTE(32+208*(kind==0?x:y)/31);
            else if(kind==2)g=BYTE(96*x/31);
            else if(kind==3)b=BYTE(96*x/31);
            else {r=BYTE(7*(x+1));g=BYTE(2*(x+1));b=BYTE(x+1);}
            c.pixels[y*32+x]=Color(255,r,g,b);
        }
        if(kind<2)c.histogramGroup="red-gradient-axis-permutation";
        cases.push_back(std::move(c));
    }
    if(cases.size()!=27)throw std::runtime_error("authored inventory count defect");
    std::map<std::string,std::map<ARGB,size_t>> histograms;
    for(const auto& item:cases)if(!item.histogramGroup.empty()){
        const auto histogram=modelHistogram(item);auto found=histograms.find(item.histogramGroup);
        if(found!=histograms.end()&&found->second!=histogram)throw std::runtime_error("authored histogram group mismatch");histograms[item.histogramGroup]=histogram;
    }
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
    std::vector<RECT> areas{{0,0,32,32}};
    const size_t size=sizeof(RedEyeCorrectionParams)+areas.size()*sizeof(RECT);
    auto storage=std::make_unique<BYTE[]>(size);std::memset(storage.get(),0,size);
    auto params=new(storage.get())RedEyeCorrectionParams{UINT(areas.size()),areas.data()};
    std::memcpy(storage.get()+sizeof(RedEyeCorrectionParams),areas.data(),areas.size()*sizeof(RECT));
    RedEyeCorrection effect;body(effect,modelStatus(effect.SetParameters(params)));
}
static void modelRecord(const ModelCase& item,Effect& effect,const fs::path& dir,std::ostream& out){
    ScreenDC screen;Metafile image((dir/(item.name+".emf")).c_str(),screen.value,RectF(0,0,32,32),MetafileFrameUnitPixel,EmfTypeEmfPlusOnly,L"Original SDK matched-model-discriminator RedEye reference");
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
        auto cases=modelCases();cases.insert(cases.begin(),modelFlat("model-control-red","same-job-control",Color(255,240,20,10),"Opaque uniform red quarter-cone baseline."));cases.insert(cases.begin()+1,modelFlat("model-control-gray","same-job-control",Color(255,96,96,96),"Opaque gray identity control."));
        out<<"{\"platform\":\"native Windows GDI+\",\"startupVersion\":"<<(mode=="direct-v1"||mode=="replay-v1"?1:2)<<",\"gdiplusModule\":"<<json(fs::path(path).u8string())<<",\"mode\":"<<json(mode)<<",\"caseCount\":"<<cases.size()<<",\"plannedCaseCount\":27,\"controlCount\":2,\"format\":\"straight RGBA row-major top-left\",\"atlases\":[";
        auto atlas=[&](const ModelCase& item){out<<"{\"name\":"<<json(item.name);if(mode=="generate"||mode=="direct-v1"){const std::string prefix=mode=="generate"?"atlas-":"atlas-direct-v1-";auto image=modelAtlas(item);modelPixels(*image,dir,prefix+item.name,out);auto requested=file(dir/(prefix+item.name+"-requested.rgba"),true);bool same=true;for(UINT y=0;y<32;++y)for(UINT x=0;x<32;++x){Color c=modelColor(item,x,y),actual;check(image->GetPixel(x,y,&actual),"source comparison");same=same&&actual.GetValue()==c.GetValue();BYTE rgba[]={c.GetR(),c.GetG(),c.GetB(),c.GetA()};requested.write(reinterpret_cast<const char*>(rgba),4);}out<<",\"requestedMatchesObserved\":"<<(same?"true":"false");if(!same)modelUnexpectedStatus=true;}out<<'}';};
        bool first=true;for(const auto& item:cases){if(!first)out<<',';first=false;atlas(item);}out<<"],\"cases\":[";
        bool failed=false;first=true;
        for(const auto& item:cases){if(!first)out<<',';first=false;failed=modelCase(item,dir,mode,out)||failed;}
        out<<"]}\n";out.close();return failed||modelUnexpectedStatus?1:0;
    }catch(const std::exception& error){std::cerr<<error.what()<<'\n';return 1;}
}
