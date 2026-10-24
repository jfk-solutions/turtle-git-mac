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
    RawImages(input, output, json, ref first);
    // This run is limited to the compressed-source questions; earlier embedded
    // texture/reference evidence is retained in its own completed run.
    if(first) throw new InvalidOperationException("No original compressed-raster metafiles selected");
    json.Append("]}");
    File.WriteAllText(Path.Combine(output,"samples.json"),json.ToString());
  }
  private static void Samples(StringBuilder json, Bitmap bitmap) {
    json.Append(",\"samples\":["); bool first=true;
    int[] positions={0,4,9,13,17,21,25,29,33,37,41,45,49,53,57,63};
    foreach(int y in positions) foreach(int x in positions) {
      if(!first)json.Append(",");first=false;
      json.Append("[").Append(x).Append(",").Append(y).Append(",\"").Append(unchecked((uint)bitmap.GetPixel(x,y).ToArgb()).ToString("X8")).Append("\"]");
    }
    json.Append("]");
  }
  private static void Error(StringBuilder json, Exception error) {
    json.Append(",\"error\":\"").Append(error.GetType().Name).Append(": ").Append(error.Message.Replace("\\","\\\\").Replace("\"","\\\"").Replace("\r"," ").Replace("\n"," ")).Append("\"");
  }
  private static void RawImages(string input,string output,StringBuilder json,ref bool first) {
    foreach(var path in Directory.GetFiles(input,"compressed-raster-source-*")) {
      if(!first)json.Append(",");first=false;
      json.Append("{\"name\":\"raw-").Append(Path.GetFileName(path)).Append("\"");
      try {
        using(var source=Image.FromFile(path))
        using(var bitmap=new Bitmap(64,64,PixelFormat.Format32bppArgb)) {
          bitmap.SetResolution(96,96);
          using(var graphics=Graphics.FromImage(bitmap)) {
            graphics.Clear(Color.Blue); graphics.DrawImage(source,new Rectangle(0,0,64,64),0,0,source.Width,source.Height,GraphicsUnit.Pixel);
          }
          json.Append(",\"imageSize\":[").Append(source.Width).Append(",").Append(source.Height).Append("]");
          json.Append(",\"frameCounts\":[");bool firstFrame=true;
          foreach(var dimension in source.FrameDimensionsList) {if(!firstFrame)json.Append(",");firstFrame=false;json.Append(source.GetFrameCount(new FrameDimension(dimension)));}json.Append("]");
          if(Array.IndexOf(source.PropertyIdList,274)>=0)json.Append(",\"orientation\":").Append(BitConverter.ToUInt16(source.GetPropertyItem(274).Value,0));
          Samples(json,bitmap);bitmap.Save(Path.Combine(output,"raw-"+Path.GetFileName(path)+".png"),ImageFormat.Png);
          var native=Path.Combine(output,"native-"+Path.GetFileName(path)+".emf");
          using(var reference=new Bitmap(64,64))
          using(var referenceGraphics=Graphics.FromImage(reference)) {
            IntPtr hdc=referenceGraphics.GetHdc();Metafile recorded;
            try {recorded=new Metafile(native,hdc,new Rectangle(0,0,64,64),MetafileFrameUnit.Pixel,EmfType.EmfPlusOnly);}
            finally {referenceGraphics.ReleaseHdc(hdc);}
            using(recorded)using(var graphics=Graphics.FromImage(recorded)) {graphics.Clear(Color.Blue);graphics.DrawImage(source,new Rectangle(8,8,48,48),0,0,source.Width,source.Height,GraphicsUnit.Pixel);}
          }
          Console.WriteLine("NATIVE_COMPRESSED_RECORD "+Path.GetFileName(path)+" "+Convert.ToBase64String(File.ReadAllBytes(native)));
        }
      } catch(Exception error) {Error(json,error);}
      json.Append("}");
    }
  }
}
