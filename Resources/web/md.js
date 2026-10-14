/* Markdown + KaTeX rendering shared by the research window and the pet's answer bubbles.
   Requires marked, DOMPurify, KaTeX and (optionally) highlight.js to be loaded first. */
(function () {
  "use strict";

  function escapeHTML(s) {
    return String(s).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
  }

  function renderMarkdown(src) {
    const codes = [], maths = [];
    // Code spans and blocks are protected first so that "$" inside code is not read as math.
    src = String(src || "").replace(/```[\s\S]*?(?:```|$)|`[^`\n]+`/g, (m) => `@@C${codes.push(m) - 1}@@`);
    src = src
      .replace(/\$\$([\s\S]+?)\$\$|\\\[([\s\S]+?)\\\]/g, (m, a, b) => `@@M${maths.push({ tex: a != null ? a : b, display: true }) - 1}@@`)
      .replace(/\\\(([\s\S]+?)\\\)|(?<![\\$\w])\$(?![\s$])([^\n$]+?)(?<![\s\\])\$(?![\w$])/g,
        (m, a, b) => `@@M${maths.push({ tex: a != null ? a : b, display: false }) - 1}@@`);
    src = src.replace(/@@C(\d+)@@/g, (m, i) => codes[+i]);
    let html = marked.parse(src, { gfm: true, breaks: false });
    html = DOMPurify.sanitize(html);
    return html.replace(/@@M(\d+)@@/g, (m, i) => {
      const { tex, display } = maths[+i];
      try { return katex.renderToString(tex, { displayMode: display, throwOnError: false, output: "htmlAndMathml" }); }
      catch (_) { return escapeHTML(display ? `$$${tex}$$` : `$${tex}$`); }
    });
  }

  function highlight(el) {
    if (!window.hljs) return;
    el.querySelectorAll("pre code").forEach((code) => { try { hljs.highlightElement(code); } catch (_) {} });
  }

  window.DeskPetMarkdown = { renderMarkdown, highlight, escapeHTML };
})();
