#!/usr/bin/env bash
set -euo pipefail

if [ ! -d "src/agent_harness" ]; then
  echo "ERROR: Run this from inside the agent-harness folder."
  echo "Example:"
  echo "  cd ~/agent-harness"
  echo "  bash patch_agent_harness_v21c_research_search_fix.sh"
  exit 1
fi

BACKUP_DIR="patch_backup_v21c_research_search_fix_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$BACKUP_DIR"

for f in research_flow.py max_cli.py; do
  if [ -f "src/agent_harness/$f" ]; then
    cp "src/agent_harness/$f" "$BACKUP_DIR/$f.bak"
  fi
done

echo "Backup saved to: $BACKUP_DIR"

python3 - <<'PY'
from pathlib import Path
import re

p = Path("src/agent_harness/research_flow.py")
text = p.read_text()

new_extract = r'''def _extract_search_urls(raw_html: str) -> list[str]:
    urls: list[str] = []
    seen: set[str] = set()

    for match in re.finditer(r"""href=["']([^"']+)["']""", raw_html):
        href = html.unescape(match.group(1)).strip()

        if not href:
            continue

        if href.startswith("//"):
            href = "https:" + href

        # DuckDuckGo often returns relative redirect links:
        #   /l/?uddg=https%3A%2F%2Fexample.com
        if href.startswith("/l/") or href.startswith("/l?"):
            href = "https://duckduckgo.com" + href

        parsed = urllib.parse.urlparse(href)
        host = parsed.hostname or ""

        final_url = ""

        # DuckDuckGo redirect links store the real page in the uddg query param.
        if "duckduckgo.com" in host and parsed.path.startswith("/l"):
            qs = urllib.parse.parse_qs(parsed.query)
            uddg = qs.get("uddg", [""])[0]
            if uddg:
                final_url = urllib.parse.unquote(uddg)

        # Some search engines use /url?q=<real-url>.
        elif parsed.path == "/url":
            qs = urllib.parse.parse_qs(parsed.query)
            q_value = qs.get("q", [""])[0]
            if q_value:
                final_url = urllib.parse.unquote(q_value)

        elif parsed.scheme in {"http", "https"}:
            final_url = href

        if not final_url:
            continue

        final_parsed = urllib.parse.urlparse(final_url)
        final_host = final_parsed.hostname or ""

        if final_parsed.scheme not in {"http", "https"}:
            continue

        if not final_host:
            continue

        if any(skip in final_host for skip in [
            "duckduckgo.com",
            "google.com",
            "bing.com",
            "yahoo.com",
        ]):
            continue

        if final_url in seen:
            continue

        seen.add(final_url)
        urls.append(final_url)

    return urls
'''

new_search = r'''def _search_duckduckgo(project: Path, config: dict[str, Any], query: str, limit: int) -> tuple[list[str], str]:
    encoded = urllib.parse.urlencode({"q": query})
    search_urls = [
        f"https://html.duckduckgo.com/html/?{encoded}",
        f"https://lite.duckduckgo.com/lite/?{encoded}",
    ]

    errors: list[str] = []

    for search_url in search_urls:
        result = _fetch_url(project, config, search_url)
        if not result.get("ok"):
            errors.append(str(result.get("error") or f"Search failed for {search_url}"))
            continue

        urls = _extract_search_urls(str(result.get("text") or ""))
        if urls:
            return urls[:limit], ""

        errors.append(f"No result links parsed from {search_url}")

    if errors:
        return [], "; ".join(errors)

    return [], "Search failed."
'''

text = re.sub(
    r'def _extract_search_urls\(raw_html: str\) -> list\[str\]:\n.*?\n(?=def _search_duckduckgo)',
    new_extract + "\n\n",
    text,
    flags=re.S,
)

text = re.sub(
    r'def _search_duckduckgo\(project: Path, config: dict\[str, Any\], query: str, limit: int\) -> tuple\[list\[str\], str\]:\n.*?\n(?=def _read_url)',
    new_search + "\n\n",
    text,
    flags=re.S,
)

p.write_text(text)
PY

python3 -m compileall src/agent_harness

echo ""
echo "v0.21c research search parser fix installed."
echo ""
echo "Now run:"
echo "  max config set allow_network true"
echo "  max research \"python argparse examples\" --limit 3"
echo "  max research history"
echo "  ls -lh test-project/workspace/research-notes"
