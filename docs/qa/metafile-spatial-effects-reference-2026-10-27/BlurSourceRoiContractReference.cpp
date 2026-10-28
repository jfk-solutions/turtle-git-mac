// Original bounded SDK source-rectangle recording discriminator.
// Four source-contract witnesses plus one contained control; no prior recapture.
#ifndef NOMINMAX
#define NOMINMAX
#endif
#define main unusedPointwiseReferenceMain
#include "../metafile-pointwise-effects-reference-2026-10-27/PointwiseEffectsReference.cpp"
#undef main
#include <vector>

struct BlurSourceRoiCase {
    const char* name;
    const char* purpose;
    REAL x,y,width,height;
    bool control;
};
static const std::vector<BlurSourceRoiCase> blurSourceRoiCases={
    {"blur-roi-fully-outside","Visible source ends before the bitmap; distinguish no-paint from transparent SourceCopy",-8,6,4,12,false},
    {"blur-roi-exact-touch","Visible source right endpoint is exactly zero; inclusive extra working sample must not invent visible intersection",-6,6,6,12,false},
    {"blur-roi-partial-right-bottom","Source begins inside and extends beyond right and bottom; distinguish cropped-zero halo from surrounding-source reads",24,25,12,11,false},
    {"blur-roi-negative-left-top","Source crosses left and top while both far endpoints remain inside; distinguish cropped-branch selection",-4,-3,18,19,false},
    {"blur-roi-contained-control","Contained integer ROI transport control",4,6,17,19,true}
};
static Color blurSourceColor(UINT x,UINT y) {
    // Same independently authored asymmetric source as retained Blur controls.
    return Color(255,BYTE(11*x+53*y),BYTE(43*x+7*y),BYTE(19*x+37*y));
}
static std::unique_ptr<Bitmap> blurSourceAtlas() {
    auto image=std::make_unique<Bitmap>(32,32,PixelFormat32bppARGB);
    check(image->GetLastStatus(),"source allocation");check(image->SetResolution(96,96),"source DPI");
    for(UINT y=0;y<32;++y)for(UINT x=0;x<32;++x)check(image->SetPixel(x,y,blurSourceColor(x,y)),"source pixel");
    return image;
}
static void blurSourcePixels(Bitmap& image,const fs::path& directory,std::ostream& report) {
    check(image.Save((directory/"atlas-blur-source-roi.png").c_str(),&pngEncoder,nullptr),"save source PNG");
    auto actual=file(directory/"atlas-blur-source-roi.rgba",true);
    auto requested=file(directory/"atlas-blur-source-roi-requested.rgba",true);
    bool identical=true;
    for(UINT y=0;y<32;++y)for(UINT x=0;x<32;++x) {
        Color observed;check(image.GetPixel(x,y,&observed),"source observation");const Color authored=blurSourceColor(x,y);
        identical=identical&&observed.GetValue()==authored.GetValue();
        const BYTE observedBytes[]={observed.GetR(),observed.GetG(),observed.GetB(),observed.GetA()};
        const BYTE requestedBytes[]={authored.GetR(),authored.GetG(),authored.GetB(),authored.GetA()};
        actual.write(reinterpret_cast<const char*>(observedBytes),4);requested.write(reinterpret_cast<const char*>(requestedBytes),4);
    }
    report<<"{\"name\":\"blur-source-roi\",\"width\":32,\"height\":32,\"png\":\"atlas-blur-source-roi.png\",\"rgba\":\"atlas-blur-source-roi.rgba\",\"requestedRGBA\":\"atlas-blur-source-roi-requested.rgba\",\"requestedMatchesObserved\":"<<(identical?"true":"false")<<'}';
    if(!identical)throw std::runtime_error("source differs from authored pixels");
}
static void recordBlurSourceRoi(const BlurSourceRoiCase& item,const fs::path& directory,std::ostream& out) {
    BlurParams parameters{2.f,TRUE};Blur effect;
    const Status parameterStatus=effect.SetParameters(&parameters);
    out<<",\"recordSetParametersStatus\":"<<parameterStatus;check(parameterStatus,"Blur parameters");
    ScreenDC screen;
    Metafile image((directory/(std::string(item.name)+".emf")).c_str(),screen.value,RectF(0,0,64,64),MetafileFrameUnitPixel,EmfTypeEmfPlusOnly,L"Original SDK Blur source ROI SourceCopy contract");
    const Status createStatus=image.GetLastStatus();out<<",\"recordCreateStatus\":"<<createStatus;check(createStatus,"record allocation");
    Graphics graphics(&image);check(graphics.GetLastStatus(),"record graphics");
    check(graphics.SetPageUnit(UnitPixel),"record pixel units");
    check(graphics.SetCompositingMode(CompositingModeSourceCopy),"record SourceCopy");
    check(graphics.Clear(Color(0,0,0,0)),"record transparent clear");
    SolidBrush sentinel(Color(255,17,41,73));check(sentinel.GetLastStatus(),"sentinel brush");
    const Status sentinelStatus=graphics.FillRectangle(&sentinel,0,0,64,64);
    out<<",\"recordSentinelStatus\":"<<sentinelStatus;check(sentinelStatus,"prior sentinel paint");
    auto input=blurSourceAtlas();RectF source(item.x,item.y,item.width,item.height);Matrix placement(1,0,0,1,16,16);
    check(placement.GetLastStatus(),"record placement");
    const Status drawStatus=graphics.DrawImage(input.get(),&source,&placement,&effect,nullptr,UnitPixel);
    // Out-of-bounds statuses are observations, not assumed successful draws.
    // Preserve the original SDK wire and sentinel even when recording rejects it.
    out<<",\"recordStatus\":"<<drawStatus<<",\"recordDrawReturnedOk\":"<<(drawStatus==Ok?"true":"false");
    if(item.control)check(drawStatus,"contained control draw");
}
int main(int argc,char** argv) {
    if(argc!=2)return 2;
    try {
        Startup startup(2);findPNGEncoder();
        const fs::path directory=fs::absolute(argv[1]);fs::create_directories(directory);
        auto out=file(directory/"generate-blur-roi.json");
        wchar_t module[32768]{};const DWORD length=GetModuleFileNameW(GetModuleHandleW(L"gdiplus.dll"),module,32768);
        if(!length||length>=32768)throw std::runtime_error("cannot identify GDI+");
        if(blurSourceRoiCases.size()!=5)throw std::runtime_error("bounded ROI inventory changed");
        out<<"{\"platform\":\"native Windows GDI+ SDK recording only\",\"startupVersion\":2,\"gdiplusModule\":"<<json(fs::path(module).u8string())
           <<",\"caseCount\":5,\"plannedCaseCount\":4,\"controlCount\":1,\"format\":\"straight RGBA row-major top-left\",\"atlases\":[";
        auto atlas=blurSourceAtlas();blurSourcePixels(*atlas,directory,out);
        out<<"],\"cases\":[";bool first=true;
        for(const auto& item:blurSourceRoiCases) {
            if(!first)out<<',';first=false;
            out<<"{\"name\":"<<json(item.name)<<",\"purpose\":"<<json(item.purpose)<<",\"family\":\"blur\",\"emf\":"<<json(std::string(item.name)+".emf")
               <<",\"atlas\":\"blur-source-roi\",\"sourceWidth\":32,\"sourceHeight\":32,\"parameters\":{\"radius\":2,\"expandEdge\":true},\"recordSourceRect\":["<<item.x<<','<<item.y<<','<<item.width<<','<<item.height
               <<"],\"recordImageMatrix\":[1,0,0,1,16,16],\"recordFrameWidth\":64,\"recordFrameHeight\":64,\"recordCompositing\":\"SourceCopy\",\"priorPaintRGBA\":[17,41,73,255],\"control\":"<<(item.control?"true":"false");
            recordBlurSourceRoi(item,directory,out);out<<'}';out.flush();
        }
        out<<"]}\n";out.close();return 0;
    }catch(const std::exception& error){std::cerr<<error.what()<<'\n';return 1;}
}
