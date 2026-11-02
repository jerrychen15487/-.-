import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import sharp from 'sharp';
import { prepareSemantics } from './prepare-score-semantics';
import { encodeScore, scoreSummary } from './encode-score';
import { parseScore, tickToMs } from '../src/lib/psc2';

type MapEntry={files:string[];measures:{source_measure:number;page:number;x:number;y:number;width:number;height:number}[]};
const mapping:Record<string,Record<string,MapEntry>>=JSON.parse(readFileSync('output/engrave/map.json','utf8'));
const out='output/releases/scores';mkdirSync(out,{recursive:true});
const catalog=[];
for(const number of ['05','06','02']) {
  const source=prepareSemantics(number), route=source.meta.source_measure_route as number[];
  for(const [notation,name] of [[1,'staff'],[2,'jianpu']] as const) {
    const entry=mapping[number]![name]!, pageBase=source.pages.length;
    for(const [i,file] of entry.files.entries()) {
      const raw=await sharp(file).resize(960,480).flatten({background:'white'}).greyscale().threshold(160).raw().toBuffer();
      if(raw.length!==960*480)throw Error('unexpected raster channels');
      const pixels=new Uint8Array(57600);
      for(let y=0;y<480;y++)for(let x=0;x<960;x++)if(raw[y*960+x]!<128)pixels[y*120+(x>>3)]!|=128>>(x&7);
      source.pages.push({id:pageBase+i,profile:1,notation,width:960,height:480,stride:120,pixels});
    }
    route.forEach((bar,index)=>{
      const m=entry.measures.find(m=>m.source_measure===bar);if(!m)throw Error('missing engraved measure');
      source.anchors.push({startTick:source.measures[index]!.startTick,pageId:pageBase+m.page,measureIndex:index,x:m.x,y:m.y,width:m.width,height:m.height,notation});
    });
  }
  source.anchors.sort((a,b)=>a.startTick-b.startTick||a.notation-b.notation);
  const bytes=encodeScore(source), score=parseScore(bytes), stem=`burgmuller-${number}`;
  writeFileSync(`${out}/${stem}.pseq`,bytes);
  writeFileSync(`${out}/${stem}.manifest.json`,JSON.stringify(scoreSummary(score),null,2)+'\n');
  // All review PNGs and covers are decoded from the final package's MONO1 bytes.
  const review=`output/review/${stem}`;mkdirSync(review,{recursive:true});
  for(const p of score.pages) {
    const raw=Buffer.alloc(960*480,255);
    for(let y=0;y<480;y++)for(let x=0;x<960;x++)if(p.pixels[y*120+(x>>3)]!&(128>>(x&7)))raw[y*960+x]=0;
    await sharp(raw,{raw:{width:960,height:480,channels:1}}).png().toFile(`${review}/page-${p.id}.png`);
    if(p.id===0)await sharp(raw,{raw:{width:960,height:480,channels:1}}).resize(640,320).png().toFile(`${out}/${stem}.png`);
  }
  catalog.push({id:score.id,title:score.meta.title,subtitle:`布格缪勒 Op.100 No.${Number(number)} · 完整作品`,level:'基础',tempo:score.bpm,duration:tickToMs(score.durationTicks,score.bpm),notes:score.notes.length,bytes:bytes.length,crc:score.crc,file:`scores/${stem}.pseq`,cover:`scores/${stem}.png`,capabilities:score.capabilities,revision:score.revision});
  console.log(number,score.notes.length,'notes',score.pages.length,'pages',bytes.length,'bytes CRC',score.crc.toString(16));
}
writeFileSync(`${out}/catalog.json`,JSON.stringify(catalog,null,2)+'\n');
