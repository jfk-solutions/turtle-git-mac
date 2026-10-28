// Original playback-only state discriminator. No image/effect generators run.
#ifndef NOMINMAX
#define NOMINMAX
#endif
#define main unusedPointwisePlaybackTransportMain
#include "../metafile-pointwise-effects-reference-2026-10-27/PointwiseEffectsReference.cpp"
#undef main

static void playbackPixels(Bitmap& image,const fs::path& destination,const std::string& stem,std::ostream& out) {
    const UINT width=image.GetWidth(),height=image.GetHeight();check(image.GetLastStatus(),"pixel dimensions");
    if((width!=32&&width!=64)||height!=width)throw std::runtime_error("unexpected retained input frame");
    check(image.Save((destination/(stem+".png")).c_str(),&pngEncoder,nullptr),"save observation PNG");
    auto rgba=file(destination/(stem+".rgba"),true);
    for(UINT y=0;y<height;++y)for(UINT x=0;x<width;++x) {
        Color color;check(image.GetPixel(x,y,&color),"observe pixel");
        const BYTE bytes[]={color.GetR(),color.GetG(),color.GetB(),color.GetA()};
        rgba.write(reinterpret_cast<const char*>(bytes),sizeof(bytes));
    }
    out<<",\"width\":"<<width<<",\"height\":"<<height<<",\"rgba\":"<<json(stem+".rgba")<<",\"png\":"<<json(stem+".png");
}
static void playbackFile(const fs::path& input,const fs::path& destination,const std::string& stem,UINT expectedSide,std::ostream& out) {
    // Picture.cpp415/Picture.h197 use the default version1 startup. This is
    // the Bitmap(filename,FALSE) consumer, not Metafile/SDK direct ApplyEffect.
    Bitmap image(input.c_str(),FALSE);
    const auto loadStatus=image.GetLastStatus();out<<",\"bitmapLoadStatus\":"<<loadStatus;check(loadStatus,"Bitmap file consumer");
    const UINT width=image.GetWidth(),height=image.GetHeight();check(image.GetLastStatus(),"intrinsic dimensions");
    if(width!=expectedSide||height!=expectedSide)throw std::runtime_error("unexpected intrinsic frame");
    Bitmap output(width,height,PixelFormat32bppARGB);check(output.GetLastStatus(),"destination allocation");
    check(output.SetResolution(96,96),"destination DPI");
    Status drawStatus=GenericError;
    {
        Graphics graphics(&output);check(graphics.GetLastStatus(),"destination graphics");
        check(graphics.Clear(Color(0,0,0,0)),"transparent destination");
        check(graphics.SetCompositingMode(CompositingModeSourceCopy),"Picture source copy");
        check(graphics.SetInterpolationMode(InterpolationModeDefault),"Picture interpolation");
        check(graphics.SetPixelOffsetMode(PixelOffsetModeHalf),"Picture pixel offset");
        ImageAttributes attributes;check(attributes.SetWrapMode(WrapModeTileFlipXY),"Picture wrap");
        drawStatus=graphics.DrawImage(&image,Rect(0,0,INT(width),INT(height)),0,0,INT(width),INT(height),UnitPixel,&attributes);
    }
    out<<",\"drawStatus\":"<<drawStatus;check(drawStatus,"Picture draw");
    out<<",\"final\":{\"name\":"<<json(stem);playbackPixels(output,destination,stem,out);out<<'}';
    // Observe the intrinsic bitmap only after the actual Picture draw. Saving
    // or GetPixel before DrawImage could force lazy decoding or affect process
    // state and would no longer measure the consumer's first use of this file.
    out<<",\"intrinsic\":{\"name\":"<<json(stem+"-intrinsic");playbackPixels(image,destination,stem+"-intrinsic",out);out<<'}';
}
int main(int argc,char** argv) {
    if(argc<4||argc>6)return 2;
    try {
        const fs::path destination=fs::u8path(argv[1]);const std::string label=argv[2];
        if(label.empty()||label.size()>64||label.find_first_not_of("abcdefghijklmnopqrstuvwxyz0123456789-")!=std::string::npos)return 2;
        fs::create_directories(destination);Startup startup(1);findPNGEncoder();
        wchar_t module[MAX_PATH]{};if(!GetModuleFileNameW(GetModuleHandleW(L"gdiplus.dll"),module,MAX_PATH))throw std::runtime_error("GDI+ module unavailable");
        auto out=file(destination/(label+".json"));
        out<<"{\"platform\":\"native Windows GDI+\",\"startupVersion\":1,\"startupStatus\":0,\"processID\":"<<GetCurrentProcessId()
           <<",\"gdiplusModule\":"<<json(fs::path(module).u8string())<<",\"label\":"<<json(label)<<",\"caseCount\":"<<argc-3
           <<",\"format\":\"straight RGBA row-major top-left\",\"cases\":[";
        bool failed=false;
        for(int i=3;i<argc;++i) {
            if(i>3)out<<',';
            const fs::path input=fs::u8path(argv[i]);const auto name=input.filename().u8string();
            out<<"{\"file\":"<<json(name)<<",\"order\":"<<i-3;
            try {
                const bool retained=name=="followup-solid-pure-red.emf"||name=="detector-color-pure-red.emf"||name=="redeye-17.emf";
                const bool blur=name=="blur-roi-fully-outside.emf"||name=="blur-roi-exact-touch.emf"||name=="blur-roi-partial-right-bottom.emf"||name=="blur-roi-negative-left-top.emf"||name=="blur-roi-contained-control.emf";
                if(!retained&&!blur)throw std::runtime_error("input outside approved inventory");
                if(fs::file_size(input)>(retained?4096:16384))throw std::runtime_error("input size exceeds bounded wire inventory");
                playbackFile(input,destination,label+"-"+std::to_string(i-3),blur?64:32,out);
            } catch(const std::exception& error) {out<<",\"error\":"<<json(error.what());failed=true;}
            out<<'}';
        }
        out<<"]}\n";out.close();return failed?1:0;
    } catch(const std::exception& error) {std::cerr<<error.what()<<'\n';return 1;}
}
