#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SITE_DIR="$SCRIPT_DIR/site"
export DOCS_DIR="$SCRIPT_DIR"

mkdir -p "$SITE_DIR"

# Copy stylesheet to site output
cp -f "$SCRIPT_DIR/style.css" "$SITE_DIR/style.css"

# Convert Markdown files and generate static HTML pages
python3 - << 'EOF'
import os
import sys
import re
import html

try:
    import markdown
    def md_to_html(text):
        return markdown.markdown(text, extensions=['fenced_code', 'tables'])
except ImportError:
    def md_to_html(text):
        lines = text.splitlines()
        out = []
        in_code = False
        in_ul = False
        in_table = False
        
        for line in lines:
            if line.startswith("```"):
                if in_code:
                    out.append("</code></pre>")
                    in_code = False
                else:
                    lang = line[3:].strip()
                    cls = f' class="language-{html.escape(lang)}"' if lang else ''
                    out.append(f'<pre><code{cls}>')
                    in_code = True
                continue
            if in_code:
                out.append(html.escape(line))
                continue
            
            stripped = line.strip()
            if not stripped:
                if in_ul:
                    out.append("</ul>")
                    in_ul = False
                if in_table:
                    out.append("</table>")
                    in_table = False
                continue
            
            if stripped.startswith("# "):
                out.append(f"<h1>{html.escape(stripped[2:])}</h1>")
            elif stripped.startswith("## "):
                out.append(f"<h2>{html.escape(stripped[3:])}</h2>")
            elif stripped.startswith("### "):
                out.append(f"<h3>{html.escape(stripped[4:])}</h3>")
            elif stripped.startswith("---"):
                out.append("<hr>")
            elif stripped.startswith("* ") or stripped.startswith("- "):
                if not in_ul:
                    out.append("<ul>")
                    in_ul = True
                item = stripped[2:]
                item = re.sub(r'\*\*(.+?)\*\*', r'<strong>\1</strong>', item)
                item = re.sub(r'`([^`]+)`', r'<code>\1</code>', item)
                out.append(f"<li>{item}</li>")
            elif stripped.startswith("|") and stripped.endswith("|"):
                cells = [c.strip() for c in stripped.strip("|").split("|")]
                if all(re.match(r"^:?-+:?$", c) for c in cells):
                    continue
                if not in_table:
                    out.append("<table>")
                    in_table = True
                    tag = "th"
                else:
                    tag = "td"
                row_html = "".join(f"<{tag}>{re.sub(r'`([^`]+)`', r'<code>\1</code>', re.sub(r'\*\*(.+?)\*\*', r'<strong>\1</strong>', c))}</{tag}>" for c in cells)
                out.append(f"<tr>{row_html}</tr>")
            else:
                p_text = re.sub(r'\*\*(.+?)\*\*', r'<strong>\1</strong>', stripped)
                p_text = re.sub(r'`([^`]+)`', r'<code>\1</code>', p_text)
                out.append(f"<p>{p_text}</p>")
        
        if in_ul: out.append("</ul>")
        if in_table: out.append("</table>")
        if in_code: out.append("</code></pre>")
        return "\n".join(out)

docs_dir = os.environ.get("DOCS_DIR") or os.path.dirname(os.path.abspath(__file__))
src_dir = os.path.join(docs_dir, "src")
site_dir = os.path.join(docs_dir, "site")

pages = [
    ("overview", "Overview"),
    ("getting-started", "Getting Started"),
    ("user-guide", "User Guide"),
    ("configuration", "Configuration"),
]

template = """<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>{title} — Mizu Documentation</title>
  <link rel="stylesheet" href="{css_path}">
</head>
<body>
  <header class="top-nav">
    <a href="{brand_href}" class="brand">
      <span class="symbol">水</span>
      <span>Mizu</span>
    </a>
    <div class="nav-links">
      <a href="https://github.com/mizu-shell/mizu" target="_blank" rel="noopener">GitHub</a>
    </div>
  </header>

  <div class="layout">
    <aside class="sidebar">
      <div class="sidebar-title">Documentation</div>
      <nav>
        <ul>
{nav_items}
        </ul>
      </nav>
    </aside>

    <main class="content">
{content}
    </main>
  </div>

  <footer class="doc-footer">
    Mizu (水) Desktop Shell — Fast, lightweight Wayland shell for Void Linux and MangoWC
  </footer>
</body>
</html>
"""

# Render site/*.html pages
for slug, title in pages:
    md_path = os.path.join(src_dir, f"{slug}.md")
    if not os.path.exists(md_path):
        print(f"Warning: {md_path} not found")
        continue

    with open(md_path, "r", encoding="utf-8") as f:
        md_text = f.read()

    html_content = md_to_html(md_text)

    # Append example configuration for configuration page
    if slug == "configuration":
        config_paths = [
            os.path.join(docs_dir, "..", "config", "config.example"),
            os.path.join(docs_dir, "..", "config.example"),
            os.path.join(docs_dir, "config.example"),
        ]
        for cp in config_paths:
            if os.path.exists(cp):
                with open(cp, "r", encoding="utf-8") as cf:
                    cfg_text = html.escape(cf.read())
                html_content += f'\n<hr>\n<h2>Example Configuration</h2>\n<pre><code class="language-ini">{cfg_text}</code></pre>'
                break

    # Build navigation for pages inside site/
    nav_lines = []
    for nav_slug, nav_title in pages:
        active_cls = ' class="active"' if nav_slug == slug else ''
        nav_lines.append(f'          <li><a href="{nav_slug}.html"{active_cls}>{nav_title}</a></li>')
    nav_items = "\n".join(nav_lines)

    rendered = template.format(
        title=title,
        css_path="style.css",
        brand_href="overview.html",
        nav_items=nav_items,
        content=html_content
    )

    out_file = os.path.join(site_dir, f"{slug}.html")
    with open(out_file, "w", encoding="utf-8") as f:
        f.write(rendered)
    print(f"Generated {out_file}")

# Generate docs/site/index.html (copy of overview.html)
overview_site = os.path.join(site_dir, "overview.html")
index_site = os.path.join(site_dir, "index.html")
if os.path.exists(overview_site):
    with open(overview_site, "r", encoding="utf-8") as f:
        overview_content = f.read()
    with open(index_site, "w", encoding="utf-8") as f:
        f.write(overview_content)
    print(f"Generated {index_site}")

# Generate docs/index.html at docs/ root with navigation links pointing to site/*.html
overview_md = os.path.join(src_dir, "overview.md")
with open(overview_md, "r", encoding="utf-8") as f:
    overview_html = md_to_html(f.read())

root_nav_lines = []
for nav_slug, nav_title in pages:
    active_cls = ' class="active"' if nav_slug == "overview" else ''
    root_nav_lines.append(f'          <li><a href="site/{nav_slug}.html"{active_cls}>{nav_title}</a></li>')
root_nav_items = "\n".join(root_nav_lines)

root_index_html = template.format(
    title="Overview",
    css_path="style.css",
    brand_href="site/overview.html",
    nav_items=root_nav_items,
    content=overview_html
)

root_index_path = os.path.join(docs_dir, "index.html")
with open(root_index_path, "w", encoding="utf-8") as f:
    f.write(root_index_html)
print(f"Generated {root_index_path}")
EOF

echo "Mizu documentation site successfully built in: $SITE_DIR"
