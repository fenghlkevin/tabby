from pathlib import Path
import subprocess,ctypes,uuid,shutil,plistlib,hashlib,sys,tempfile,os
version,build=sys.argv[1:3]
root=Path(__file__).resolve().parent.parent;source=root/'dist/Axon.app';target=Path('/Applications/Axon.app');stage=Path('/Applications/.Axon-install-'+uuid.uuid4().hex+'.app')
def run(*args):subprocess.run(args,check=True)
def verify(path):
 # Finder custom metadata is outside signed Contents. Verify a clean copy,
 # removing only the root Finder icon metadata, never signed files.
 if (path/'Icon\r').exists():
  with tempfile.TemporaryDirectory(prefix='axon-signature-') as temporary:
   clean=Path(temporary)/'Axon.app'
   run('ditto',str(path),str(clean))
   (clean/'Icon\r').unlink(missing_ok=True)
   subprocess.run(['xattr','-d','com.apple.FinderInfo',str(clean)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
   run('codesign','--verify','--deep','--strict',str(clean))
 else:run('codesign','--verify','--deep','--strict',str(path))
 with (path/'Contents/Info.plist').open('rb') as f:info=plistlib.load(f)
 assert (info['CFBundleShortVersionString'],info['CFBundleVersion'])==(version,build)
 return hashlib.sha256((path/'Contents/MacOS/TabbyNative').read_bytes()).hexdigest()
(root/f'dist/ui-{version}').mkdir(parents=True, exist_ok=True)
workspace=Path(os.environ.get('TABBY_NATIVE_WORKSPACE', str(Path.home()/'Library/Application Support/TabbyNative/workspace.json')))
expected=verify(source);archive=root/f'dist/Axon-{version}-mac-arm64.zip';run('unzip','-tq',str(archive))
run('ditto',str(source),str(stage))
run('swift',str(root/'scripts/installed-icon.swift'),str(stage),str(workspace))
assert verify(stage)==expected
lib=ctypes.CDLL(None,use_errno=True);swap=lib.renamex_np;swap.argtypes=[ctypes.c_char_p,ctypes.c_char_p,ctypes.c_uint];swap.restype=ctypes.c_int
def exchange():
 if swap(bytes(stage),bytes(target),2)!=0:raise OSError(ctypes.get_errno(),'Cannot replace Axon')
exchange()
try:
 run('swift',str(root/'scripts/installed-icon.swift'),str(target),str(workspace),str(root/f'dist/ui-{version}/installed-file-icon.png'))
 assert verify(target)==expected
except BaseException:exchange();raise
shutil.rmtree(stage)
(root/f'dist/installation-{version}.txt').write_text(f'Installed {version} ({build}), no retained backup, no restart.\nExecutable SHA-256: '+expected+'\n')
print(f'Installed {version} ({build}); no backup retained; no app restart.')
print('ZIP SHA-256: '+hashlib.sha256(archive.read_bytes()).hexdigest())
