#!/usr/bin/env python3
"""Download public GeoData and verify GitHub's release asset digests."""
import hashlib
import json
from pathlib import Path
import tempfile
from urllib.request import Request, urlopen

REPOSITORY = 'MetaCubeX/meta-rules-dat'
FILES = {
    'geoip.dat': ('geoip', 'GEOIP.dat'),
    'geosite.dat': ('geosite', 'GEOSITE.dat'),
    'geoip.metadb': ('mmdb', 'GEOIP.metadb'),
    'GeoLite2-ASN.mmdb': ('asn', 'ASN.mmdb'),
}


def fetch(url):
    return urlopen(Request(url, headers={'User-Agent': 'flclash-client-shell'}), timeout=120)


def main():
    target = Path(__file__).resolve().parents[1] / 'assets/data'
    target.mkdir(parents=True, exist_ok=True)
    with fetch(f'https://api.github.com/repos/{REPOSITORY}/releases/tags/latest') as response:
        release = json.load(response)
    assets = {asset['name']: asset for asset in release['assets']}
    lock = ['schema=1', f"source.ref=release-{release['id']}"]
    with tempfile.TemporaryDirectory(dir=target) as directory:
        staged = Path(directory)
        for name, (key, destination) in FILES.items():
            asset = assets[name]
            digest = asset.get('digest', '')
            if not digest.startswith('sha256:') or len(digest) != 71:
                raise RuntimeError(f'Missing SHA-256 release digest: {name}')
            url = asset['browser_download_url']
            if not url.startswith(f'https://github.com/{REPOSITORY}/releases/download/'):
                raise RuntimeError(f'Unexpected release URL: {name}')
            with fetch(url) as response, (staged / destination).open('wb') as output:
                checksum = hashlib.sha256()
                size = 0
                while chunk := response.read(1024 * 1024):
                    output.write(chunk)
                    checksum.update(chunk)
                    size += len(chunk)
            if size != asset['size'] or checksum.hexdigest() != digest[7:]:
                raise RuntimeError(f'Release size or digest mismatch: {name}; retry the download')
            lock.extend([f'source.{key}={url}', f'{key}.file={destination}',
                         f'{key}.size={size}', f'{key}.sha256={checksum.hexdigest()}'])
        for _, destination in FILES.values():
            (staged / destination).replace(target / destination)
    (target / 'GEODATA.lock').write_text('\n'.join(lock) + '\n', encoding='utf-8')
    print('Verified four public GeoData assets')


if __name__ == '__main__':
    main()
