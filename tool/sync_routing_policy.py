import argparse
from pathlib import Path

parser = argparse.ArgumentParser(description='Synchronize the shared routing policy to the website checkout.')
parser.add_argument('--website-root', type=Path, required=True)
parser.add_argument('--check', action='store_true')
arguments = parser.parse_args()
source = Path(__file__).resolve().parents[1] / 'core/routing_policy.json'
target = arguments.website_root / 'resources/conf/routing_policy.json'
if not (arguments.website_root / 'app/Utils/HappRouting.php').is_file():
    parser.error('website checkout is missing HappRouting.php')
if arguments.check:
    if not target.is_file() or target.read_bytes() != source.read_bytes():
        raise SystemExit('shared routing policy is out of sync')
else:
    target.write_bytes(source.read_bytes())
print('shared routing policy: identical')
