import { mkdirSync, writeFileSync } from 'node:fs';
import { encodeScore, scoreSummary } from './encode-score';
import { engineeringSource } from '../tests/fixtures/engineering';
import { parseScore } from '../src/lib/psc2';
import { crc32 } from '../src/lib/pseq';

const dir = 'tests/fixtures/packages';
mkdirSync(dir, { recursive: true });
const bytes = encodeScore(engineeringSource());
writeFileSync(`${dir}/engineering.pseq`, bytes);
const invalid: Record<string, (b: Uint8Array, v: DataView) => void> = {
  'bad-crc': b => { b[400] = b[400]! ^ 1; },
  'bad-anchor': (_b, v) => { const o = section(v,7); v.setUint32(v.getUint32(o+8,true)+4,999,true); repair(_b,v,o); },
  'unsafe-start': (_b,v) => { const o=section(v,8);v.setUint32(v.getUint32(o+8,true)+4,3840,true);repair(_b,v,o); },
  'bad-score-flags': (_b,v) => { const o=section(v,2);_b[v.getUint32(o+8,true)+11]=2;repair(_b,v,o); },
};
function section(v: DataView, type: number) { for(let o=64;o<64+v.getUint16(36,true)*32;o+=32) if(v.getUint32(o,true)===type)return o;throw Error('missing section'); }
function repair(b:Uint8Array,v:DataView,o:number) { const start=v.getUint32(o+8,true);v.setUint32(o+24,crc32(b.subarray(start,start+v.getUint32(o+12,true))),true); }
const invalidResults: Record<string,string>={};
for (const [name, mutate] of Object.entries(invalid)) {
  const b=bytes.slice();mutate(b,new DataView(b.buffer));
  try { parseScore(b);throw Error('illegal fixture was accepted'); }
  catch(e) { if(!(e instanceof Error)||!e.message.startsWith('曲目包无效'))throw e;invalidResults[name]=e.message; }
  writeFileSync(`${dir}/${name}.pseq`,b);
}
const v=new DataView(bytes.buffer);
writeFileSync(`${dir}/manifest.json`,JSON.stringify({ ...scoreSummary(parseScore(bytes)), sections:Array.from({length:v.getUint16(36,true)},(_,i)=>{const o=64+i*32;return {type:v.getUint32(o,true),offset:v.getUint32(o+8,true),length:v.getUint32(o+12,true),crc:v.getUint32(o+24,true)};}), pixels: [0,1,2,3].map(page=>({page,black:[[8,20+page],[15,20+page]],white:[[9,20+page]]})), invalid:invalidResults },null,2)+'\n');
