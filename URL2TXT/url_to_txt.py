#!/usr/bin/env python3
# URL -> TXT / Markdown scraper using Playwright Chromium.

from __future__ import annotations

import argparse
import csv
import json
import re
import sys
import time
from pathlib import Path
from typing import Any, Dict, List
from urllib.parse import urlparse

from bs4 import BeautifulSoup
from playwright.sync_api import TimeoutError as PlaywrightTimeoutError
from playwright.sync_api import sync_playwright

DEFAULT_TIMEOUT_MS = 90000
DEFAULT_WAIT_SECONDS = 1.5


def slugify(value: str, max_len: int = 120) -> str:
    value = value.strip().lower()
    value = re.sub(r"https?://", "", value)
    value = re.sub(r"[^a-z0-9._-]+", "-", value)
    value = re.sub(r"-+", "-", value).strip("-._")
    return (value or "page")[:max_len]


def load_urls(input_file: Path | None, single_urls: List[str], csv_input: Path | None = None, csv_column: str = 'url') -> List[str]:
    urls: List[str] = []

    if input_file:
        for line in input_file.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            urls.append(line)

    if csv_input:
        with csv_input.open('r', encoding='utf-8-sig', newline='') as f:
            reader = csv.DictReader(f)
            if not reader.fieldnames:
                raise ValueError(f'CSV input file {csv_input} has no header row')
            if csv_column not in reader.fieldnames:
                raise ValueError(f'CSV column {csv_column!r} not found in {csv_input}. Available columns: {reader.fieldnames}')
            for row in reader:
                u = (row.get(csv_column) or '').strip()
                if u and not u.startswith('#'):
                    urls.append(u)

    for u in single_urls:
        u = u.strip()
        if u:
            urls.append(u)

    deduped: List[str] = []
    seen = set()
    for u in urls:
        if u not in seen:
            deduped.append(u)
            seen.add(u)
    return deduped


def clean_text(text: str) -> str:
    text = text.replace("\u00a0", " ")
    lines = [re.sub(r"[ \t]+", " ", line).strip() for line in text.splitlines()]
    cleaned_lines: List[str] = []
    last_blank = False
    for line in lines:
        is_blank = line == ""
        if is_blank and last_blank:
            continue
        cleaned_lines.append(line)
        last_blank = is_blank
    return "\n".join(cleaned_lines).strip() + "\n"


def read_visible_text(page) -> str:
    js = """
() => {
  function isVisible(el) {
    const style = window.getComputedStyle(el);
    if (!style) return false;
    if (style.visibility === 'hidden' || style.display === 'none') return false;
    const rect = el.getBoundingClientRect();
    return rect.width > 0 && rect.height > 0;
  }

  const candidates = [
    document.querySelector('main'),
    document.querySelector('[role="main"]'),
    document.querySelector('article'),
    document.body
  ].filter(Boolean);

  const root = candidates[0] || document.body;
  let text = root.innerText || '';
  if (!text.trim()) {
    text = [...root.querySelectorAll('*')]
      .filter(isVisible)
      .map(el => (el.innerText || '').trim())
      .filter(Boolean)
      .join('\n');
  }
  return text;
}
"""
    return page.evaluate(js)


def expand_everything(page, attempts: int = 3, settle_ms: int = 500) -> int:
    total_clicked = 0
    js = """
() => {
  function visible(el) {
    if (!el) return false;
    const style = window.getComputedStyle(el);
    const rect = el.getBoundingClientRect();
    return style.display !== 'none' && style.visibility !== 'hidden' && rect.width > 0 && rect.height > 0;
  }

  const clickedEls = new Set();
  const selectors = [
    'details:not([open]) > summary',
    '[aria-expanded="false"]',
    'button[aria-controls]',
    '[role="button"][aria-controls]',
    'button',
    '[role="button"]',
    '.accordion button', '.accordion [role="button"]',
    '.collapsible button', '.disclosure button'
  ];

  const terms = [
    'expand', 'show more', 'show all', 'more', 'details', 'see more', 'read more',
    'expand all', 'show', 'attributes', 'examples', 'response', 'request', 'schema'
  ];

  function shouldClick(el) {
    if (!visible(el)) return false;
    if (el.disabled) return false;
    const txt = ((el.innerText || el.textContent || '').trim().toLowerCase());
    const ariaExpanded = el.getAttribute('aria-expanded');
    const tag = (el.tagName || '').toLowerCase();
    if (tag === 'summary') return true;
    if (ariaExpanded === 'false') return true;
    if (txt && terms.some(t => txt === t || txt.includes(t))) return true;
    return false;
  }

  document.querySelectorAll('details').forEach(d => d.open = true);

  let count = 0;
  for (const sel of selectors) {
    for (const el of document.querySelectorAll(sel)) {
      if (!clickedEls.has(el) && shouldClick(el)) {
        try {
          el.click();
          clickedEls.add(el);
          count++;
        } catch (e) {}
      }
    }
  }

  const maybeExpandAll = [...document.querySelectorAll('button, [role="button"], a')]
    .find(el => {
      const txt = ((el.innerText || el.textContent || '').trim().toLowerCase());
      return visible(el) && (txt === 'expand all' || txt.includes('expand all') || txt.includes('show all'));
    });
  if (maybeExpandAll) {
     try { maybeExpandAll.click(); count++; } catch (e) {}
  }

  return count;
}
"""
    for _ in range(attempts):
        clicked = page.evaluate(js)
        total_clicked += int(clicked or 0)
        page.wait_for_timeout(settle_ms)
    return total_clicked


