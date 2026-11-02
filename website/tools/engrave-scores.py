"""Engrave the selected audited editions in two real notations at profile-1 size.
Requires pinned portable LilyPond and jianpu-ly; ordinary website builds do not.
"""
from pathlib import Path
from fractions import Fraction
from collections import defaultdict
import json, re, subprocess, os, sys
ROOT=Path(__file__).resolve().parent.parent
BIN=ROOT/'output/toolchain/lilypond-2.24.4/bin'
PAPER=r'''\paper {
 paper-width = 160\mm paper-height = 80\mm
 top-margin = 3\mm bottom-margin = 3\mm left-margin = 4\mm right-margin = 4\mm
 print-page-number = ##f print-first-page-number = ##f
 oddHeaderMarkup = ##f evenHeaderMarkup = ##f oddFooterMarkup = ##f evenFooterMarkup = ##f
 bookTitleMarkup = ##f scoreTitleMarkup = ##f
 ragged-bottom = ##f ragged-last-bottom = ##f indent = 0\mm
}'''

def digit(n, number):
    # Jianpu's tonic is F4 for No.5; C4 (6=A minor) for No.2, C4 for No.6.
    tonic_name=3 if number=='05' else 0
    diatonic=n['octave']*7+n['notename']-tonic_name
    octave,degree=divmod(diatonic,7)
    base_alt=-1 if number=='05' and n['notename']==6 else 0
    alt=int(Fraction(n['alteration'])*2)-base_alt
    assert alt in (-1,0,1)
    return ('b' if alt<0 else '#' if alt>0 else '')+str(degree+1)+("'"*octave if octave>0 else ','*(-octave))

