import { readFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { describe,it,expect } from 'vitest';
import { prepareSemantics } from '../tools/prepare-score-semantics';

describe('selected complete editions',()=>{
  it('pins only Nos.5, 6, 2 and verifies original source bytes',()=>{
    const entries=JSON.parse(readFileSync('sources/mutopia/manifest.json','utf8'));
    expect(entries.map((e:{file:string})=>e.file).sort()).toEqual(['25EF-02.ly','25EF-05.ly','25EF-06.ly']);
    for(const e of entries)expect(createHash('sha256').update(readFileSync(`sources/mutopia/${e.file}`)).digest('hex')).toBe(e.sha256);
  });
  it.each([['05',414,32,92160,112],['06',485,32,122880,132],['02',480,55,105600,152]] as const)('%s has full route, exact duration and conservative scoring', (number,count,bars,duration,bpm)=>{
    const s=prepareSemantics(number);expect(s.notes.length).toBe(count);expect(s.measures.length).toBe(bars);
    expect(s.durationTicks).toBe(duration);expect(s.bpm).toBe(bpm);expect(s.controls).toEqual([]);
    expect(s.notes.every(n=>!(n.flags&4)||n.dynamic>0)).toBe(true);
    expect(s.notes.some(n=>!(n.flags&2))).toBe(true);
    expect(s.notes.some(n=>!(n.flags&4))).toBe(true);
    const ends=new Map<number,number>();for(const n of s.notes){expect(n.startTick).toBeGreaterThanOrEqual(ends.get(n.pitch)??0);ends.set(n.pitch,n.startTick+n.durationTicks);}
  });
  it('retains initial chord/part pitches and source-only dynamics',()=>{
    const five=prepareSemantics('05');expect(five.notes.filter(n=>n.startTick===0).map(n=>[n.pitch,n.part])).toEqual([[53,1],[57,1],[60,1],[81,2]]);
    const six=prepareSemantics('06');expect(six.notes.filter(n=>n.startTick===0).map(n=>[n.pitch,n.dynamic])).toEqual([[48,0],[64,2]]);
  });
  it('merges actual ties into one attack but keeps repeated keys distinct',()=>{
    const two=prepareSemantics('02');
    expect(two.notes.find(n=>n.part===2&&n.startTick===14400&&n.pitch===74)?.durationTicks).toBe(1440);
    expect(two.notes.some(n=>n.part===2&&n.startTick===15360&&n.pitch===74)).toBe(false);
    expect(two.notes.filter(n=>n.startTick===0).map(n=>n.pitch)).toEqual([57,60,64]);
    expect(two.notes.filter(n=>n.startTick===960).map(n=>n.pitch)).toEqual([57,60,64]);
    expect(two.notes.find(n=>n.part===2)?.startTick).toBe(3840);
    expect(two.notes.filter(n=>n.startTick===two.durationTicks-1920).every(n=>!(n.flags&2))).toBe(true);
  });
});
