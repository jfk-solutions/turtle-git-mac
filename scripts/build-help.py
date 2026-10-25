#!/usr/bin/env python3
"""Generate the portable, offline Apple Help resources from the Mac user guides.
Use the site Python environment. Xcode indexes the copied book before signing.
"""
from pathlib import Path
from html import escape
from urllib.parse import urlsplit, unquote, quote
import argparse
import hashlib
import json
import plistlib
from markdown_it import MarkdownIt
from site_docs import slug

ROOT=Path(__file__).resolve().parent.parent
BOOK=ROOT/'Sources/TurtleGitMac/Resources/TurtleGitHelp.help'
LOCALE=Path('Contents/Resources/en.lproj')
CSS='''html{color-scheme:light dark;font:15px -apple-system,BlinkMacSystemFont,sans-serif;line-height:1.6}body{max-width:900px;margin:auto;padding:24px;color:CanvasText;background:Canvas}a{color:LinkText}nav{display:flex;gap:18px;flex-wrap:wrap;border-bottom:1px solid GrayText;padding-bottom:12px}h1,h2,h3{line-height:1.25}h2{margin-top:2em}img{max-width:100%;height:auto}pre{overflow:auto;padding:12px;background:color-mix(in srgb,CanvasText 7%,Canvas)}code{font-family:ui-monospace,monospace}table{border-collapse:collapse}th,td{border:1px solid GrayText;padding:6px}footer{border-top:1px solid GrayText;margin-top:32px;font-size:12px}.skip{position:absolute;left:-9999px}.skip:focus{position:static}'''

