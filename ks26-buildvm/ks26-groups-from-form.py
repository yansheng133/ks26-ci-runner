#!/usr/bin/env python3
"""Google Form 匯出的 CSV → watcher 的 groups.conf

為什麼要有這支：段 1 的 ⏱13:00 助教要在時間壓力下手打 8 行 GitHub 網址。
打錯一個字，那一組整場靜靜地不會 build，而且沒有人會發現。

用法：
    ./ks26-groups-from-form.py responses.csv > groups.conf
    ./ks26-groups-from-form.py responses.csv --branch main --out groups.conf

它不假設 Google Form 的欄位順序或題目文字（那是你自己設計的），
而是掃每一列找「組號」與「GitHub 網址」，同一組有多次填答時取最後一次。
"""
import argparse, csv, re, sys

# 組號有三種寫法：group1／組 1（數字在後）、第 1 組（數字在前）、純數字
GROUP_RES = [re.compile(r'(?:group|組)\s*[-_ ]?([1-8])\b', re.I),
             re.compile(r'第\s*([1-8])\s*組'),
             re.compile(r'^\s*([1-8])\s*$')]
REPO_RE  = re.compile(r'https?://(?:www\.)?github\.com/([A-Za-z0-9._-]+)/([A-Za-z0-9._-]+)', re.I)

def normalise(owner, repo):
    repo = re.sub(r'\.git$', '', repo)
    return f"https://github.com/{owner}/{repo}"

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("csvfile")
    ap.add_argument("--branch", default="main")
    ap.add_argument("--groups", type=int, default=8)
    ap.add_argument("--out")
    a = ap.parse_args()

    found, problems = {}, []
    with open(a.csvfile, newline="", encoding="utf-8-sig") as fh:
        for lineno, row in enumerate(csv.reader(fh), 1):
            if not any(c.strip() for c in row):
                continue
            g = None
            for cell in row:
                for rx in GROUP_RES:
                    m = rx.search(cell)
                    if m:
                        g = int(m.group(1)); break
                if g: break
            r = None
            for cell in row:
                m = REPO_RE.search(cell)
                if m:
                    r = normalise(m.group(1), m.group(2)); break
            if g and r:
                if g in found and found[g][0] != r:
                    problems.append(f"第 {g} 組填了兩個不同的網址，採用較晚的：{found[g][0]} → {r}")
                found[g] = (r, lineno)          # 後面的覆蓋前面的＝取最後一次填答
            elif r and not g:
                problems.append(f"第 {lineno} 行有網址但看不出組號：{r}")
            elif g and not r:
                problems.append(f"第 {lineno} 行有組號 {g} 但沒有 GitHub 網址")

    out = ["# 由 ks26-groups-from-form.py 產生：<組> <repo> <分支>"]
    missing = []
    for g in range(1, a.groups + 1):
        if g in found:
            out.append(f"group{g} {found[g][0]} {a.branch}")
        else:
            missing.append(g)
            out.append(f"# group{g} —— 表單裡沒有這一組，補上網址後把 # 拿掉")

    text = "\n".join(out) + "\n"
    if a.out:
        open(a.out, "w", encoding="utf-8").write(text)
        print(f"寫入 {a.out}：{len(found)} 組", file=sys.stderr)
    else:
        sys.stdout.write(text)

    for p in problems:
        print(f"注意：{p}", file=sys.stderr)
    if missing:
        print(f"缺少：第 {', '.join(map(str, missing))} 組沒有填表——開跑前要補", file=sys.stderr)
    return 1 if missing else 0

if __name__ == "__main__":
    sys.exit(main())