def auto_scroll(page, max_rounds: int = 20, settle_ms: int = 700) -> None:
    prev_height = -1
    stable_rounds = 0
    for _ in range(max_rounds):
        height = page.evaluate("() => document.body.scrollHeight")
        page.evaluate("(h) => window.scrollTo(0, h)", height)
        page.wait_for_timeout(settle_ms)
        new_height = page.evaluate("() => document.body.scrollHeight")
        if new_height == prev_height:
            stable_rounds += 1
        else:
            stable_rounds = 0
        if stable_rounds >= 2:
            break
        prev_height = new_height
    page.evaluate("() => window.scrollTo(0, 0)")
    page.wait_for_timeout(250)


def extract_text_from_html(html: str) -> str:
    soup = BeautifulSoup(html, "lxml")
    for tag in soup(["script", "style", "noscript", "svg", "canvas"]):
        tag.decompose()
    main = soup.find("main") or soup.find(attrs={"role": "main"}) or soup.find("article") or soup.body or soup
    text = main.get_text("\n", strip=True)
    return clean_text(text)


def escape_markdown(text: str) -> str:
    return text.replace('\\', '\\\\').replace('|', '\\|')


def build_output_text(meta: Dict[str, Any], format_name: str = 'txt') -> str:
    if format_name == 'md':
        title = meta.get('title') or meta.get('final_url') or meta.get('url') or 'Untitled'
        lines = [
            f"# {escape_markdown(title)}",
            "",
            f"- **URL:** {escape_markdown(str(meta.get('final_url') or meta.get('url') or ''))}",
            f"- **HTTP status:** {escape_markdown(str(meta.get('status_code')))}",
            f"- **Expanded UI elements clicked:** {escape_markdown(str(meta.get('clicked_expanders')))}",
            f"- **Extracted at:** {escape_markdown(time.strftime('%Y-%m-%d %H:%M:%S %Z'))}",
            "",
            "---",
            "",
            meta['text'].rstrip(),
            "",
        ]
        return "\n".join(lines)

    header = [
        f"Title: {meta.get('title', '')}",
        f"URL: {meta.get('final_url') or meta.get('url')}",
        f"HTTP status: {meta.get('status_code')}",
        f"Expanded UI elements clicked: {meta.get('clicked_expanders')}",
        f"Extracted at: {time.strftime('%Y-%m-%d %H:%M:%S %Z')}",
        "",
        "=" * 80,
        "",
    ]
    return "\n".join(header) + meta['text']


def fetch_one(page, url: str, wait_seconds: float, timeout_ms: int) -> Dict[str, Any]:
    start = time.time()
    meta: Dict[str, Any] = {
        'url': url,
        'ok': False,
        'title': '',
        'duration_seconds': None,
        'clicked_expanders': 0,
    }

    response = None
    try:
        response = page.goto(url, wait_until='domcontentloaded', timeout=timeout_ms)
        page.wait_for_load_state('networkidle', timeout=timeout_ms)
    except PlaywrightTimeoutError:
        pass

    page.wait_for_timeout(int(wait_seconds * 1000))
    auto_scroll(page)
    clicked = expand_everything(page)
    auto_scroll(page)
    if clicked:
        page.wait_for_timeout(800)
        clicked += expand_everything(page, attempts=2, settle_ms=400)
    page.wait_for_timeout(int(wait_seconds * 1000))

    title = page.title() or ''
    current_url = page.url
    visible_text = read_visible_text(page)
    html = page.content()

    cleaned = clean_text(visible_text)
    if len(cleaned) < 500:
        parsed_fallback = extract_text_from_html(html)
        if len(parsed_fallback) > len(cleaned):
            cleaned = parsed_fallback

    status = None
    if response is not None:
        try:
            status = response.status
        except Exception:
            status = None

    meta.update({
        'ok': bool(cleaned.strip()),
        'final_url': current_url,
        'title': title,
        'status_code': status,
        'duration_seconds': round(time.time() - start, 2),
        'clicked_expanders': clicked,
        'characters': len(cleaned),
        'text': cleaned,
    })
    return meta


