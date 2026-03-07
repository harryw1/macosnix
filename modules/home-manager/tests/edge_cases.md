---
title: mdconvert Edge-Case Reference
subtitle: All the things that tend to break
author: Harrison Weiss
organization: DCAS BST
date: March 7, 2026
---

This document exercises every known edge case in the conversion pipeline.
If it renders cleanly, the converter is working correctly.

---

## 1. Tables

### 1a. Standard table (baseline)

| Name          | Role           | Status  |
|---------------|----------------|---------|
| Alice         | Engineer       | Active  |
| Bob           | Designer       | On leave |
| Charlie       | Product        | Active  |

### 1b. Wide table (8 columns — overflow risk)

| ID  | Service       | Region | P50 ms | P99 ms | Error % | Owner   | On-call  |
|-----|---------------|--------|--------|--------|---------|---------|----------|
| 001 | API Gateway   | us-east| 42     | 180    | 0.01%   | Alice   | Team A   |
| 002 | Auth Service  | us-west| 18     | 95     | 0.00%   | Bob     | Team B   |
| 003 | Search Index  | eu-west| 110    | 640    | 1.80%   | Charlie | Team C   |
| 004 | Batch Ingest  | ap-east| —      | —      | 2.60%   | Dana    | Team D   |
| 005 | Cache Layer   | us-east| 3      | 12     | 0.00%   | Eve     | Team A   |

### 1c. Inline formatting inside cells (bold, italic, `code`)

| Package       | Version       | Notes                                |
|---------------|---------------|--------------------------------------|
| **python-docx** | `1.1.2`     | Primary docx builder                 |
| *weasyprint*  | `60.x`        | HTML → PDF; needs system Cairo/Pango |
| `markdown`    | **3.6**       | Parses MD extensions                 |
| `pyyaml`      | *6.0*         | YAML front-matter parsing            |

### 1d. Empty cells (ragged rows)

| Col A | Col B | Col C |
|-------|-------|-------|
| One   |       | Three |
|       | Two   |       |
| Four  | Five  |       |

### 1e. Table without a header row (no `thead`)

<!-- The markdown library always generates thead for the first row, but
     this documents intent and the no-thead fallback path. -->

| A | B | C |
|---|---|---|
| 1 | 2 | 3 |
| 4 | 5 | 6 |

### 1f. Two tables back-to-back (no gap paragraph between them)

| X | Y |
|---|---|
| 1 | 2 |

| P | Q | R |
|---|---|---|
| a | b | c |
| d | e | f |

### 1g. Single-column table

| Item                               |
|------------------------------------|
| Alpha                              |
| Beta                               |
| Gamma with a very long description that should wrap inside the cell without overflowing |

### 1h. Very long content in cells (wrapping stress test)

| Field         | Value                                                                                                       |
|---------------|-------------------------------------------------------------------------------------------------------------|
| Description   | This is an intentionally long description to verify that cell content wraps correctly and does not overflow the page or the cell boundary in any output format. |
| Command       | `uv run mdconvert -f docx -t notes very_long_filename_that_might_cause_issues.md output_document.docx`     |
| Notes         | **Important:** review output carefully; *italic emphasis* and `inline code` must all survive wrapping.      |

---

## 2. Lists

### 2a. Three-level nested unordered list

- Level 1 item A
    - Level 2 item A.1
        - Level 3 item A.1.i
        - Level 3 item A.1.ii
    - Level 2 item A.2
- Level 1 item B
    - Level 2 item B.1

### 2b. Three-level nested ordered list

1. First step
    1. Sub-step 1.1
        1. Sub-sub-step 1.1.1
        2. Sub-sub-step 1.1.2
    2. Sub-step 1.2
2. Second step

### 2c. Mixed ordered and unordered

1. Do the thing
    - Option A
    - Option B
2. Then do the next thing
    - Option X
        1. Sub-option X.1
        2. Sub-option X.2

### 2d. List with inline formatting

- **Bold item** — should appear bold throughout
- *Italic item* — should appear italic
- Item with `inline code` inside it
- Item with a [link](https://example.com) inside it
- ~~Strikethrough item~~ — struck through

---

## 3. Headings (all six levels)

### 3a. Heading cascade

# H1 — Top-level section
## H2 — Subsection
### H3 — Sub-subsection
#### H4 — Minor heading
##### H5 — Rarely used
###### H6 — Smallest heading

Paragraph following immediately after H6 — no extra space should be inserted.

---

## 4. Code

### 4a. Inline code in a sentence

Run `uv run mdconvert -f pdf report.md` to produce a PDF, or use `md2pdf report.md` via the shell alias.

### 4b. Fenced code block — Python

```python
def build_docx(meta: dict, html: str, palette: dict, template: str) -> bytes:
    """Convert parsed HTML to a styled python-docx Document."""
    doc = Document()
    for section in doc.sections:
        section.top_margin    = Inches(1)
        section.bottom_margin = Inches(1)
    _walk_block(doc, BeautifulSoup(html, "html.parser"), palette, template)
    buf = BytesIO()
    doc.save(buf)
    return buf.getvalue()
```

### 4c. Fenced code block — shell (hyphenated language tag)

```shell-session
$ md2docx quarterly-review.md
✓  quarterly-review.docx
$ md2pdf  quarterly-review.md
✓  quarterly-review.pdf
```

### 4d. Long line in code block (horizontal-scroll test)

```text
SELECT service_name, region, AVG(latency_p50) AS avg_p50, AVG(latency_p99) AS avg_p99, SUM(error_count) AS total_errors FROM metrics WHERE recorded_at >= NOW() - INTERVAL '30 days' GROUP BY service_name, region ORDER BY avg_p99 DESC;
```

---

## 5. Blockquotes

> Single-line blockquote.

> Multi-line blockquote.
> The second line continues here.
> And a third line as well.

> **Blockquote with formatting**: *italicised text* and `code` inside a quote.

---

## 6. Horizontal rules

Above the rule.

---

Below the rule.

---

## 7. Inline formatting mix

This paragraph exercises **bold**, *italic*, ***bold-italic***, `inline code`, ~~strikethrough~~, and a [hyperlink](https://dcas.nyc.gov) — all in the same paragraph.

---

## 8. Document with no blank line before list

The following list starts immediately after this sentence:
- Item one
- Item two
- Item three

And a numbered list:
1. First
2. Second
3. Third

---

## 9. Special characters

Quotes: "smart quotes" and 'apostrophes' should be converted by the smarty extension.

Em dashes — like this — should survive. En dashes: 2024–2026.

Unicode: café, naïve, Ångström, 日本語, العربية.

Math-ish: ≤ ≥ ± × ÷ ≠ ∞

---

## 10. Empty section (no content between headings)

### 10a. Heading with no body

### 10b. Another heading immediately after

This paragraph is under 10b and should not be orphaned.
