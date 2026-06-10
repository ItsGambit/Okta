# URL to TXT / Markdown Scraper

A Python + Playwright scraper that loads pages in a real Chromium browser, expands common collapsible sections, waits for JavaScript-rendered content, and exports the resulting page text as either **plain text (`.txt`)** or **Markdown (`.md`)**.

This project is designed for Ubuntu Desktop and includes a Bash installer/bootstrap script.

---

## What this project does

The scraper is useful for documentation sites, API references, and modern web apps where content may be:

- rendered with JavaScript
- hidden inside accordions, expandable sections, or `<details>` blocks
- loaded lazily during scrolling

The script will:

1. Open each URL in **Chromium** using **Playwright**
2. Wait for the page to render
3. Scroll the page to trigger lazy-loaded content
4. Attempt to expand common collapsible UI sections
5. Extract the rendered visible text
6. Save the result as **`.txt`** or **`.md`**
7. Write a **JSON manifest** and optionally a **CSV report**

---

## Files included

- `url_to_txt.py` — main Python scraper
- `install_and_run.sh` — Bash script to install dependencies and set up a virtual environment on Ubuntu
- `urls.txt` — sample text input file (one URL per line)
- `urls.csv` — sample CSV input file with a `url` column
- `README_url_to_txt.md` — this README