def generate():
    definition=json.loads((ROOT/'docs/help-topics.json').read_text())
    topics=definition['topics']; ids=[t['id'] for t in topics]
    if len(set(ids))!=len(ids): raise ValueError('Duplicate help topic')
    documents=sorted({t['document'] for t in topics}|set(definition['additional_guides']))
    output={}; inputs={'docs/help-topics.json':hashlib.sha256((ROOT/'docs/help-topics.json').read_bytes()).hexdigest()}
    aliases={}; headings={}; titles={}; parsed={}; links=[]
    for name in documents:
        source=ROOT/'docs'/name
        if source.parent!=ROOT/'docs' or not source.is_file():raise ValueError('Invalid help document: '+name)
        raw=source.read_bytes();inputs['docs/'+name]=hashlib.sha256(raw).hexdigest()
        md=MarkdownIt('commonmark',{'html':False}).enable(['table','strikethrough']); tokens=md.parse(raw.decode())
        anchors=set();counts={};title=source.stem
        for i,token in enumerate(tokens):
            if token.type=='heading_open':
                text=tokens[i+1].content; anchor=slug(text); count=counts.get(anchor,0);counts[anchor]=count+1
                if count:anchor+='-'+str(count)
                token.attrSet('id',anchor);anchors.add(anchor)
                if token.tag=='h1':title=text
        headings[name]=anchors;titles[name]=title;parsed[name]=(md,tokens)
    for topic in topics:
        fragment=topic.get('fragment')
        if fragment and fragment not in headings[topic['document']]:raise ValueError('Missing help fragment: '+str(topic))
        aliases.setdefault((topic['document'],fragment),[]).append(topic['id'])
    def shell(title,body,apple=False):
        meta='<meta name="AppleTitle" content="'+escape(definition['book_name'])+'" />' if apple else ''
        return ('<!DOCTYPE html>\n<html lang="en"><head><meta charset="utf-8" /><meta name="viewport" content="width=device-width, initial-scale=1" />'+meta+'<title>'+escape(title)+'</title><link rel="stylesheet" href="help.css" /></head><body><a class="skip" href="#content">Skip to content</a><nav aria-label="Help navigation"><a href="index.html">TurtleGit Help</a><a href="GETTING-STARTED.html">Getting started</a><a href="DIALOG-GUIDE.html">Dialog guide</a></nav><main id="content">'+body+'</main><footer>TurtleGit for Mac · A macOS fork of TortoiseGit · macOS port by Jochen Kühner. <a href="https://jfk-solutions.github.io/turtle-git-mac/manual/">Online manual</a> · <a href="https://github.com/jfk-solutions/turtle-git-mac/blob/main/NOTICE">Attribution</a></footer></body></html>\n').encode()
    for name,(md,tokens) in parsed.items():
        source=ROOT/'docs'/name
        for token in tokens:
            for child in token.children or []:
                key='href' if child.type=='link_open' else 'src' if child.type=='image' else None
                if not key:continue
                original=child.attrGet(key) or '';parts=urlsplit(original)
                if parts.scheme or parts.netloc:continue
                target=(source.parent/unquote(parts.path)).resolve() if parts.path else source
                suffix=('#'+parts.fragment if parts.fragment else '')
                if target.parent==ROOT/'docs' and target.name in documents:
                    child.attrSet(key,target.stem+'.html'+suffix);links.append((name,target.name,parts.fragment));continue
                if child.type=='image':
                    target.relative_to(ROOT)
                    if not target.is_file():raise ValueError('Missing help image: '+str(target))
                    image_name=hashlib.sha256(target.relative_to(ROOT).as_posix().encode()).hexdigest()[:12]+'-'+target.name
                    output[LOCALE/'images'/image_name]=target.read_bytes();inputs[target.relative_to(ROOT).as_posix()]=hashlib.sha256(target.read_bytes()).hexdigest()
                    child.attrSet(key,'images/'+quote(image_name));continue
                if target.parent==ROOT/'docs' and target.suffix=='.md':
                    child.attrSet(key,'https://jfk-solutions.github.io/turtle-git-mac/manual/'+quote(target.stem)+'.html'+suffix)
                elif target.is_relative_to(ROOT):
                    child.attrSet(key,'https://github.com/jfk-solutions/turtle-git-mac/blob/main/'+quote(target.relative_to(ROOT).as_posix())+suffix)
                else:raise ValueError('External local path in help: '+original)
        # Named anchors are indexed by Apple Help; heading IDs also support normal links.
        body=md.renderer.render(tokens,md.options,{})
        prefix=''.join('<a name="topic-'+escape(t)+'"></a>' for t in aliases.get((name,None),[]))
        for fragment in headings[name]:
            added=''.join('<a name="topic-'+escape(t)+'"></a>' for t in aliases.get((name,fragment),[]))
            if added:body=body.replace('<h2 id="'+fragment+'">',added+'<h2 id="'+fragment+'">',1)
        output[LOCALE/(source.stem+'.html')]=shell(titles[name],prefix+body)
    for name,target,fragment in links:
        if fragment and unquote(fragment) not in headings[target]:raise ValueError('Broken help section: '+name+' -> '+target+'#'+fragment)
    listing=''.join('<li><a href="'+Path(name).stem+'.html">'+escape(titles[name])+'</a></li>' for name in documents)
    output[LOCALE/'index.html']=shell(definition['book_name'],'<a name="topic-home"></a><h1>TurtleGit for Mac Help</h1><p>Browse these Mac workflow guides offline, or use Help Viewer’s search. Dialog Help buttons open the relevant topic.</p><ul>'+listing+'</ul>',True)
    output[LOCALE/'help.css']=CSS.encode()
    output[LOCALE/'topics.json']=(json.dumps(definition,indent=2)+'\n').encode()
    info={'CFBundleDevelopmentRegion':'en','CFBundleIdentifier':definition['bundle_id'],'CFBundleName':'TurtleGitHelp','CFBundlePackageType':'BNDL','CFBundleSignature':'hbwr','CFBundleInfoDictionaryVersion':'6.0','CFBundleShortVersionString':'1','CFBundleVersion':'1','HPDBookAccessPath':'index.html','HPDBookIndexPath':'TurtleGitHelp.helpindex','HPDBookTitle':definition['book_name'],'HPDBookType':'3'}
    digest=hashlib.sha256(json.dumps(inputs,sort_keys=True).encode()).hexdigest()
    info['CFBundleVersion']='1.'+str(int(digest[:7],16))
    output[Path('Contents/Info.plist')]=plistlib.dumps(info,sort_keys=True)
    output[LOCALE/'InfoPlist.strings']=('"HPDBookTitle" = "'+definition['book_name']+'";\n').encode()
    manifest={'source_hashes':inputs,'files':{str(p):hashlib.sha256(data).hexdigest() for p,data in sorted(output.items())}}
    output[Path('Contents/Resources/manifest.json')]=(json.dumps(manifest,indent=2,sort_keys=True)+'\n').encode()
    return output, len(documents), len(topics)

def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--check',action='store_true');args=parser.parse_args()
    output,documents,topics=generate()
    actual={p.relative_to(BOOK) for p in BOOK.rglob('*') if p.is_file()}
    if args.check:
        changed=[str(p) for p,data in output.items() if not (BOOK/p).is_file() or (BOOK/p).read_bytes()!=data]
        extra=sorted(map(str,actual-set(output)))
        if changed or extra:raise SystemExit('Regenerate help book: '+', '.join(changed+extra))
    else:
        for p in actual-set(output):(BOOK/p).unlink()
        for p,data in output.items():(BOOK/p).parent.mkdir(parents=True,exist_ok=True);(BOOK/p).write_bytes(data)
    print(json.dumps({'documents':documents,'topics':topics,'files':len(output),'bytes':sum(map(len,output.values())),'mode':'check' if args.check else 'write'}))
if __name__=='__main__':main()
