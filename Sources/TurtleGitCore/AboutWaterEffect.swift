// SPDX-License-Identifier: GPL-2.0-or-later
// Port of Utils/MiscUI/WaterEffect.cpp/.h: Copyright (C) 2023, 2025 TortoiseGit;
// Copyright (C) 2003-2006, 2008-2010, 2012-2013 TortoiseSVN.
import Foundation

/// The source About banner's two-page height field, refraction and shading.
/// Native pixels preserve their alpha; the Windows RGB macro discarded it.
public struct AboutWaterEffect:Sendable {
    public let width:Int
    public let height:Int
    public private(set) var page=0
    public var density:Int=2 {didSet {density=min(16,max(1,density))}}
    private var first:[Int32]
    private var second:[Int32]
    public init?(width:Int,height:Int) {
        // The source renderer processes horizontal pairs. Bound native buffers
        // and require even widths instead of inheriting odd-width overreads.
        guard width>=4,width<=2048,width%2==0,height>=4,height<=1024 else{return nil}
        self.width=width;self.height=height
        first=Array(repeating:0,count:width*height);second=first
    }
    public mutating func clear() {
        first=Array(repeating:0,count:width*height);second=first;page=0
    }
    public mutating func blob(x:Int,y:Int,radius:Int,strength:Int) {
        guard x>=0,x<width,y>=0,y<height,radius>0 else{return}
        let radius=min(32,radius),amount=Int32(min(1600,max(-1600,strength)))
        let left=max(1,x-radius),right=min(width-1,x+radius)
        let top=max(1,y-radius),bottom=min(height-1,y+radius)
        guard left<right,top<bottom else{return}
        for cy in top..<bottom {
            for cx in left..<right where (cx-x)*(cx-x)+(cy-y)*(cy-y)<radius*radius {
                let index=cy*width+cx
                if page==0 {first[index] = first[index] &+ amount}
                else {second[index] = second[index] &+ amount}
            }
        }
    }
    public mutating func smooth() {
        if page==0 {Self.smooth(new:&first,old:second,width:width,height:height)}
        else {Self.smooth(new:&second,old:first,width:width,height:height)}
    }
    private static func smooth(new:inout [Int32],old:[Int32],width:Int,height:Int) {
        for y in 1..<(height-1) {
            for x in 1..<(width-1) {
                let i=y*width+x
                let sum=old[i+width] &+ old[i-width] &+ old[i+1] &+ old[i-1] &+ old[i-width-1] &+ old[i-width+1] &+ old[i+width-1] &+ old[i+width+1]
                new[i]=((sum>>3) &+ new[i])>>1
            }
        }
    }
    public mutating func render(source:[UInt32],destination:inout [UInt32]) {
        guard source.count==width*height,destination.count==source.count else{return}
        // DrawWater intentionally reads page one in upstream, irrespective of
        // the page being calculated. Preserve its alternating-frame behavior.
        for y in 1..<(height-1) {
            for x in 1..<(width-1) {
                let index=y*width+x,dx=first[index] &- first[index+1],dy=first[index] &- first[index+width]
                let sample=index+width*Int(dy>>3)+Int(dx>>3)
                guard sample>0,sample<source.count else{continue}
                let color=source[sample]
                func channel(_ shift:UInt32)->UInt32 {
                    UInt32(min(255,max(0,Int((color>>shift)&255)-Int(dx))))
                }
                destination[index]=(color&0xFF000000)|channel(0)|(channel(8)<<8)|(channel(16)<<16)
            }
        }
        if page==0 {Self.calculate(new:&first,old:second,width:width,height:height,density:density)}
        else {Self.calculate(new:&second,old:first,width:width,height:height,density:density)}
        page ^= 1
    }
    private static func calculate(new:inout [Int32],old:[Int32],width:Int,height:Int,density:Int) {
        for y in 1..<(height-1) {
            for x in 1..<(width-1) {
                let i=y*width+x
                let sum=old[i+width] &+ old[i-width] &+ old[i+1] &+ old[i-1] &+ old[i-width-1] &+ old[i-width+1] &+ old[i+width-1] &+ old[i+width+1]
                let value=(sum>>2) &- new[i]
                new[i]=value &- (value>>density)
            }
        }
    }
}
