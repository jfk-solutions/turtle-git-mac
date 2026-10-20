#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Original classic EMF mask, key and alpha records; no renderer is executed.
MS-EMF 2.3.1.1/.3/.4/.8. Sizes/offsets include the eight-byte record header.
ROP4 matrix P=F0,S=CC,D=AA yields foreground n and background 255-n.
"""
import pathlib, struct
P=pathlib.Path(__file__).parent
U=lambda *v:struct.pack('<'+'I'*len(v),*v)
I=lambda *v:struct.pack('<'+'i'*len(v),*v)
H=lambda *v:struct.pack('<'+'H'*len(v),*v)
F=lambda *v:struct.pack('<'+'f'*len(v),*v)
def record(t,b=b''):
 b+=b'\0'*((-len(b))%4);return U(t,len(b)+8)+b
def write(name,records):
 records=[*records,record(14,U(0,0,20))]
 h=U(1,88)+I(0,0,64,64)+I(0,0,1693,1693)+U(0x464d4520,0x10000,88+sum(map(len,records)),len(records)+1)+H(32,0)+U(0,0,0)+I(960,960,254,254)
 (P/(name+'.emf')).write_bytes(h+b''.join(records))
def brush(handle,rgb):return record(39,U(handle,0,rgb[0]|rgb[1]<<8|rgb[2]<<16,0))
def select(handle):return record(37,U(handle))
def rect(x,y,w,h):return record(43,I(x,y,x+w,y+h))
def base(rgb=(0,0,255),pattern=(240,240,240)):
 return [select(0x80000008),brush(1,rgb),select(1),rect(0,0,64,64),brush(2,pattern),select(2)]
def dib(w,h,pixel,depth=32,bottom=False,palette=None):
 stride=((w*depth+31)//32)*4;rows=[]
 for y in (range(h-1,-1,-1) if bottom else range(h)):
  row=bytearray(stride)
  for x in range(w):
   value=pixel(x,y)
   if depth==1:row[x//8]|=value<<(7-x%8)
   elif depth==8:row[x]=value
   else:
    r,g,b,*alpha=value;row[x*(depth//8):x*(depth//8)+depth//8]=bytes([b,g,r]+([alpha[0] if alpha else 0] if depth==32 else []))
  rows.append(bytes(row))
 bits=b''.join(rows);colors=palette or ([(0,0,0),(255,255,255)] if depth==1 else [])
 table=b''.join(bytes([b,g,r,0]) for r,g,b in colors)
 return U(40)+I(w,h if bottom else -h)+H(1,depth)+U(0,len(bits),0,0,len(colors),0)+table,bits
def transfer(t,source,mask=None,*,x=8,y=8,w=32,h=32,sx=0,sy=0,sw=32,sh=32,fg=204,bg=170,reserved=0,mx=0,my=0,points=((8,8),(40,16),(16,40)),blend=0x01ff0000,key=0xff,transform=(1,0,0,1,0,0),mask_first=False,mask_usage=0):
 plg=t==79;masked=t in [78,79];fixed=140 if plg else 128 if masked else 108
 sb,sp=source if source else (b'',b'');mb,mp=mask if mask else (b'',b'')
 chunks=[('mask',mb,mp),('source',sb,sp)] if mask_first else [('source',sb,sp),('mask',mb,mp)]
 offsets={};data=b''
 for name,bmi,bits in chunks:
  offsets[name]=(fixed+len(data),len(bmi),fixed+len(data)+len(bmi),len(bits)) if bmi else (0,0,0,0)
  data+=bmi+bits
 if plg:body=I(0,0,64,64)+I(*(v for p in points for v in p))+I(sx,sy,sw,sh)+F(*transform)+U(0,0,*offsets['source'])
 else:
  code=(bg<<24)|(fg<<16)|reserved if masked else blend if t==114 else key
  body=I(0,0,64,64)+I(x,y,w,h)+U(code)+I(sx,sy)+F(*transform)+U(0,0,*offsets['source'])
  if not masked:body+=I(sw,sh)
 if masked:body+=I(mx,my)+U(mask_usage,*offsets['mask'])
 assert len(body)==fixed-8
 return record(t,body+data)
red=dib(32,32,lambda x,y:(255,0,0));half=dib(32,32,lambda x,y:int(x<16),1)
write('classic-maskblt-copy',base()+[transfer(78,red,half)])
write('classic-maskblt-default-destination',[transfer(78,red,half)])
write('classic-maskblt-unused-mask-palette',base()+[transfer(78,red,(half[0][:40]+H(65535,65534),half[1]),mask_usage=1)])
write('classic-maskblt-swapped-palette',base()+[transfer(78,red,dib(32,32,lambda x,y:int(x<16),1,palette=[(255,255,255),(0,0,0)]),reserved=0x1234,mask_first=True)])
write('classic-maskblt-matrix',base((170,170,170))+[transfer(78,dib(4,4,lambda x,y:(204,204,204)),dib(4,4,lambda x,y:int(x<2),1),x=(n%16)*4,y=(n//16)*4,w=4,h=4,sw=4,sh=4,fg=n,bg=255-n) for n in range(256)])
write('classic-maskblt-no-mask',base((170,170,170))+[select(0x80000005),transfer(78,None,fg=85,bg=204,reserved=0x9137,transform=(float('nan'),0,0,1,0,0))])
write('classic-maskblt-no-source',base((170,170,170))+[transfer(78,None,half,fg=240,bg=85,transform=(float('nan'),0,0,1,0,0))])
write('classic-maskblt-crop-edge',base()+[record(35,F(1,0,0,1,.25,0)),transfer(78,dib(32,8,lambda x,y:(255,0,0) if 8<=x<16 else (0,255,0)),x=8,y=8,w=8,h=8,sx=8,sw=8,sh=8)])
write('classic-maskblt-offset',base()+[transfer(78,red,dib(40,32,lambda x,y:int(x<16),1),mx=8)])
write('classic-plgblt-mask-shear',base()+[record(33),record(30,I(0,0,28,64)),transfer(79,red,dib(8,8,lambda x,y:int(x<4),1)),record(34,I(-1)),transfer(78,dib(8,8,lambda x,y:(0,255,0)),x=48,y=8,w=8,h=8,sw=8,sh=8)])
write('classic-plgblt-mask-mirror',base()+[transfer(79,red,half,points=((48,8),(16,8),(48,40)))])
write('classic-plgblt-no-mask',base()+[transfer(79,red,None,points=((8,8),(40,8),(8,40)))])
key_source=dib(32,32,lambda x,y:(255,0,0) if x<16 else (0,255,0),24)
write('classic-transparentblt-key',base()+[transfer(116,key_source)])
write('classic-transparentblt-indexed',base()+[transfer(116,dib(32,32,lambda x,y:int(x>=16),8,palette=[(255,0,0),(0,255,0)]))])
write('classic-transparentblt-crop-bottom-up',base()+[record(33),record(35,F(1,0,0,1,8,0)),transfer(116,dib(48,32,lambda x,y:((0,255,0) if y<16 else (255,255,0)) if x>=24 else (255,0,0),24,True),x=0,sx=8,w=32,sw=32),record(34,I(-1))])
write('classic-alphablend-pixel',base()+[transfer(114,dib(32,32,lambda x,y:(128,0,0,128)))])
write('classic-alphablend-constant',base()+[transfer(114,red,blend=0x00800000)])
write('classic-alphablend-both',base()+[transfer(114,dib(32,32,lambda x,y:(128,0,0,128)),blend=0x01800000)])
write('classic-alphablend-zero',base()+[transfer(114,dib(32,32,lambda x,y:(0,0,0,0)),blend=0x01ff0000)])
write('classic-alphablend-ignored-flags',base()+[transfer(114,red,blend=0x00ff7f00)])
# Invalid variants have complete outer framing. A later painted rectangle must
# never hide these refusals with plausible partial output.
bad={
 'mask-color':transfer(78,red,dib(32,32,lambda x,y:(255,255,255))),
 'mask-outside':transfer(78,red,half,mx=1),
 'source-missing':transfer(78,None,half),
 'pattern-missing':transfer(78,None,half,fg=240,bg=170),
 'alpha-operation':transfer(114,red,blend=0x01ff0001),
 'alpha-format':transfer(114,red,blend=0x02ff0000),
 'alpha-premultiplication':transfer(114,red),
 'alpha-depth':transfer(114,key_source),
 'alpha-negative':transfer(114,red,w=-32),
 'alpha-source-outside':transfer(114,red,sx=1),
 'transparent-negative':transfer(116,key_source,sw=-32),
 'transparent-colorref':transfer(116,key_source,key=0x010000ff),
 'source-shear':transfer(116,key_source,transform=(1,1,0,1,0,0)),
 'plg-singular':transfer(79,red,half,points=((8,8),(16,16),(24,24))),
 'plg-mask-color':transfer(79,red,red),
}
for name,body in bad.items():write('unsupported-transfer-'+name,base()+([select(0x80000005)] if name=='pattern-missing' else [])+[body,rect(0,0,64,64)])
for name,offset,value in [('source-offset',84,100),('mask-offset',112,120),('source-truncated',96,1)]:
 body=bytearray(transfer(78,red,half));struct.pack_into('<I',body,offset,value);write('unsupported-transfer-'+name,base()+[bytes(body)])
