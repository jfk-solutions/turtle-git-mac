#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <cstdio>
#include <cstring>
#include <vector>
#include <algorithm>
struct Transform {const char*name;XFORM x;};
int main(){
 const Transform transforms[]={{"identity",{1,0,0,1,0,0}},{"enlarge3",{3,0,0,3,0,0}},{"shrinkQuarter",{.25f,0,0,.25f,0,0}},{"anisotropic",{3,0,0,.25f,0,0}},{"rotate45",{.70710677f,.70710677f,-.70710677f,.70710677f,0,0}},{"shear",{1,1.5f,.25f,1,0,0}}};
 HDC dc=CreateCompatibleDC(NULL);if(!dc)return 2;SetGraphicsMode(dc,GM_ADVANCED);
 int count=0;puts("{\"scope\":\"Finite native GDI WidenPath eligibility only; no pixels or TurtleGit runtime\",\"cases\":[");
 auto observe=[&](const Transform&t,int width,const char*kind,bool vertical=false){
  SetWorldTransform(dc,&t.x);HPEN pen=NULL;bool owned=true;
  if(!strcmp(kind,"geometric")){LOGBRUSH b={BS_SOLID,RGB(255,0,0),0};pen=ExtCreatePen(PS_GEOMETRIC|PS_SOLID,width,&b,0,NULL);}
  else if(!strcmp(kind,"cosmetic")){LOGBRUSH b={BS_SOLID,RGB(255,0,0),0};pen=ExtCreatePen(PS_COSMETIC|PS_SOLID,1,&b,0,NULL);}
  else if(!strcmp(kind,"stock")){pen=(HPEN)GetStockObject(BLACK_PEN);owned=false;}
  else if(!strcmp(kind,"null")){pen=CreatePen(PS_NULL,width,RGB(255,0,0));}
  else pen=CreatePen(PS_SOLID,width,RGB(255,0,0));
  if(!pen)ExitProcess(3);HGDIOBJ old=SelectObject(dc,pen);POINT mapped[2]={{0,0},{width,0}};LPtoDP(dc,mapped,2);
  BOOL begin=BeginPath(dc),m=MoveToEx(dc,8,16,NULL),l=LineTo(dc,vertical?8:48,vertical?48:16),end=EndPath(dc);SetLastError(0);BOOL result=WidenPath(dc);DWORD error=GetLastError();int n=GetPath(dc,NULL,NULL,0);RECT bounds={0,0,0,0};
  if(n>0){std::vector<POINT>p(n);std::vector<BYTE>b(n);GetPath(dc,p.data(),b.data(),n);bounds={p[0].x,p[0].y,p[0].x,p[0].y};for(auto q:p){bounds.left=std::min(bounds.left,q.x);bounds.top=std::min(bounds.top,q.y);bounds.right=std::max(bounds.right,q.x);bounds.bottom=std::max(bounds.bottom,q.y);}}
  printf("%s{\"transform\":\"%s\",\"kind\":\"%s\",\"logicalWidth\":%d,\"vertical\":%s,\"widen\":%d,\"lastError\":%lu,\"devicePoints\":[",count++?",\n":"",t.name,kind,width,vertical?"true":"false",!!result,error);
  XFORM identity={1,0,0,1,0,0};SetWorldTransform(dc,&identity);
  if(n>0){std::vector<POINT>p(n);std::vector<BYTE>b(n);GetPath(dc,p.data(),b.data(),n);for(int k=0;k<n;k++)printf("%s[%ld,%ld,%u]",k?",":"",p[k].x,p[k].y,b[k]);}
  puts("]}");
  AbortPath(dc);SelectObject(dc,old);if(owned)DeleteObject(pen);
 };
 for(int index:{3,5,2})for(bool vertical:{false,true})observe(transforms[index],2,"classic",vertical);
 for(bool vertical:{false,true})observe(transforms[3],1,"classic",vertical);
 for(bool vertical:{false,true})observe(transforms[5],1,"classic",vertical);
 observe(transforms[1],1,"classic");observe(transforms[0],0,"classic");observe(transforms[0],1,"stock");observe(transforms[0],2,"null");
 printf("\n],\"count\":%d}\n",count);DeleteDC(dc);return 0;
}
