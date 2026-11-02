import { readFileSync } from 'node:fs';
import { computeSafeStarts } from '../src/lib/psc2';
import { DYNAMICS, PPQ } from '../src/lib/protocol';
import type { ScoreSource } from './encode-score';

type Event = {kind:string;part:number;tick:number;duration?:number;pitch?:number;values?:string[]};
export type AuditedSource = {piece:string;source_sha256:string;recipe:{title:string;numerator:number;bpm:number;bars:number;route:number[]};events:Event[]};
export function prepareSemantics(number:string):ScoreSource {
  const data:AuditedSource=JSON.parse(readFileSync(`sources/mutopia/25EF-${number}.events.json`,'utf8'));
  const length=data.recipe.numerator*PPQ;
  type Written = Omit<ScoreSource['notes'][number], 'group'> & {tie:boolean};
  const written:Written[]=[];
  for(const part of [1,2]) {
    const moments=new Map<number,Event[]>();
    for(const e of data.events.filter(e=>e.part===part))moments.set(e.tick,[...(moments.get(e.tick)??[]),e]);
    let dynamic=0;
    for(const [tick,events] of [...moments].sort(([a],[b])=>a-b)) {
      for(const e of events) {
        if(e.kind==='dynamic')dynamic=Math.max(0,DYNAMICS.findIndex(level=>level===e.values![0]));
        if(['crescendo','decrescendo'].includes(e.kind)&&e.values![0]==='-1')dynamic=0;
        if(e.kind==='text') {
          const text=e.values![0]!;
          if(/cresc|dim\./i.test(text))dynamic=0;
          const prefix=/^(pp|p|mp|mf|ff|f)\s/.exec(text);if(prefix)dynamic=DYNAMICS.findIndex(level=>level===prefix[1]);
        }
      }
      const articulations=events.filter(e=>e.kind==='articulation').map(e=>e.values![0]);
      const release=!articulations.some(a=>['staccato','staccatissimo','fermata'].includes(a!));
      const effective=articulations.includes('accent')?0:dynamic;
      for(const e of events.filter(e=>e.kind==='note'))written.push({startTick:tick,durationTicks:e.duration!,pitch:e.pitch!,dynamic:effective,part,flags:1+(release?2:0)+(effective?4:0),tie:events.some(e=>e.kind==='tie')});
    }
  }
  const expanded:Written[]=[];
  data.recipe.route.forEach((bar,index)=>{
    for(const n of written.filter(n=>Math.floor(n.startTick/length)+1===bar))expanded.push({...n,startTick:index*length+n.startTick%length});
  });
  expanded.sort((a,b)=>a.startTick-b.startTick||a.pitch-b.pitch||a.part-b.part);
  const tied:Written[]=[], pending=new Map<string,Written>();
  for(const n of expanded) {
    const key=`${n.part}:${n.pitch}`,prev=pending.get(key);
    if(prev) {
      if(prev.startTick+prev.durationTicks!==n.startTick)throw Error(`${number}: 延音线不连续 ${key} @ ${n.startTick}`);
      // A tied continuation is not a new key attack. Attack/dynamic reference
      // belongs to the first note; the release belongs to the last continuation.
      prev.durationTicks+=n.durationTicks;prev.tie=n.tie;prev.flags=(prev.flags&5)|(n.flags&2);
      if(!n.tie)pending.delete(key);
    } else { tied.push(n);if(n.tie)pending.set(key,n); }
  }
  if(pending.size)throw Error(`${number}: 未结束的延音线`);
  const notes:ScoreSource['notes']=[];
  for(const n of tied) {
    const previous=notes.at(-1);
    if(previous?.startTick===n.startTick&&previous.pitch===n.pitch) {
      if(previous.durationTicks!==n.durationTicks||previous.dynamic!==n.dynamic||previous.flags!==n.flags)throw Error(`${number}: 同音共同目标属性冲突`);
      previous.part|=n.part;
    } else { const {tie:_,...note}=n;notes.push({...note,group:n.startTick}); }
  }
  const durationTicks=length*data.recipe.route.length;
  const measures=data.recipe.route.map((_bar,index)=>({index,startTick:index*length,endTick:(index+1)*length,numerator:data.recipe.numerator,denominatorPow:2}));
  return {id:`b10000${number}-2013-4012-8000-000000000001`,revision:1,durationTicks,bpm:data.recipe.bpm,capabilities:7,notes,measures,controls:[],pages:[],anchors:[],safeStarts:computeSafeStarts(notes,measures,[],durationTicks),meta:{title:data.recipe.title,composer:'Friedrich Burgmüller',opus:`Op.100 No.${Number(number)}`,source:`https://www.mutopiaproject.org/cgibin/piece-info.cgi?id=${number==='02'?203:number==='05'?214:215}`,source_sha256:data.source_sha256,license:'Public Domain',generator_version:'psc2-selected-editions-2.0.0',default_bpm_source:'Mutopia source MIDI tempo; fixed quarter-note BPM, not an authoritative composer metronome mark',source_measure_route:data.recipe.route,reference_policy:'Original reference only. No pedal targets. Hairpins, unsupported dynamics and accents disable dynamic scoring; staccato and fermata disable release scoring. Their nominal notated lengths remain visible. Preview uses the fixed default tempo.',notation_parts:'Top: upper part; bottom: lower part. Parenthesized small numbers in jianpu are original fingerings.'}};
}
