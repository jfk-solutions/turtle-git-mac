// Copyright (C) TurtleGit contributors. Licensed under GPL-2.0-or-later.
import Foundation
@main struct RedEyeArithmetic {
static func main() throws {
 guard CommandLine.arguments.count==3 else {fatalError("usage: red-eye-arithmetic INPUTS.json REPORT.json")}
 let inputs=try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1]))) as! [[String:Any]]
 func associate(_ c:Int,_ a:Int)->UInt8 {UInt8(a==0 ? 0:min(255,(((c*a+127)/255)*((255<<16)/a))>>16))}
 var rows=[[String:Any]]()
 for row in inputs {
  let c=row["case"] as! [String:Any],w=c["width"] as! Int,h=c["height"] as! Int
  let p=c["parameters"] as! [String:Any],areas=(p["areas"] as! [[Int]]).map{SpatialImageEffectRect(left:$0[0],top:$0[1],right:$0[2],bottom:$0[3])}
  var source=try Data(contentsOf:URL(fileURLWithPath:row["atlas"] as! String))
  let expected=try Data(contentsOf:URL(fileURLWithPath:row["reference"] as! String))
  for i in stride(from:0,to:source.count,by:4) {for j in 0..<3 {source[i+j]=associate(Int(source[i+j]),Int(source[i+3]))}}
  var budget=SpatialImageEffectBudget()
  do {
   var actual=try RedEyeImageEffects.apply(pixels:source,width:w,height:h,areas:areas,budget:&budget).pixels
   for i in stride(from:0,to:actual.count,by:4) {for j in 0..<3 {let a=Int(actual[i+3]);actual[i+j]=associate(Int(associate(Int(actual[i+j]),a)),a)}}
   var bad=0,nonexact=0,maximum=0,sum=0
   for i in stride(from:0,to:actual.count,by:4) {var pixel=0;for j in 0..<4 {let d=abs(Int(actual[i+j])-Int(expected[i+j]));pixel=max(pixel,d);sum+=d};if pixel>1 {bad+=1};if pixel>0 {nonexact+=1};maximum=max(maximum,pixel)}
   rows.append(["file":c["file"]!,"pixelsExceedingOne":bad,"nonexactPixels":nonexact,"maxByteDelta":maximum,"absoluteByteError":sum])
  } catch is RedEyeImageEffectNoPaint {rows.append(["file":c["file"]!,"noPaint":true])}
 }
 let report:[String:Any]=["qualification":"Standalone arithmetic development comparison; not app, Core or native checks. Original retained Windows buffers only.","cases":rows]
 try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:CommandLine.arguments[2]))
 print("cases \(rows.count), pixelpasses \(rows.filter{($0["pixelsExceedingOne"] as? Int)==0}.count), noPaint \(rows.filter{($0["noPaint"] as? Bool)==true}.count)")
 for row in rows where (row["pixelsExceedingOne"] as? Int ?? 0)>0 {print(row)}
}
}