def music_bars(data,part):
    number=data['piece'];recipe=data['recipe'];length=recipe['numerator']*960
    moments=defaultdict(list)
    for e in data['events']:
        if e['part']==part:moments[e['tick']].append(e)
    bars=[[] for _ in range(recipe['bars'])]
    for tick,events in sorted(moments.items()):
        rhythmic=[e for e in events if e['kind'] in ('note','rest')]
        if not rhythmic:
            # No selected edition has free-standing marks between rhythmic events.
            if events:raise ValueError((number,tick,events))
            continue
        duration=rhythmic[0]['duration'];assert all(e['duration']==duration for e in rhythmic)
        dots=rhythmic[0]['dots'];log=rhythmic[0]['duration_log']
        heads=''.join(digit(n,number) for n in rhythmic) if rhythmic[0]['kind']=='note' else '0'
        prefix={2:'',3:'q',4:'s',5:'d',6:'h'}.get(log,'')
        token=prefix+heads+('.'*dots if log>=2 else '')
        marks=[];tie=False
        for e in events:
            k=e['kind'];v=e.get('values',[])
            if k=='tie':tie=True
            elif k=='slur':marks.append('(' if v[0]=='-1' else ')')
            elif k=='dynamic':marks.append('\\'+v[0])
            elif k in ('crescendo','decrescendo'):
                marks.append('\\!' if v[0]=='1' else ('\\cresc' if k=='crescendo' else '\\dim') if v[1]=='text' else '\\<' if k=='crescendo' else '\\>')
            elif k=='articulation':marks.append({'staccato':'\\staccato','accent':'\\accent','fermata':'\\fermata'}[v[0]])
            elif k=='text':marks.append('^'+json.dumps(v[0],ensure_ascii=False))
            # Fingerings remain in the original staff engraving; numbered notation
            # explicitly labels fingering as text to avoid confusion with scale degrees.
            elif k=='finger':marks.append('^"('+v[0]+')"')
        chord_fingers=[','.join(str(f) for f in n.get('fingerings',[])) or '-' for n in rhythmic]
        if any(f!='-' for f in chord_fingers):marks.append('^"('+('/'.join(chord_fingers))+')"')
        result=[token]+marks
        if log<2:
            assert duration%960==0
            result+=['-']*(duration//960-1)
        if tie:result+=['~']
        bars[tick//length].extend(result)
    for i,bar in enumerate(bars):
        # Bare | is jianpu-ly's alternative-ending separator, not a bar check.
        bar+=['\\pageBreak' if (i+1)%4==0 else '\\break' if (i+1)%2==0 else '\\noBreak']
    return [' '.join(b) for b in bars]

def repeats(b,number):
    join=lambda a,z:'\n'.join(b[a-1:z])
    if number=='02':return join(1,2)+'\nR{ '+join(3,9)+' } A{ '+join(10,10)+' | '+join(11,11)+' }\nR{ '+join(12,26)+' } A{ '+join(27,27)+' | '+join(28,28)+' }\n'+join(29,33)
    if number=='05':return 'R{ '+join(1,7)+' } A{ '+join(8,8)+' | '+join(9,9)+' }\nR{ '+join(10,17)+' }'
    return 'R{ '+join(1,8)+' }\n'+join(9,16)

def main():
    folder=ROOT/'output/engrave';folder.mkdir(exist_ok=True)
    env=os.environ.copy();env['PATH']=str(BIN)+os.pathsep+env['PATH'];env['PYTHONUTF8']='1'
    for number in ['02','05','06']:
        data=json.loads((ROOT/f'sources/mutopia/25EF-{number}.events.json').read_text(encoding='utf-8'));r=data['recipe']
        original=(ROOT/f'sources/mutopia/25EF-{number}.ly').read_text(encoding='utf-8')
        original=original.replace('set-global-staff-size 16','set-global-staff-size 20')
        original=re.sub(r'^.*PianoStaff.instrumentName.*\n','',original,flags=re.M)
        original=re.sub(r'  \\midi \{.*?\n    \}', '',original,flags=re.S)
        original=original.replace('\\layout {}',r'\layout { \context { \Score \consists #anchor-engraver } }')
        skip={2:'s2',3:'s2.',4:'s1'}[r['numerator']]
        breaks=' '.join(skip+' '+('\\pageBreak' if (i+1)%4==0 else '\\break' if (i+1)%2==0 else '\\noBreak') for i in range(r['bars']))
        original=original.replace('\\Global \\clef treble','\\Global \\clef treble { '+breaks+' }')
        key={'02':'6=A','05':'1=F','06':'1=C'}[number]
        parts=[]
        for part,name in [(2,'Upper'),(1,'Lower')]:
            parts.append('OctavesAfter NoIndent\n'+key+f" {r['numerator']}/4 4={r['bpm']}\n"+repeats(music_bars(data,part),number))
        text='\nNextPart\n'.join(parts)
        txt=folder/f'jianpu{number}.txt';txt.write_text(text,encoding='utf-8')
        generated=subprocess.run([sys.executable,str(ROOT/'output/toolchain/jianpu-ly.py'),str(txt)],capture_output=True,encoding='utf-8',env=env)
        if generated.returncode:raise RuntimeError(generated.stderr)
        jianpu=generated.stdout.replace('\\layout {',r'\layout { \context { \Score \consists #anchor-engraver }')
        # The dash already means continuation. jianpu-ly 1.891 emits hidden
        # chord-to-dash ties with a mismatching placeholder octave; remove only
        # those invisible dash ties, leaving real note-to-note ties untouched.
        jianpu=re.sub(r'~(?=[^\n]*\\note-mod "–")','',jianpu)
        # Render the converter's staccato triangle as a path, not a missing font glyph.
        jianpu=jianpu.replace(r'\finger \markup { \fontsize #-4 "▼" }',r"\finger \markup { \path #0.08 #'((moveto -0.3 0.5) (lineto 0.3 0.5) (lineto 0 -0.4) (closepath)) }")
        midi=jianpu.find('\\score {\n\\unfoldRepeats')
        if midi>=0:jianpu=jianpu[:midi]
        if number=='05':jianpu=jianpu.replace(r'\bar "|."',r'\bar ":|."')
        if number=='06':jianpu=jianpu.replace(r'\bar "|."',r'\bar "||"')
        for name,source in [('staff',original),('jianpu',jianpu)]:
            for stale in folder.glob(f'{name}{number}*.svg'):stale.unlink()
            path=folder/f'{name}{number}.ly'
            path.write_text('\\include "'+(ROOT/'tools/engraving-anchors.ily').as_posix()+'"\n'+source+'\n'+PAPER,encoding='utf-8')
            subprocess.run([str(BIN/'lilypond.exe'),'-dbackend=svg','-o',str(folder/f'{name}{number}'),str(path)],check=True,cwd=ROOT,env=env)

if __name__=='__main__':main()
