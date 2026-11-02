"""Pinned LilyPond notation extraction for the three selected Mutopia editions.
The source bytes stay immutable. Output contains spelling, exact rational timings,
rests and marks. This is deliberately not a generic LilyPond importer.
"""
from pathlib import Path
from fractions import Fraction
import argparse, hashlib, json, re, shlex, subprocess

ROOT = Path(__file__).resolve().parent.parent
RECIPES = {
    '02': dict(title='阿拉贝斯克', numerator=2, bpm=152, bars=33, route=list(range(1,11))+list(range(3,10))+[11]+list(range(12,28))+list(range(12,27))+list(range(28,34))),
    '05': dict(title='天真', numerator=3, bpm=112, bars=17, route=list(range(1,9))+list(range(1,8))+[9]+list(range(10,18))*2),
    '06': dict(title='进步', numerator=4, bpm=132, bars=16, route=list(range(1,9))*2+list(range(9,17))+list(range(1,9))),
}

def main():
    ap=argparse.ArgumentParser();ap.add_argument('--lilypond',type=Path,default=ROOT/'output/toolchain/lilypond-2.24.4/bin/lilypond.exe');args=ap.parse_args()
    manifest=json.loads((ROOT/'sources/mutopia/manifest.json').read_text(encoding='utf-8'))
    output=ROOT/'output/score-audit';output.mkdir(exist_ok=True,parents=True)
    for number,recipe in RECIPES.items():
        source=ROOT/f'sources/mutopia/25EF-{number}.ly'
        expected=next(m['sha256'] for m in manifest if m['file']==source.name)
        assert hashlib.sha256(source.read_bytes()).hexdigest()==expected,'source changed'
        folder=output/number;folder.mkdir(exist_ok=True)
        text=source.read_text(encoding='utf-8')
        # Use layout's printed order, including each alternative exactly once.
        text=text.replace('\\layout {}',r'\layout { \context { \Voice \consists #audit-engraver } }')
        text='\\include "'+(ROOT/'tools/extract-events.ily').as_posix()+'"\n'+text
        derivative=folder/'extract.ly';derivative.write_text(text,encoding='utf-8')
        subprocess.run([str(args.lilypond),'-dno-print-pages','-o',str(folder/'score'),str(derivative)],check=True,cwd=ROOT)
        events=[]
        for line in (folder/'events.scm').read_text(encoding='utf-8').splitlines():
            tokens=shlex.split(line[1:-1]);kind,staff,tick=tokens[:3]
            tick=Fraction(tick);assert tick.denominator==1
            e=dict(kind=kind,part=2 if staff=='up' else 1,tick=int(tick))
            if kind in ('note','rest'):
                duration=Fraction(tokens[3]);assert duration.denominator==1
                e.update(duration=int(duration),duration_log=int(tokens[4]),dots=int(tokens[5]))
                if kind=='note': e.update(pitch=int(tokens[6]),notename=int(tokens[7]),octave=int(tokens[8]),alteration=str(Fraction(tokens[9])),fingerings=[int(x) for x in tokens[10].split(',') if x])
            else:e['values']=tokens[3:]
            events.append(e)
        length=recipe['numerator']*960
        assert max(e['tick']+e['duration'] for e in events if e['kind'] in ('note','rest'))==recipe['bars']*length,(number,'bar count')
        notes=[e for e in events if e['kind']=='note'];ends={};overlaps=[]
        for n in sorted(notes,key=lambda n:(n['tick'],n['pitch'])):
            prev=ends.get(n['pitch'])
            if prev and prev['tick']+prev['duration']>n['tick']:
                if (prev['tick'],prev['duration'])!=(n['tick'],n['duration']):overlaps.append([prev,n])
            ends[n['pitch']]=n
        if overlaps:raise ValueError(f'{number}: incompatible same-pitch overlaps: {overlaps}')
        result=dict(piece=number,recipe=recipe,source_sha256=expected,events=events)
        target=ROOT/f'sources/mutopia/25EF-{number}.events.json'
        target.write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n',encoding='utf-8',newline='\n')
        print(number,'notes',len(notes),'events',len(events),'route',len(recipe['route']))

if __name__=='__main__':main()
