// Focused original SDK observations. Neither earlier assay main is invoked.
#define main unusedPointwiseReferenceMain
#include "../metafile-pointwise-effects-reference-2026-10-27/PointwiseEffectsReference.cpp"
#undef main
#include <cstring>
#include <sstream>
struct FollowCase {
    std::string name,shape="solid";
    int size=32,left=0,top=0,dimension=32,width=0,height=0;
    BYTE r=240,g=20,b=10;
    std::vector<RECT> areas{{0,0,32,32}};
    REAL blurRadius=-1;
    std::string repeats;
    void describe(std::ostream& out) const {
        out<<",\"source\":"<<json(name)<<",\"family\":"<<json(blurRadius<0?"redEyeCorrection":"blur")<<",\"emf\":"<<json(name+".emf")
            <<",\"sourceWidth\":"<<(width?width:dimension)<<",\"sourceHeight\":"<<(height?height:dimension)<<",\"atlas\":"<<json(name)<<",\"sourceDefinition\":{\"shape\":"<<json(shape)<<",\"left\":"<<left<<",\"top\":"<<top<<",\"size\":"<<size<<",\"foregroundRGB\":["<<int(r)<<','<<int(g)<<','<<int(b)<<"],\"backgroundRGB\":"<<(shape=="tall-bars"?"[0,0,0]":"[96,96,96]");
        if(shape=="tall-bars")out<<",\"fullWidthBars\":{\"redRows\":[0,128],\"greenRows\":[1,129],\"blueRows\":[64,256],\"value\":255,\"clipRowsToHeight\":true}";
        out<<"},\"parameters\":{";
        if(blurRadius>=0)out<<"\"radius\":"<<blurRadius<<",\"expandEdge\":false";
        else {out<<"\"numberOfAreas\":"<<areas.size()<<",\"areas\":[";bool first=true;for(const auto& a:areas){if(!first)out<<',';first=false;out<<'['<<a.left<<','<<a.top<<','<<a.right<<','<<a.bottom<<']';}out<<']';}
        out<<'}';if(!repeats.empty())out<<",\"repeatsSourceCase\":"<<json(repeats);
    }
};
static UINT followWidth(const FollowCase& c){return UINT(c.width?c.width:c.dimension);}
static UINT followHeight(const FollowCase& c){return UINT(c.height?c.height:c.dimension);}
static Color followColor(const FollowCase& c,UINT x,UINT y) {
    if(c.shape=="tall-bars")return Color(255,y==0||y==128?255:0,y==1||y==129?255:0,y==64||y==256?255:0);
    if(c.shape=="step")return Color(255,x<16?0:255,y<11?31:223,(x+y)<23?240:17);
    if(c.shape=="asymmetric")return Color(255,BYTE(11*x+53*y),BYTE(43*x+7*y),BYTE(19*x+37*y));
    if(c.shape=="gradient")return Color(255,BYTE((x*255+15)/31),20,10);
    bool foreground=c.shape=="solid";
    if(c.shape=="square")foreground=int(x)>=c.left&&int(x)<c.left+c.size&&int(y)>=c.top&&int(y)<c.top+c.size;
    if(c.shape=="disk") {int dx=2*int(x)+1-(2*c.left+c.size),dy=2*int(y)+1-(2*c.top+c.size);foreground=dx*dx+dy*dy<=c.size*c.size;}
    return foreground?Color(255,c.r,c.g,c.b):Color(255,96,96,96);
}
static std::unique_ptr<Bitmap> followAtlas(const FollowCase& c){auto image=std::make_unique<Bitmap>(followWidth(c),followHeight(c),PixelFormat32bppARGB);check(image->GetLastStatus(),"source allocation");check(image->SetResolution(96,96),"source DPI");for(UINT y=0;y<followHeight(c);++y)for(UINT x=0;x<followWidth(c);++x)check(image->SetPixel(x,y,followColor(c,x,y)),"source pixel");return image;}
static void followPixels(Bitmap& image, const fs::path& dir, const std::string& name, std::ostream& report) {
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
static std::vector<FollowCase> followCases() {
    std::vector<FollowCase> result;
    auto add=[&](FollowCase c){for(const auto& old:result)if(old.name==c.name)throw std::runtime_error("duplicate case name");result.push_back(c);};
    auto solid=[&](const char* name,BYTE r,BYTE g,BYTE b){FollowCase c;c.name=name;c.r=r;c.g=g;c.b=b;add(c);};
    solid("solid-red",240,20,10);solid("solid-gray",96,96,96);solid("solid-skin",180,145,120);solid("solid-pure-red",255,0,0);
    for(const auto& shape:{"square","disk"})for(int size:{1,2,4,8,16,24}) {
        if(std::string(shape)=="disk"&&size==1)continue;
        FollowCase c;c.name=std::string(shape)+"-"+std::to_string(size);c.shape=shape;c.size=size;c.left=c.top=(32-size)/2;add(c);
        c.name+="-bounds";c.areas={{c.left,c.top,c.left+size,c.top+size}};add(c);
    }
    for(const auto& shape:{"square","disk"})for(int shift=0;shift<3;++shift){FollowCase c;c.name=std::string(shape)+"-8-shift"+std::to_string(shift);c.shape=shape;c.size=8;c.left=12+(shift==0||shift==2);c.top=12+(shift==1||shift==2);add(c);}
    for(int origin:{4,20}){FollowCase c;c.name="square-8-at"+std::to_string(origin);c.shape="square";c.size=8;c.left=c.top=origin;add(c);}
    const std::vector<std::vector<RECT>> variants={{{0,0,16,32}},{{8,8,24,24}},{{11,11,21,21}},{{-4,-4,20,20}},{{12,12,20,20}},{{0,0,24,24},{8,8,32,32}},{{8,8,32,32},{0,0,24,24}},{{0,0,32,32},{0,0,32,32}}};
    for(UINT i=0;i<variants.size();++i){FollowCase c;c.name="square-8-roi"+std::to_string(i);c.shape="square";c.size=8;c.left=c.top=12;c.areas=variants[i];add(c);}
    solid("threshold-low-red",128,20,10);solid("threshold-high-green",240,120,10);solid("threshold-high-blue",240,20,120);solid("threshold-balanced",120,60,60);
    FollowCase gradient;gradient.name="red-gradient";gradient.shape="gradient";add(gradient);
    for(const auto& prior:{"solid-red","square-8"}){auto it=std::find_if(result.begin(),result.end(),[&](const FollowCase& c){return c.name==prior;});if(it==result.end())throw std::runtime_error("repeat source absent");FollowCase c=*it;c.repeats=c.name;c.name+="-repeat";add(c);}
    for(const auto& shape:{"step","asymmetric"})for(REAL radius:{.75f,1.25f,2.5f,7.3f}){FollowCase c;c.name=std::string("blur-")+shape+"-r"+std::to_string(int(radius*100));c.shape=shape;c.blurRadius=radius;add(c);}
    for(int dimension:{16,24,33}){FollowCase c;c.name="solid-red-size"+std::to_string(dimension);c.dimension=dimension;c.size=dimension;c.areas={{0,0,dimension,dimension}};add(c);}
    for(int extent:{14,16}){FollowCase c;c.name="solid-red-roi"+std::to_string(extent);c.areas={{0,0,extent,extent}};add(c);}
    for(int height:{33,129,257}){FollowCase c;c.name="blur-tall-bars-"+std::to_string(height);c.shape="tall-bars";c.width=17;c.height=height;c.blurRadius=3;add(c);}
    if(result.size()!=65)throw std::runtime_error("followup inventory changed");return result;
}
template<class Body>static void followEffect(const FollowCase& c,Body&& body){
    if(c.blurRadius>=0){BlurParams p{c.blurRadius,FALSE};Blur e;body(e,e.SetParameters(&p));return;}
    auto areas=c.areas;const size_t bytes=sizeof(RedEyeCorrectionParams)+areas.size()*sizeof(RECT);auto storage=std::make_unique<BYTE[]>(bytes);std::memset(storage.get(),0,bytes);auto p=new(storage.get())RedEyeCorrectionParams{UINT(areas.size()),areas.data()};std::memcpy(storage.get()+sizeof(RedEyeCorrectionParams),areas.data(),areas.size()*sizeof(RECT));RedEyeCorrection e;body(e,e.SetParameters(p));
}
static void followAux(Effect& e,const fs::path& dir,const std::string& stem,std::ostream& out){UINT size=e.GetAuxDataSize();out<<",\"auxBytes\":"<<size;if(size>1024*1024)throw std::runtime_error("auxiliary bound");if(size&&e.GetAuxData()){auto bytes=file(dir/(stem+".aux"),true);bytes.write(static_cast<const char*>(e.GetAuxData()),size);out<<",\"aux\":"<<json(stem+".aux");}}
static void followRecord(const FollowCase& c,Effect& e,const fs::path& dir,std::ostream& out){ScreenDC screen;Metafile image((dir/(c.name+".emf")).c_str(),screen.value,RectF(0,0,REAL(followWidth(c)),REAL(followHeight(c))),MetafileFrameUnitPixel,EmfTypeEmfPlusOnly,L"Original SDK focused spatial reference");auto status=image.GetLastStatus();out<<",\"recordCreateStatus\":"<<status;if(status!=Ok)return;Graphics g(&image);check(g.GetLastStatus(),"record graphics");check(g.SetPageUnit(UnitPixel),"record units");check(g.SetCompositingMode(CompositingModeSourceCopy),"record compositing");check(g.Clear(Color(0,0,0,0)),"record clear");auto input=followAtlas(c);RectF source(0,0,REAL(followWidth(c)),REAL(followHeight(c)));Matrix identity;status=g.DrawImage(input.get(),&source,&identity,&e,nullptr,UnitPixel);out<<",\"recordStatus\":"<<status<<",\"recordFrameWidth\":"<<followWidth(c)<<",\"recordFrameHeight\":"<<followHeight(c);}
static void followDirect(const FollowCase& c,Effect& e,const fs::path& dir,const std::string& stem,bool created,std::ostream& out){auto input=followAtlas(c);e.UseAuxData(TRUE);if(!created){auto status=input->ApplyEffect(&e,nullptr);out<<",\"applyStatus\":"<<status;followAux(e,dir,stem,out);if(status==Ok)followPixels(*input,dir,stem,out);}else{Bitmap* in=input.get();Bitmap* raw=nullptr;RECT bounds{};auto status=Bitmap::ApplyEffect(&in,1,&e,nullptr,&bounds,&raw);std::unique_ptr<Bitmap> image(raw);out<<",\"applyStatus\":"<<status<<",\"outputRect\":["<<bounds.left<<','<<bounds.top<<','<<bounds.right<<','<<bounds.bottom<<']';followAux(e,dir,stem,out);if(status==Ok){if(!image)throw std::runtime_error("null successful output");followPixels(*image,dir,stem,out);}}}
static void followReplay(const FollowCase& item, const fs::path& dir, const std::string& prefix, std::ostream& out) {
    Bitmap image((dir/(item.name+".emf")).c_str(),FALSE);
    const Status loaded=image.GetLastStatus();out << ",\"bitmapLoadStatus\":" << loaded;
    if (loaded != Ok) return;
    const UINT width=image.GetWidth(),height=image.GetHeight();
    out << ",\"intrinsicWidth\":" << width << ",\"intrinsicHeight\":" << height
        << ",\"expectedSize\":" << (width==followWidth(item) && height==followHeight(item) ? "true":"false");
    // Retain true dimensions: a recorder/constructor mismatch is never hidden
    // by stretching a successful result into the requested 32x32 viewport.
    if (!width || !height || width>512 || height>512) throw std::runtime_error("unbounded replay dimensions");
    out << ",\"intrinsic\":{\"name\":" << json(prefix+item.name+"-intrinsic");
    followPixels(image,dir,prefix+item.name+"-intrinsic",out);out << '}';
    Bitmap output(width,height,PixelFormat32bppARGB);check(output.GetLastStatus(),"replay allocation");
    check(output.SetResolution(96,96),"replay DPI");
    Status drawn;
    {
        Graphics graphics(&output);check(graphics.Clear(Color(0,0,0,0)),"replay clear");
        check(graphics.SetCompositingMode(CompositingModeSourceCopy),"replay compositing");
        check(graphics.SetInterpolationMode(InterpolationModeDefault),"Picture interpolation");
        check(graphics.SetPixelOffsetMode(PixelOffsetModeHalf),"Picture pixel offset");
        ImageAttributes attributes;check(attributes.SetWrapMode(WrapModeTileFlipXY),"Picture wrap");
        drawn=graphics.DrawImage(&image,Rect(0,0,INT(width),INT(height)),0,0,INT(width),INT(height),UnitPixel,&attributes);
    }
    out << ",\"drawStatus\":" << drawn;
    if (drawn == Ok) followPixels(output,dir,prefix+item.name,out);
}
int main(int argc,char** argv){if(argc!=3)return 2;try{std::string mode=argv[1];if(mode!="generate"&&mode!="direct-v1"&&mode!="replay"&&mode!="replay-v1")return 2;bool v1=mode=="direct-v1"||mode=="replay-v1";Startup startup(v1?1:2);findPNGEncoder();fs::path dir=fs::absolute(argv[2]);fs::create_directories(dir);auto inventory=followCases();auto out=file(dir/(mode+".json"));wchar_t path[32768]{};DWORD length=GetModuleFileNameW(GetModuleHandleW(L"gdiplus.dll"),path,32768);if(!length||length>=32768)throw std::runtime_error("cannot identify GDI+");out<<"{\"platform\":\"native Windows GDI+\",\"startupVersion\":"<<(v1?1:2)<<",\"gdiplusModule\":"<<json(fs::path(path).u8string())<<",\"mode\":"<<json(mode)<<",\"caseCount\":"<<inventory.size()<<",\"format\":\"straight RGBA row-major top-left\",\"atlases\":[";bool first=true;
    for(const auto& c:inventory){if(!first)out<<',';first=false;out<<"{\"name\":"<<json(c.name);if(mode=="generate"){auto image=followAtlas(c);followPixels(*image,dir,"atlas-"+c.name,out);auto bytes=file(dir/("atlas-"+c.name+"-requested.rgba"),true);for(UINT y=0;y<followHeight(c);++y)for(UINT x=0;x<followWidth(c);++x){Color p=followColor(c,x,y);BYTE raw[]={p.GetR(),p.GetG(),p.GetB(),p.GetA()};bytes.write(reinterpret_cast<const char*>(raw),4);}}out<<'}';}out<<"],\"cases\":[";first=true;bool failed=false;
    for(const auto& c:inventory){if(!first)out<<',';first=false;std::string prefix=mode=="generate"?"":mode+"-";out<<"{\"name\":"<<json(prefix+c.name);c.describe(out);std::ostringstream detail;try{if(mode=="generate"||mode=="direct-v1"){if(mode=="generate")followEffect(c,[&](auto& e,Status s){detail<<",\"recordSetParametersStatus\":"<<s;if(s==Ok)followRecord(c,e,dir,detail);});detail<<",\"direct\":{\"name\":"<<json(prefix+c.name);followEffect(c,[&](auto& e,Status s){detail<<",\"setParametersStatus\":"<<s;if(s==Ok)followDirect(c,e,dir,prefix+c.name,false,detail);});detail<<"},\"created\":{\"name\":"<<json(prefix+"created-"+c.name);followEffect(c,[&](auto& e,Status s){detail<<",\"setParametersStatus\":"<<s;if(s==Ok)followDirect(c,e,dir,prefix+"created-"+c.name,true,detail);});detail<<'}';}else{followReplay(c,dir,prefix,detail);}}catch(const std::exception& error){detail.str("");detail.clear();detail<<",\"error\":"<<json(error.what());failed=true;}out<<detail.str()<<'}';out.flush();}out<<"]}\n";out.close();return failed?1:0;
}catch(const std::exception& e){std::cerr<<e.what()<<'\n';return 1;}}
