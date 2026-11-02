"""Map printed measures to final SVG coordinates. Fail on any measure split across pages."""
from pathlib import Path
from collections import defaultdict
import xml.etree.ElementTree as ET
import json,re,math
ROOT=Path(__file__).resolve().parent.parent
def main():
    maps={}
    for number in ['02','05','06']:
        data=json.loads((ROOT/f'sources/mutopia/25EF-{number}.events.json').read_text(encoding='utf-8'));length=data['recipe']['numerator']*960
        maps[number]={}
        for notation in ['staff','jianpu']:
            files=sorted((ROOT/'output/engrave').glob(f'{notation}{number}-*.svg'),key=lambda p:int(p.stem.split('-')[-1]))
            measures=defaultdict(list);barlines=defaultdict(list)
            assert files
            for page,path in enumerate(files):
                root=ET.parse(path).getroot();box=list(map(float,root.get('viewBox').split()));sx,sy=960/box[2],480/box[3]
                for g in root.iter():
                    if 'data-tick' not in g.attrib:continue
                    kind=g.get('data-kind');tick=int(g.get('data-tick'))
                    transform=next((e.get('transform') for e in g.iter() if 'transform' in e.attrib),None)
                    if not transform:continue
                    match=re.fullmatch(r'translate\(([-\d.]+),\s*([-\d.]+)\)',transform)
                    assert match,transform
                    x,y=float(match[1])*sx,float(match[2])*sy
                    if kind=='bar':barlines[(page,tick)].append((x,y))
                    else:measures[tick//length+1].append((page,x,y))
            assert set(measures)==set(range(1,data['recipe']['bars']+1)),(number,notation,'missing or extra measures',set(measures))
            rects=[]
            for bar,points in sorted(measures.items()):
                pages={p for p,x,y in points};assert len(pages)==1,(number,notation,bar,'split across pages',pages)
                page=pages.pop();xs=[x for p,x,y in points];ys=[y for p,x,y in points]
                ymin,ymax=min(ys),max(ys)
                left=[x for x,y in barlines[(page,(bar-1)*length)] if ymin-70<=y<=ymax+70 and x<=min(xs)+10]
                right=[x for x,y in barlines[(page,bar*length)] if ymin-70<=y<=ymax+70 and x>=max(xs)-10]
                x=max(0,math.floor(min(left) if left else 24));end=min(960,math.ceil(max(right) if right else 936))
                y=max(0,math.floor(ymin-65));bottom=min(480,math.ceil(ymax+65))
                assert x<end and y<bottom
                rects.append(dict(source_measure=bar,page=page,x=x,y=y,width=end-x,height=bottom-y))
            maps[number][notation]=dict(files=[str(p.relative_to(ROOT)).replace('\\','/') for p in files],measures=rects)
            print(number,notation,len(files),'pages;',len(rects),'complete measures')
    (ROOT/'output/engrave/map.json').write_text(json.dumps(maps,indent=2)+'\n',encoding='utf-8',newline='\n')
if __name__=='__main__':main()
