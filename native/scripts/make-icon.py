from PIL import Image, ImageDraw, ImageFilter
S=4; N=1024*S
def lerp(a,b,t): return tuple(int(a[i]+(b[i]-a[i])*t) for i in range(3))
img=Image.new("RGBA",(N,N),(0,0,0,0))
# Apple grid: 824 body inset 100, corner ~185
x0,y0,x1,y1=100*S,100*S,924*S,924*S; r=185*S
# shadow
sh=Image.new("RGBA",(N,N),(0,0,0,0)); d=ImageDraw.Draw(sh)
d.rounded_rectangle((x0,y0+14*S,x1,y1+14*S),r,fill=(0,0,0,110))
sh=sh.filter(ImageFilter.GaussianBlur(18*S)); img=Image.alpha_composite(img,sh)
# gradient body
grad=Image.new("RGBA",(N,N)); gd=ImageDraw.Draw(grad)
top,bot=(46,43,95),(18,18,38)
for y in range(N): gd.line([(0,y),(N,y)],fill=lerp(top,bot,y/N)+(255,))
mask=Image.new("L",(N,N),0); ImageDraw.Draw(mask).rounded_rectangle((x0,y0,x1,y1),r,fill=255)
body=Image.new("RGBA",(N,N),(0,0,0,0)); body.paste(grad,(0,0),mask); img=Image.alpha_composite(img,body)
# speech bubble
b=Image.new("RGBA",(N,N),(0,0,0,0)); bd=ImageDraw.Draw(b)
bx0,by0,bx1,by1=215*S,270*S,809*S,700*S
bd.rounded_rectangle((bx0,by0,bx1,by1),150*S,fill=(245,246,252,255))
bd.polygon([(330*S,650*S),(300*S,815*S),(470*S,690*S)],fill=(245,246,252,255))
img=Image.alpha_composite(img,b)
# waveform bars (cyan->violet), like the app meter
d=ImageDraw.Draw(img)
heights=[70,150,250,330,230,300,180,110,60]
n=len(heights); w=34*S; gap=24*S
total=n*w+(n-1)*gap; sx=(1024*S-total)//2; cy=485*S
for i,h in enumerate(heights):
    c=lerp((56,189,248),(139,92,246),i/(n-1))
    x=sx+i*(w+gap); hh=h*S//2
    d.rounded_rectangle((x,cy-hh,x+w,cy+hh),w//2,fill=c+(255,))
import sys; img.resize((1024,1024),Image.LANCZOS).save(sys.argv[1] if len(sys.argv)>1 else "icon_1024.png")
