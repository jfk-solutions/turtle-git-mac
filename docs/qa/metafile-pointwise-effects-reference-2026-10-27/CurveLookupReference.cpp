// Original bounded native Windows source-contract assay. No port formula.
// Reuse only the established source atlas/pixel writer/Bitmap replay helpers.
#define main TurtleGitEarlierPointwiseReferenceMain
#include "PointwiseEffectsReference.cpp"
#undef main

static std::unique_ptr<Bitmap> curveRamp() {
    auto image=std::make_unique<Bitmap>(32,8,PixelFormat32bppARGB);
    check(image->GetLastStatus(),"curve ramp allocation");
    check(image->SetResolution(96,96),"curve ramp DPI");
    // Each channel independently visits all256 values. Blue73 is invertible
    // modulo256; distinct channels expose accidental shared-channel routing.
    for(UINT i=0;i<256;++i)check(image->SetPixel(i%32,i/32,Color(255,BYTE(i),BYTE(255-i),BYTE((i*73)&255))),"curve ramp pixel");
    return image;
}
static void lookup(const fs::path& dir,const std::string& mode,std::ostream& report) {
    auto binary=file(dir/(mode+".bin"),true);
    UINT offset=0,count=0;bool first=true;
    report << ",\"format\":\"one256-byte channel LUT per(mode,intensity), no interpolation; BGR routing independently verified for all4 channel enums\",\"binary\":" << json(mode+".bin") << ",\"cases\":[";
    for(int adjustment=0;adjustment<8;++adjustment) {
        const int low=adjustment<2 ? -255:adjustment<6 ? -100:adjustment==6 ? 1:0;
        const int high=adjustment<2 ? 255:adjustment<6 ? 100:adjustment==6 ? 255:254;
        for(int value=low;value<=high;++value) {
            if(!first)report << ',';first=false;
            report << "{\"adjustment\":" << adjustment << ",\"adjustValue\":" << value << ",\"offset\":" << offset << ",\"length\":256,\"channels\":[";
            std::array<BYTE,256> expected{};
            for(int channel=0;channel<4;++channel) {
                if(channel)report << ',';
                ColorCurveParams params{static_cast<CurveAdjustments>(adjustment),static_cast<CurveChannel>(channel),value};
                ColorCurve effect;const Status set=effect.SetParameters(&params);
                report << "{\"channel\":" << channel << ",\"setParametersStatus\":" << set;
                if(set!=Ok)throw std::runtime_error("Valid finite-domain curve parameter refused");
                effect.UseAuxData(TRUE);auto image=curveRamp();const Status applied=image->ApplyEffect(&effect,nullptr);
                report << ",\"applyStatus\":" << applied << ",\"auxBytes\":" << effect.GetAuxDataSize();
                if(applied!=Ok || effect.GetAuxDataSize()!=1024 || !effect.GetAuxData())throw std::runtime_error("Curve LUT capture failed");
                const BYTE* tables=static_cast<const BYTE*>(effect.GetAuxData());
                if(channel==0)std::copy(tables,tables+256,expected.begin());
                UINT routingErrors=0,pixelErrors=0;
                for(UINT component=0;component<4;++component)for(UINT input=0;input<256;++input) {
                    // Native table order B,G,R,A; enum1/2/3 selects R/G/B.
                    const bool selected=component<3 && (channel==0 || component==UINT(3-channel));
                    const BYTE wanted=selected ? expected[input]:BYTE(input);
                    if(tables[component*256+input]!=wanted)++routingErrors;
                }
                for(UINT i=0;i<256;++i) {
                    Color actual;check(image->GetPixel(i%32,i/32,&actual),"curve actual pixel");
                    const BYTE source[]={BYTE(i),BYTE(255-i),BYTE((i*73)&255),255};
                    const BYTE observed[]={actual.GetR(),actual.GetG(),actual.GetB(),actual.GetA()};
                    for(UINT component=0;component<4;++component) {
                        const bool selected=component<3 && (channel==0 || component==UINT(channel-1));
                        const BYTE wanted=selected ? expected[source[component]]:source[component];
                        if(observed[component]!=wanted)++pixelErrors;
                    }
                }
                report << ",\"routingErrors\":" << routingErrors << ",\"actualPixelErrors\":" << pixelErrors << '}';
                if(routingErrors || pixelErrors)throw std::runtime_error("Curve table or actual channel routing proof failed");
            }
            report << "]}";binary.write(reinterpret_cast<const char*>(expected.data()),256);offset+=256;++count;report.flush();
        }
    }
    binary.close();
    report << "],\"caseCount\":" << count << ",\"bytes\":" << offset;
    if(count!=2336 || offset!=598016 || fs::file_size(dir/(mode+".bin"))!=offset)throw std::runtime_error("Incomplete finite curve domain");
}
static void states(const fs::path& dir,const std::string& mode,std::ostream& report) {
    std::vector<fs::path> paths;
    for(const auto& entry:fs::directory_iterator(dir)) {
        const auto name=entry.path().filename().string();
        if(entry.path().extension()==L".emf" && name.rfind("state-",0)==0)paths.push_back(entry.path());
    }
    std::sort(paths.begin(),paths.end());
    if(paths.size()!=3)throw std::runtime_error("Expected exactly three authored state witnesses");
    report << ",\"caseCount\":3,\"cases\":[";bool first=true;
    for(const auto& path:paths) {
        if(!first)report << ',';first=false;
        const Case item{Family::curve,{0,0,0},path.stem().string()};
        report << "{\"name\":" << json(mode+"-"+item.name) << ",\"source\":" << json(path.filename().string()) << ",\"observation\":\"pending-effect interposition; no behavior presumed\"";
        try {replay(item,dir,mode+"-",report);}catch(const std::exception& error){report << ",\"error\":" << json(error.what());}
        report << '}';report.flush();
    }
    report << ']';
}
int main(int argc,char** argv) {
    if(argc!=3)return 2;
    try {
        const std::string mode=argv[1];
        if(mode!="lookup-v1" && mode!="lookup-v2" && mode!="states-v1" && mode!="states-v2")return 2;
        const bool versionOne=mode=="lookup-v1" || mode=="states-v1";
        Startup startup(versionOne ? 1:2);findPNGEncoder();
        const fs::path dir=fs::absolute(argv[2]);fs::create_directories(dir);
        auto report=file(dir/(mode+".json"));
        wchar_t module[32768]{};const DWORD length=GetModuleFileNameW(GetModuleHandleW(L"gdiplus.dll"),module,32768);
        if(!length || length>=32768)throw std::runtime_error("Cannot identify native GDI+ module");
        report << "{\"platform\":\"native Windows GDI+\",\"startupVersion\":" << (versionOne?1:2) << ",\"gdiplusModule\":" << json(fs::path(module).u8string()) << ",\"mode\":" << json(mode);
        if(mode.rfind("lookup",0)==0)lookup(dir,mode,report);else states(dir,mode,report);
        report << "}\n";report.close();return 0;
    }catch(const std::exception& error){std::cerr << error.what() << '\n';return 1;}
}