def write_csv_report(csv_report: Path, manifest: List[Dict[str, Any]]) -> None:
    fieldnames = [
        'url', 'final_url', 'title', 'ok', 'status_code', 'duration_seconds',
        'clicked_expanders', 'characters', 'output_file', 'format', 'error'
    ]
    with csv_report.open('w', encoding='utf-8', newline='') as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        for item in manifest:
            writer.writerow({key: item.get(key) for key in fieldnames})


def main() -> int:
    ap = argparse.ArgumentParser(description='Convert a list of URLs into .txt or .md files using a real browser.')
    ap.add_argument('--input', type=Path, help='Text file containing one URL per line')
    ap.add_argument('--csv-input', type=Path, help='CSV input file containing URLs')
    ap.add_argument('--csv-column', default='url', help='Column name in --csv-input that contains URLs (default: url)')
    ap.add_argument('--url', action='append', default=[], help='Single URL. Can be passed multiple times.')
    ap.add_argument('--output', type=Path, default=Path('out'), help='Output directory for exported files')
    ap.add_argument('--format', choices=['txt', 'md'], default='txt', help='Export format for page content (default: txt)')
    ap.add_argument('--combine', type=Path, help='Optional combined output file containing all pages')
    ap.add_argument('--manifest', type=Path, default=Path('manifest.json'), help='Write a JSON manifest with results')
    ap.add_argument('--csv-report', type=Path, help='Optional CSV summary report for all processed URLs')
    ap.add_argument('--wait', type=float, default=DEFAULT_WAIT_SECONDS, help='Extra wait time in seconds after rendering and after expanding sections')
    ap.add_argument('--headed', action='store_true', help='Run with a visible browser window (useful for troubleshooting)')
    ap.add_argument('--timeout-ms', type=int, default=DEFAULT_TIMEOUT_MS, help='Navigation/load timeout in milliseconds')
    args = ap.parse_args()

    urls = load_urls(args.input, args.url, csv_input=args.csv_input, csv_column=args.csv_column)
    if not urls:
        print('ERROR: no URLs were provided. Use --input urls.txt, --csv-input urls.csv, or --url https://example.com', file=sys.stderr)
        return 2

    args.output.mkdir(parents=True, exist_ok=True)
    manifest: List[Dict[str, Any]] = []
    combined_chunks: List[str] = []
    ext = 'md' if args.format == 'md' else 'txt'

    with sync_playwright() as p:
        browser = p.chromium.launch(headless=not args.headed)
        context = browser.new_context(
            user_agent='Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36',
            viewport={'width': 1440, 'height': 2000},
            locale='en-US',
        )
        page = context.new_page()
        page.set_default_timeout(args.timeout_ms)

        for idx, url in enumerate(urls, start=1):
            print(f'[{idx}/{len(urls)}] Fetching: {url}', flush=True)
            try:
                result = fetch_one(page, url, wait_seconds=args.wait, timeout_ms=args.timeout_ms)
            except Exception as exc:
                result = {
                    'url': url,
                    'ok': False,
                    'title': '',
                    'status_code': None,
                    'clicked_expanders': 0,
                    'duration_seconds': None,
                    'characters': 0,
                    'error': f'{type(exc).__name__}: {exc}',
                    'text': '',
                }

            parsed = urlparse(result.get('final_url') or url)
            stem = slugify(f"{parsed.netloc}{parsed.path}")
            out_file = args.output / f"{stem}.{ext}"

            if result.get('ok'):
                rendered = build_output_text(result, format_name=args.format)
                out_file.write_text(rendered, encoding='utf-8')
                print(f"  Wrote: {out_file} ({result.get('characters', 0)} chars, {result.get('clicked_expanders', 0)} expand/clicks)", flush=True)
                if args.combine:
                    combined_chunks.append(build_output_text(result, format_name=args.format))
            else:
                print(f"  FAILED: {url} :: {result.get('error', 'No text extracted')}", file=sys.stderr, flush=True)

            manifest_record = {k: v for k, v in result.items() if k != 'text'}
            manifest_record['output_file'] = str(out_file)
            manifest_record['format'] = args.format
            manifest.append(manifest_record)

        context.close()
        browser.close()

    args.manifest.write_text(json.dumps(manifest, indent=2, ensure_ascii=False), encoding='utf-8')
    print(f'Manifest written to: {args.manifest}')

    if args.csv_report:
        write_csv_report(args.csv_report, manifest)
        print(f'CSV report written to: {args.csv_report}')

    if args.combine and combined_chunks:
        separator = "\n\n" + ("-" * 100 if args.format == 'md' else "=" * 100) + "\n\n"
        args.combine.write_text(separator.join(combined_chunks), encoding='utf-8')
        print(f'Combined output written to: {args.combine}')

    failures = sum(1 for x in manifest if not x.get('ok'))
    return 1 if failures else 0


if __name__ == '__main__':
    raise SystemExit(main())
