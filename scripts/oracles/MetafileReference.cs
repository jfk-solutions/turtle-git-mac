// Original synthetic-fixture reference probe; no application or third-party source.
using System;
using System.IO;
using System.Text;
using System.Drawing;
using System.Drawing.Imaging;
using System.Drawing.Drawing2D;
public static class MetafileReference {
  public static void Run(string input, string output) {
    Directory.CreateDirectory(output);
    var json = new StringBuilder("{\"platform\":\"" + Environment.OSVersion.ToString() + "\",\"cases\":[");
    bool first = true;
    foreach (var path in Directory.GetFiles(input, "compressed-raster-*")) {
      var extension=Path.GetExtension(path).ToLowerInvariant();
      if(extension!=".emf" && extension!=".wmf") continue;
      if(Path.GetFileName(path).StartsWith("compressed-raster-refused-")) continue;
      if (!first) json.Append(","); first=false;
      json.Append("{\"name\":\"").Append(Path.GetFileName(path)).Append("\"");
      try {
        using (var image = new Metafile(path))
        using (var bitmap = new Bitmap(64,64,PixelFormat.Format32bppArgb)) {
          json.Append(",\"metafileSize\":[").Append(image.Width).Append(",").Append(image.Height).Append("]");
          bitmap.SetResolution(96,96);
          using (var g = Graphics.FromImage(bitmap)) {
            g.Clear(Color.Transparent);
            g.PageUnit=GraphicsUnit.Pixel;
            g.CompositingMode=CompositingMode.SourceOver;
            g.DrawImage(image,new Rectangle(0,0,64,64),0,0,64,64,GraphicsUnit.Pixel);
          }
          var file = Path.Combine(output, Path.GetFileNameWithoutExtension(path)+".png");
          bitmap.Save(file,ImageFormat.Png);
          json.Append(",\"samples\":[");
          int[] positions = {0,4,9,13,17,21,25,29,33,37,41,45,49,53,57,63};
          bool fp=true;
          foreach (int y in positions) foreach(int x in positions) {
            if (!fp) json.Append(","); fp=false;
            json.Append("[").Append(x).Append(",").Append(y).Append(",\"").Append(unchecked((uint)bitmap.GetPixel(x,y).ToArgb()).ToString("X8")).Append("\"]");
          }
          json.Append("]");
          // Compact, lossless images for destination-dependent cases are available
          // directly in logs as well as the downloadable reference artifact.
          var name=Path.GetFileNameWithoutExtension(path);
          if(name=="embedded-compositing-inherit" || name=="embedded-compositing-over" || name=="embedded-compositing-copy" || name=="embedded-image-destination-rop" || name=="embedded-child-clear")
            json.Append(",\"png\":\"").Append(Convert.ToBase64String(File.ReadAllBytes(file))).Append("\"");
        }
      } catch(Exception e) {
        json.Append(",\"error\":\"").Append(e.GetType().Name).Append(": ").Append(e.Message.Replace("\\","\\\\").Replace("\"","\\\"").Replace("\r"," ").Replace("\n"," ")).Append("\"");
      }
      json.Append("}");
    }
    // This run is limited to the compressed-source questions; earlier embedded
    // texture/reference evidence is retained in its own completed run.
    if(first) throw new InvalidOperationException("No original compressed-raster metafiles selected");
    json.Append("]}");
    File.WriteAllText(Path.Combine(output,"samples.json"),json.ToString());
  }
  private static void NativeTexture(string input,string output) {
    using(var child=new Metafile(Path.Combine(input,"oracle-child.emf"))) {
      using(var reference=new Bitmap(64,64))
      using(var referenceGraphics=Graphics.FromImage(reference)) {
        IntPtr hdc=referenceGraphics.GetHdc();
        Metafile recorded;
        try {recorded=new Metafile(Path.Combine(output,"native-recorded-texture.emf"),hdc,new Rectangle(0,0,64,64),MetafileFrameUnit.Pixel,EmfType.EmfPlusOnly);}
        finally {referenceGraphics.ReleaseHdc(hdc);}
        using(recorded)
        using(var graphics=Graphics.FromImage(recorded))
        using(var texture=new TextureBrush(child,WrapMode.Tile)) {
          graphics.Clear(Color.Blue);graphics.FillRectangle(texture,8,8,48,48);
        }
      }
      Console.WriteLine("NATIVE_RECORDED_TEXTURE "+Convert.ToBase64String(File.ReadAllBytes(Path.Combine(output,"native-recorded-texture.emf"))));
      try {
        using(var brush=new TextureBrush(child,WrapMode.Tile))
        using(var bitmap=new Bitmap(64,64,PixelFormat.Format32bppArgb)) {
          using(var g=Graphics.FromImage(bitmap)) {
            g.Clear(Color.Blue); g.FillRectangle(brush,0,0,64,64);
          }
          bitmap.Save(Path.Combine(output,"native-texture.png"),ImageFormat.Png);
          Console.WriteLine("NATIVE_TEXTURE_RESULT success pixel="+unchecked((uint)bitmap.GetPixel(5,5).ToArgb()).ToString("X8"));
        }
      } catch(Exception e) {Console.WriteLine("NATIVE_TEXTURE_RESULT "+e.GetType().Name+" "+e.Message);}
    }
  }

}
