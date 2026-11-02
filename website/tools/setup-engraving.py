"""Download pinned public offline tools into output/toolchain; no account or global install."""
from pathlib import Path
import hashlib, urllib.request, zipfile
ROOT=Path(__file__).resolve().parent.parent/'output/toolchain'
FILES=[
 ('lilypond-2.24.4.zip','https://gitlab.com/lilypond/lilypond/-/releases/v2.24.4/downloads/lilypond-2.24.4-mingw-x86_64.zip','e238f5a33ebde7466fe03d0fbcaa155a44536ca582951972482e0b00ceb0fbf1'),
 ('jianpu-ly.py','https://ssb22.user.srcf.net/mwrhome/jianpu-ly.py','00e7ecea3bd97a201b72e1f42125e3f40a3395619ccb44e6f410cfe320773838'),
]
def main():
 ROOT.mkdir(parents=True,exist_ok=True)
 for name,url,expected in FILES:
  path=ROOT/name
  data=path.read_bytes() if path.exists() else urllib.request.urlopen(url,timeout=120).read()
  if hashlib.sha256(data).hexdigest()!=expected:raise ValueError(f'{name}: SHA-256 differs; do not silently upgrade')
  if not path.exists():path.write_bytes(data)
  print(name,expected)
  if name.endswith('.zip') and not (ROOT/'lilypond-2.24.4/bin/lilypond.exe').exists():
   with zipfile.ZipFile(path) as archive:
    for member in archive.infolist():
     if not (ROOT/member.filename).resolve().is_relative_to(ROOT.resolve()):raise ValueError('unsafe archive path')
    archive.extractall(ROOT)
if __name__=='__main__':main()
