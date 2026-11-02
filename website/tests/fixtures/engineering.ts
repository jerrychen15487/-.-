import type { ScoreSource } from '../../tools/encode-score';

/** Hand-authored expectations, intentionally independent of the safe-point implementation. */
export const expectedSafe = [0, 4800, 5760, 7680, 8640, 9600, 9920, 10240];
export function engineeringSource(): ScoreSource {
  const note = (startTick: number, durationTicks: number, pitch: number, dynamic: number, part: number, flags: number) => ({ startTick, durationTicks, pitch, dynamic, part, flags, group: startTick });
  return {
    id: '12345678-1234-5678-9abc-def012345678', revision: 1, durationTicks: 11520, bpm: 120, capabilities: 7,
    meta: { title: 'PSC2 工程向量', source: 'hand-authored engineering fixture; not a published composition', generator_version: '2.0.0', license: 'CC0-1.0' },
    notes: [note(0,4320,48,0,1,3), note(0,960,60,1,2,7), note(960,240,60,2,2,7), note(1440,240,64,3,2,7), note(1440,240,67,4,2,7), note(1920,960,65,5,2,7), note(2880,960,69,6,2,7), note(4800,480,60,0,2,1), note(5760,480,48,0,1,0), note(7680,960,72,4,3,7), note(8640,480,72,4,3,7), note(9600,320,75,0,2,1), note(9920,320,75,0,2,1), note(10240,320,75,0,2,1)],
    controls: [{tick:100,controller:1,value:127,flags:0},{tick:960,controller:64,value:96,flags:1},{tick:4800,controller:64,value:63,flags:1},{tick:7680,controller:64,value:64,flags:0},{tick:8640,controller:64,value:0,flags:0}],
    measures: [0,1,2].map(index => ({index,startTick:index*3840,endTick:(index+1)*3840,numerator:4,denominatorPow:2})),
    pages: [0,1,2,3].map(id => {
      const pixels = new Uint8Array(57600); pixels[120 * (20 + id) + 1] = 0x81;
      return {id,profile:1,notation:id < 2 ? 1 : 2,width:960,height:480,stride:120,pixels};
    }),
    anchors: [0,1,2].flatMap(measureIndex => [1,2].map(notation => ({ startTick:measureIndex*3840,pageId:(notation-1)*2+(measureIndex===1?1:0),measureIndex,x:8,y:20,width:940,height:400,notation }))),
    safeStarts: [...expectedSafe],
  };
}
