import fitz, os, sys

base = r'c:\Users\cubecloud-io\github-pr\pacgate-ai-pr\scope-assets'

files = [
    ('harvey1', 'Harvey 2026年4月全景调研.pdf'),
    ('harvey2', 'Harvey Agent技术应用调研（2026年4月）.pdf'),
    ('crosby1', 'Crosby 深度调研（2025-2026）.pdf'),
    ('crosby2', 'crosby-tech-architecture-analysis.pdf'),
    ('moritz',  'Moritz 深度调研（2025-2026）.pdf'),
    ('concept1', r'original-concept\Pacgate AI Law Firm 浅色科技版.pdf'),
    ('concept2', r'original-concept\法律AI系统产品设计框架.pdf'),
]

target = sys.argv[1] if len(sys.argv) > 1 else 'all'

for key, fname in files:
    if target != 'all' and key != target:
        continue
    path = os.path.join(base, fname)
    print('=' * 70)
    print(f'FILE: {fname}')
    print('=' * 70)
    doc = fitz.open(path)
    full = ''
    for page in doc:
        full += page.get_text()
    doc.close()
    print(full)
    print()
