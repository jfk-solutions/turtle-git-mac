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
    foreach (var path in Directory.GetFiles(input, "embedded-*.emf")) {
      if (Path.GetFileName(path).StartsWith("embedded-refused-")) continue;
      if (!first) json.Append(","); first=false;
      json.Append("{\"name\":\"").Append(Path.GetFileName(path)).Append("\"");
      try {
        using (var image = new Metafile(path))
        using (var bitmap = new Bitmap(64,64,PixelFormat.Format32bppArgb)) {
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
    json.Append("]}");
    File.WriteAllText(Path.Combine(output,"samples.json"),json.ToString());
  }
}
